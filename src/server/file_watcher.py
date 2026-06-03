"""
File watcher service — monitors a user-configured directory for new files
and delegates to FileProcessingQueue for LLM processing.

Architecture:
    FileWatcher ──watchdog──▶ FileWatchHandler ──▶ server._on_new_file_detected()
    _on_new_file_detected() → FileProcessingQueue.submit_file() → unified pipeline

Data cleaning pipelines (by file type):

    管道 A — 纯文本文件 (.md, .markdown, .txt, .json, .xml, .csv):
        直接读取文本，不做多余的视觉转换。
        .json / .xml / .csv 包裹在 markdown 代码块（如 ```json）以帮助 DeepSeek
        触发结构化数据的图谱注意力。

    管道 B — 需要简单清洗 (.html, .htm, .docx, .doc):
        HTML: BeautifulSoup 过滤 <script>/<style> 等噪点标签，
              markdownify 转为高可读性 Markdown。
        DOC/DOCX: 调用 macOS 原生 textutil 零依赖提取纯文本。

    管道 C — 原生多模态视觉 (.jpg, .jpeg, .png, .webp, .gif):
        Base64 编码，通过 API 的 image_url 块作为多模态输入。
        GIF 动图：PIL 提取第一帧，白底 RGB 后转 PNG 再编码。

    管道 D — 高动态视觉渲染 (.pdf, .pptx, .ppt, .xlsx, .xls):
        化文字为图像，利用 LLM 超强视觉/OCR 能力。
        PDF: pyobjc-framework-Quartz / macOS 原生 Quartz/PDFKit 逐页渲染为 PNG。
        Office: AppleScript 调用本地 Office/iWork 另存为 PDF，再走 Quartz 管道。

    ICS 特殊路径 (.ics):
        直接正则解析，不走 LLM，直接创建日历事件。
"""

from __future__ import annotations

import asyncio
import base64
import io
import os
import subprocess
import tempfile
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Literal

import random

from loguru import logger

# ---------------------------------------------------------------------------
# Retry helper for transient LLM API errors (503, 429, connection issues)
# ---------------------------------------------------------------------------

_RETRYABLE_CODES = {429, 503}
_MAX_RETRIES = 3
_BASE_DELAY = 2.0  # seconds


def _is_transient_error(exc: Exception) -> bool:
    """Check if an exception represents a transient (retryable) API error."""
    # OpenAI SDK errors
    if hasattr(exc, "status_code"):
        if getattr(exc, "status_code") in _RETRYABLE_CODES:
            return True
    if hasattr(exc, "code") and getattr(exc, "code") in _RETRYABLE_CODES:
        return True
    # Also retry on connection/timeout errors
    msg = str(exc).lower()
    for keyword in ("503", "429", "rate limit", "service unavailable",
                    "timed out", "connection", "overloaded", "high demand"):
        if keyword in msg:
            return True
    return False


async def _retry_llm_call(fn, *args, **kwargs) -> Any:
    """Call an async function with retry + exponential backoff for transient errors."""
    last_exc = None
    for attempt in range(_MAX_RETRIES + 1):
        try:
            return await fn(*args, **kwargs)
        except Exception as exc:
            last_exc = exc
            if attempt < _MAX_RETRIES and _is_transient_error(exc):
                delay = _BASE_DELAY * (2 ** attempt) + random.uniform(0, 1)
                logger.warning(
                    f"LLM call transient error (attempt {attempt + 1}/{_MAX_RETRIES + 1}), "
                    f"retrying in {delay:.1f}s: {exc}"
                )
                await asyncio.sleep(delay)
            else:
                raise
    raise last_exc  # pragma: no cover


from pydantic import BaseModel, Field, field_validator
from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer

from .constants import CLASSIFY_PROMPT


# ---------------------------------------------------------------------------
# macOS native bridge detection — zero-dependency graphics core
# ---------------------------------------------------------------------------

try:
    from Quartz import PDFDocument, CGColorSpaceCreateDeviceRGB
    from Foundation import NSURL
    HAS_MAC_NATIVE = True
except ImportError:
    HAS_MAC_NATIVE = False

try:
    from Vision import VNRecognizeTextRequest, VNImageRequestHandler
    from Foundation import NSData
    HAS_MAC_VISION = True
except ImportError:
    HAS_MAC_VISION = False


# ---------------------------------------------------------------------------
# FileParser — supported file extensions and utility checks
# ---------------------------------------------------------------------------


class FileParser:
    """Supported file extensions and utility checks."""

    SUPPORTED_SUFFIXES = {
        # 管道 A: 纯文本
        ".md", ".markdown", ".txt", ".json", ".xml", ".csv",
        # 管道 B: 需要清洗
        ".html", ".htm", ".docx", ".doc",
        # 管道 C: 多模态视觉
        ".jpg", ".jpeg", ".png", ".gif", ".webp",
        # 管道 D: 视觉渲染
        ".pdf", ".pptx", ".ppt", ".xlsx", ".xls",
        # ICS: 直接解析，不走 LLM
        ".ics",
    }

    @classmethod
    def is_supported(cls, file_path: Path) -> bool:
        return file_path.suffix.lower() in cls.SUPPORTED_SUFFIXES


# ---------------------------------------------------------------------------
# FileSummarizer — LLM-based content → detailed markdown summary + category
# ---------------------------------------------------------------------------


class ExtractedTodo(BaseModel):
    """从文档中识别出的单条待办事项。"""

    title: str = Field(description="待办标题，不超过200字", max_length=200)
    context: str | None = Field(
        default=None,
        description="文档中该待办对应的原文句子，用于在文档中标记内联链接",
    )
    due_date: str | None = Field(
        default=None,
        description="截止时间，如'明天下午'、'6月5日前'，解析为 YYYY-MM-DD 或 YYYY-MM-DD HH:MM:SS",
    )
    priority: Literal["low", "medium", "high"] = Field(
        default="medium",
        description="优先级：low（低）/ medium（中）/ high（高）",
    )

    @field_validator("title", mode="before")
    @classmethod
    def _truncate_title(cls, v: str) -> str:
        if isinstance(v, str) and len(v) > 200:
            return v[:200]
        return v


class ExtractedSchedule(BaseModel):
    """从文档中识别出的单条日程安排。"""

    title: str = Field(description="日程标题，如'项目周会'")
    context: str | None = Field(
        default=None,
        description="文档中该日程对应的原文句子，用于在文档中标记内联链接",
    )
    target_date: str = Field(description="日程的具体时间，格式 YYYY-MM-DD HH:MM:SS 或 YYYY-MM-DD")


# Keep alias for backward compatibility
SingleReminder = ExtractedTodo


class UnifiedAgentResult(BaseModel):
    """大一统 Agent 输出模型：每个文件都是一篇文档，可选提取子待办和子日程。

    文档元数据（title / summary / content / tags）始终必填。
    reminders 和 schedules 是可选字段，识别不到时留空即可。
    """

    # 文档元数据 — 始终必填
    title: str | None = Field(
        default=None,
        description="文档标题，不超过200字",
        max_length=200,
    )
    summary: str | None = Field(
        default=None,
        description="一句话核心内容摘要，不超过200字",
        max_length=200,
    )
    content: str | None = Field(
        default=None,
        description="详细的 markdown 格式摘要，始终必填。对于识别出的待办/日程原文句子，用 [原文]{{extracted:N}} 标记",
    )
    tags: list[str] = Field(description="1-5 个中文关键词标签", min_length=1, max_length=5)

    # 保留字段，始终为 null
    target_date: str | None = Field(
        default=None,
        description="保留字段，始终填 null",
    )

    # 可选：从文档中识别出的待办事项
    reminders: list[ExtractedTodo] = Field(
        default_factory=list,
        description="从文档中识别出的待办事项列表，识别不到时留空 []",
    )

    # 可选：从文档中识别出的日程安排
    schedules: list[ExtractedSchedule] = Field(
        default_factory=list,
        description="从文档中识别出的日程安排列表，识别不到时留空 []",
    )

    @field_validator("title", mode="before")
    @classmethod
    def _truncate_title(cls, v: str | None) -> str | None:
        if isinstance(v, str) and len(v) > 200:
            return v[:200]
        return v

    @field_validator("summary", mode="before")
    @classmethod
    def _truncate_summary(cls, v: str | None) -> str | None:
        if isinstance(v, str) and len(v) > 200:
            return v[:200]
        return v


class FileSummarizer:
    """Submit a file directly to the LLM as a multimodal attachment.

    The file bytes are read, base64-encoded, and sent as an ``image_url``
    content block so the LLM receives the actual file — not pre-extracted
    text.
    """

    # ------------------------------------------------------------------
    # 四管道扩展集
    # ------------------------------------------------------------------

    # 管道 A: 纯文本 — 直接读取，不做格式转换
    _SFX_PLAINTEXT: set[str] = {
        ".md", ".markdown", ".txt", ".json", ".xml", ".csv", ".ics",
    }

    # 管道 B: 需要清洗
    _SFX_HTML: set[str] = {".html", ".htm"}
    _SFX_DOC: set[str] = {".docx", ".doc"}

    # 管道 C: 多模态视觉 — base64 编码后直接给 DeepSeek 视觉模型
    _SFX_VISION: set[str] = {".jpg", ".jpeg", ".png", ".gif", ".webp"}

    # 管道 D: 视觉渲染 — 先渲染为图片，再用 LLM OCR 能力
    _SFX_RENDER: set[str] = {".pdf", ".pptx", ".ppt", ".xlsx", ".xls"}

    # MIME 类型映射（管道 C 使用）
    _MIME_MAP: dict[str, str] = {
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".png": "image/png",
        ".gif": "image/gif",
        ".webp": "image/webp",
    }

    # 结构化文本包裹在 markdown 代码块中以帮助 DeepSeek 触发图注意力
    _CODE_BLOCK_LANG: dict[str, str] = {
        ".json": "json",
        ".xml": "xml",
        ".csv": "csv",
    }

    def __init__(self):
        self._text_llm = None
        self._vision_llm = None
        self._text_profile = None
        self._vision_profile = None
        self._llms_initialized = False

    def _ensure_llms(self):
        """Lazy-init LLM references so constructors don't fail without API key."""
        if self._llms_initialized:
            return
        from .gateway import TaskType, get_gateway

        gw = get_gateway()
        self._text_llm = gw.get_llm(TaskType.TEXT)
        self._vision_llm = gw.get_llm(TaskType.MULTIMODAL)
        self._text_profile = gw.get_profile(TaskType.TEXT)
        self._vision_profile = gw.get_profile(TaskType.MULTIMODAL)
        self._llms_initialized = True

        if self._vision_llm is None:
            logger.warning(
                f"⚠️ FileSummarizer: 多模态视觉 LLM 不可用，"
                f"图片/PDF 管道将完全依赖 macOS 本地 OCR 降级"
            )

    @property
    def text_llm(self):
        self._ensure_llms()
        return self._text_llm

    @property
    def vision_llm(self):
        self._ensure_llms()
        return self._vision_llm

    @property
    def text_profile(self):
        self._ensure_llms()
        return self._text_profile

    @property
    def vision_profile(self):
        self._ensure_llms()
        return self._vision_profile

    @property
    def _multimodal_supports_vision(self) -> bool:
        """当前 MULTIMODAL 槽位是否真正可用（有凭据 + 模型支持 vision）。"""
        from .constants import MODEL_META

        vl = self.vision_llm
        if vl is None:
            return False
        vp = self.vision_profile
        return MODEL_META.get(vp.model, {}).get("supports_vision", False)

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def summarize(self, file_path: Path) -> dict[str, Any]:
        """根据文件后缀分发到对应的处理管道。"""
        self._ensure_llms()
        suffix = file_path.suffix.lower()

        if suffix in self._SFX_PLAINTEXT:
            return await self._pipeline_plain_text(file_path)

        if suffix in self._SFX_HTML or suffix in self._SFX_DOC:
            return await self._pipeline_cleaning(file_path)

        if suffix in self._SFX_VISION:
            return await self._pipeline_vision(file_path)

        if suffix in self._SFX_RENDER:
            return await self._pipeline_visual_render(file_path)

        raise ValueError(f"不支持的文件格式: {suffix}")

    # ==================================================================
    # 管道 A: 纯文本文件
    # ==================================================================

    async def _pipeline_plain_text(self, file_path: Path) -> dict[str, Any]:
        """管道 A — 直接读取纯文本，结构化格式包裹在代码块中。

        .json / .xml / .csv 用 markdown 代码块包裹，
        帮助 DeepSeek 触发结构化数据的图注意力机制。
        """
        from langchain_core.messages import HumanMessage

        suffix = file_path.suffix.lower()
        text = file_path.read_text(encoding="utf-8", errors="replace")
        if not text or not text.strip():
            raise ValueError(f"文件为空: {file_path.name}")

        max_chars = 32000
        truncated = text if len(text) <= max_chars else (
            text[:max_chars]
            + f"\n\n---\n\n> ⚠️ 内容已截断，原文件共 {len(text)} 字符"
        )

        lang = self._CODE_BLOCK_LANG.get(suffix)
        if lang:
            truncated = f"```{lang}\n{truncated}\n```"

        p = self.text_profile
        logger.info(
            f"管道 A 处理 {file_path.name} ({len(text)} 字符) | "
            f"模型={p.model} | thinking={'开' if p.thinking_enabled else '关'}"
        )

        user_message = HumanMessage(content=[
            {
                "type": "text",
                "text": (
                    f"文件名：{file_path.name}\n"
                    f"原文字数：约 {len(text)} 字符\n\n"
                    f"--- 文件内容 ---\n{truncated}\n--- 内容结束 ---\n\n"
                    f"请仔细阅读以上文件，为其分类并生成一份详细的 markdown 摘要。"
                ),
            },
        ])

        return await self._invoke_llm(user_message, file_path)

    # ==================================================================
    # 管道 B: 需要简单清洗的文件
    # ==================================================================

    async def _pipeline_cleaning(self, file_path: Path) -> dict[str, Any]:
        """管道 B — HTML 去噪 / DOC 提取后再提交 LLM。

        HTML: BeautifulSoup 去噪 + markdownify 转 Markdown
        DOC/DOCX: macOS 原生 textutil 提取纯文本
        """
        suffix = file_path.suffix.lower()

        if suffix in self._SFX_HTML:
            cleaned = self._clean_html(file_path)
        else:
            cleaned = self._clean_doc(file_path)

        p = self.text_profile
        logger.info(
            f"管道 B 清洗 {file_path.name} ({len(cleaned)} 字符) | "
            f"模型={p.model} | thinking={'开' if p.thinking_enabled else '关'}"
        )

        return await self._submit_cleaned_text(file_path, cleaned, suffix)

    @staticmethod
    def _clean_html(file_path: Path) -> str:
        """用 BeautifulSoup 去除 HTML 中的噪点标签，markdownify 转为 Markdown。"""
        try:
            from bs4 import BeautifulSoup
        except ImportError:
            raise RuntimeError("beautifulsoup4 未安装，请运行: uv sync")

        try:
            from markdownify import markdownify as md_convert
        except ImportError:
            raise RuntimeError("markdownify 未安装，请运行: uv sync")

        raw_html = file_path.read_text(encoding="utf-8", errors="replace")
        soup = BeautifulSoup(raw_html, "html.parser")

        # 移除对内容无贡献的噪点标签
        for tag in soup(["script", "style", "noscript", "iframe", "nav", "footer", "meta", "link"]):
            tag.decompose()

        # 将干净的 HTML 转为 Markdown
        return md_convert(str(soup), heading_style="ATX")

    @staticmethod
    def _clean_doc(file_path: Path) -> str:
        """用 macOS 原生 textutil 提取 .doc/.docx 的纯文本。

        textutil 是 macOS 自带工具，零外部依赖，毫秒级完成。
        写入临时文件而非 stdout 以通过 macOS 沙盒限制。
        """
        with tempfile.NamedTemporaryFile(suffix=".txt", delete=False) as tmp:
            tmp_path = Path(tmp.name)

        try:
            result = subprocess.run(
                ["textutil", "-convert", "txt", str(file_path), "-output", str(tmp_path)],
                capture_output=True,
                text=True,
                timeout=30,
            )
            if result.returncode != 0:
                raise RuntimeError(f"textutil 失败: {result.stderr.strip()}")

            text = tmp_path.read_text(encoding="utf-8", errors="replace")
            if not text or not text.strip():
                raise ValueError(f"文档无文本内容: {file_path.name}")
            return text
        finally:
            tmp_path.unlink(missing_ok=True)

    async def _submit_cleaned_text(
        self, file_path: Path, cleaned_text: str, suffix: str
    ) -> dict[str, Any]:
        """将清洗后的文本提交给 LLM。"""
        from langchain_core.messages import HumanMessage

        max_chars = 32000
        truncated = cleaned_text if len(cleaned_text) <= max_chars else (
            cleaned_text[:max_chars]
            + f"\n\n---\n\n> ⚠️ 内容已截断，原文件共 {len(cleaned_text)} 字符"
        )

        user_message = HumanMessage(content=[
            {
                "type": "text",
                "text": (
                    f"文件名：{file_path.name}\n"
                    f"格式：{suffix.upper().lstrip('.')}（已自动提取文本内容）\n"
                    f"原文字数：约 {len(cleaned_text)} 字符\n\n"
                    f"--- 文件内容 ---\n{truncated}\n--- 内容结束 ---\n\n"
                    f"请仔细阅读以上文件，为其分类并生成一份详细的 markdown 摘要。"
                ),
            },
        ])

        return await self._invoke_llm(user_message, file_path)

    # ==================================================================
    # 管道 C: 原生多模态视觉
    # ==================================================================

    async def _pipeline_vision(self, file_path: Path) -> dict[str, Any]:
        """管道 C — 图片文件 base64 编码后发送给 DeepSeek 视觉模型。

        GIF 动图先用 PIL 提取第一帧转为 PNG 后再编码。
        大多数 LLM 视觉接口只接收静态图片，直接传 GIF 可能报错。
        """
        from langchain_core.messages import HumanMessage

        suffix = file_path.suffix.lower()
        file_bytes = file_path.read_bytes()

        if suffix == ".gif":
            try:
                file_bytes = self._extract_gif_first_frame(file_path)
                mime_type = "image/png"
                logger.info(f"GIF 首帧提取成功 {file_path.name} → PNG ({len(file_bytes)} bytes)")
            except Exception:
                logger.opt(exception=True).warning(
                    f"GIF 首帧提取失败 {file_path.name}，使用原始 GIF"
                )
                mime_type = "image/gif"
        else:
            mime_type = self._MIME_MAP.get(suffix, "application/octet-stream")

        if not self._multimodal_supports_vision:
            logger.warning(
                f"管道 C 降级 {file_path.name} | MULTIMODAL 模型不支持视觉，"
                f"启用 macOS 本地 OCR → TEXT 管道"
            )
            text = await asyncio.to_thread(extract_text_via_mac_vision, file_bytes)
            if not text or not text.strip():
                raise RuntimeError(
                    f"macOS 本地 OCR 未能从图片中提取文字: {file_path.name}"
                )
            return await self._submit_cleaned_text(file_path, text, suffix)

        b64_data = base64.b64encode(file_bytes).decode("ascii")
        data_url = f"data:{mime_type};base64,{b64_data}"

        p = self.vision_profile
        logger.info(
            f"管道 C 提交 {file_path.name} ({mime_type}, {len(file_bytes)} bytes) | "
            f"模型={p.model} | thinking={'开' if p.thinking_enabled else '关'}"
        )

        user_message = HumanMessage(content=[
            {
                "type": "text",
                "text": (
                    f"请仔细阅读这张图片（文件名：{file_path.name}），"
                    f"用 markdown 格式完整转录/描述图片中的内容，"
                    f"保留关键信息、数据和结构。"
                ),
            },
            {
                "type": "image_url",
                "image_url": {"url": data_url},
            },
        ])

        return await self._invoke_vision_llm(user_message, file_path)

    @staticmethod
    def _extract_gif_first_frame(file_path: Path) -> bytes:
        """用 PIL 提取 GIF 第一帧，白底 RGB 后输出为 PNG 字节流。"""
        try:
            from PIL import Image
        except ImportError:
            raise RuntimeError("Pillow 未安装，请运行: uv sync")

        with Image.open(file_path) as img:
            img.seek(0)
            # 处理调色板 / 透明通道
            if img.mode in ("RGBA", "PA", "LA"):
                rgb_img = Image.new("RGB", img.size, (255, 255, 255))
                mask = img.split()[-1] if img.mode in ("RGBA", "LA") else None
                rgb_img.paste(img, mask=mask)
            elif img.mode == "P":
                rgb_img = img.convert("RGBA")
                bg = Image.new("RGB", img.size, (255, 255, 255))
                bg.paste(rgb_img, mask=rgb_img.split()[-1])
                rgb_img = bg
            else:
                rgb_img = img.convert("RGB")

            buf = io.BytesIO()
            rgb_img.save(buf, format="PNG")
            return buf.getvalue()

    # ==================================================================
    # 管道 D: 高动态视觉渲染
    # ==================================================================

    async def _pipeline_visual_render(self, file_path: Path) -> dict[str, Any]:
        """管道 D — 三支智能文档处理矩阵。

        Phase 1: 提取原生文本 + 视觉元素探测。
        Phase 2: 综合「文字有无」「图表有无」双维路由：

        ① 有字无图 → 纯文本直通车（跳过昂贵渲染）
        ② 有字有图 → 多模态图文双轨混合投喂
        ③ 纯扫描件 → 多模态视觉通道
        """
        suffix = file_path.suffix.lower()
        fpath = str(file_path)

        # ── Step 1: 提取原生文本 + 视觉元素探测 ──
        native_text = ""
        has_visuals = False

        if suffix == ".pdf":
            native_text = await asyncio.to_thread(extract_pdf_text_via_quartz, fpath)
            has_visuals = await asyncio.to_thread(detect_visual_elements, fpath)
        elif suffix in (".pptx", ".ppt"):
            native_text = await asyncio.to_thread(extract_pptx_text_locally, fpath)
            has_visuals = await asyncio.to_thread(detect_visual_elements, fpath)
        elif suffix in (".xlsx", ".xls"):
            native_text = await asyncio.to_thread(extract_excel_to_markdown_table, fpath)
            has_visuals = False
        else:
            raise ValueError(f"不支持的渲染格式: {suffix}")

        vp = self.vision_profile
        logger.info(
            f"管道 D 双轨分析 {file_path.name}: "
            f"native_text={len(native_text)}chars | visuals={has_visuals} | "
            f"vision_model={vp.model}"
        )

        # 分支 ① 有字无图 → 纯文本直通车（跳过昂贵渲染，省 Token 省时间）
        if native_text.strip() and not has_visuals:
            logger.info(
                f"管道 D ① 纯文本通道 {file_path.name} "
                f"({len(native_text)} chars, 无需渲染)"
            )
            return await self._submit_cleaned_text(file_path, native_text, suffix)

        # 渲染图片（分支 ②③ 共用）
        if suffix == ".pdf":
            data_urls = await asyncio.to_thread(self._render_pdf_pages, file_path)
        else:
            data_urls = await asyncio.to_thread(self._render_office_to_images, file_path)

        logger.info(
            f"管道 D 渲染完成 {file_path.name} ({len(data_urls)} 页)"
        )

        # 分支 ② 有字有图 → 多模态图文双轨混合投喂（或 OCR 降级）
        if native_text.strip() and has_visuals:
            if not self._multimodal_supports_vision:
                logger.warning(
                    f"管道 D ② 降级 {file_path.name} | MULTIMODAL 模型不支持视觉，"
                    f"使用 macOS 本地 OCR + 原生文本 → TEXT 管道"
                )
                ocr_text = await asyncio.to_thread(_ocr_data_urls, data_urls)
                combined = native_text + "\n\n--- OCR from rendered images ---\n" + ocr_text
                return await self._submit_cleaned_text(file_path, combined, suffix)

            logger.info(
                f"管道 D ② 图文双轨混合 {file_path.name} | "
                f"模型={vp.model}"
            )
            return await self._submit_multipage_vision(file_path, data_urls, native_text)

        # 分支 ③ 纯扫描件 → 多模态视觉通道（或 OCR 降级）
        if not self._multimodal_supports_vision:
            logger.warning(
                f"管道 D ③ 降级 {file_path.name} | MULTIMODAL 模型不支持视觉，"
                f"使用 macOS 本地 OCR → TEXT 管道"
            )
            ocr_text = await asyncio.to_thread(_ocr_data_urls, data_urls)
            if not ocr_text.strip():
                raise RuntimeError(
                    f"macOS 本地 OCR 未能从文档中提取文字: {file_path.name}"
                )
            return await self._submit_cleaned_text(file_path, ocr_text, suffix)

        logger.info(
            f"管道 D ③ 纯扫描件视觉通道 {file_path.name} | "
            f"模型={vp.model}"
        )
        return await self._submit_multipage_vision(file_path, data_urls, "")

    @staticmethod
    def _render_pdf_pages(
        file_path: Path, max_pages: int = 20, dpi: int = 200
    ) -> list[str]:
        """用 macOS 原生 Quartz/PDFKit 将 PDF 逐页渲染为高分辨率 PNG。

        返回 base64 data URL 列表，每页一个。
        超过 max_pages 页时截断。
        """
        try:
            from Quartz import (
                CGPDFDocumentCreateWithURL,
                CGPDFDocumentGetNumberOfPages,
                CGPDFDocumentGetPage,
                CGRectMake,
                CGColorSpaceCreateDeviceRGB,
                CGBitmapContextCreate,
                kCGImageAlphaPremultipliedFirst,
                CGContextDrawPDFPage,
                CGContextSetRGBFillColor,
                CGContextFillRect,
                CGContextScaleCTM,
                CGPDFPageGetBoxRect,
                kCGPDFMediaBox,
                CGBitmapContextGetData,
            )
            from CoreFoundation import (
                CFURLCreateFromFileSystemRepresentation,
                kCFAllocatorDefault,
            )
        except ImportError:
            raise RuntimeError(
                "pyobjc-framework-Quartz 未安装，请运行: uv sync"
            )
        try:
            from PIL import Image as PILImage
        except ImportError:
            raise RuntimeError("Pillow 未安装，请运行: uv sync")

        # 创建 CFURL
        path_bytes = str(file_path).encode("utf-8")
        url = CFURLCreateFromFileSystemRepresentation(
            kCFAllocatorDefault, path_bytes, len(path_bytes), False
        )
        if url is None:
            raise RuntimeError(f"无法创建 PDF URL: {file_path}")

        pdf_doc = CGPDFDocumentCreateWithURL(url)
        if pdf_doc is None:
            raise RuntimeError(f"无法打开 PDF: {file_path}")

        page_count = CGPDFDocumentGetNumberOfPages(pdf_doc)
        if page_count == 0:
            raise RuntimeError(f"PDF 无页面: {file_path}")

        actual_pages = min(page_count, max_pages)
        scale = dpi / 72.0  # PDF points → pixels
        data_urls: list[str] = []

        for page_idx in range(1, actual_pages + 1):
            page = CGPDFDocumentGetPage(pdf_doc, page_idx)
            if page is None:
                continue

            media_box = CGPDFPageGetBoxRect(page, kCGPDFMediaBox)
            width = int(media_box.size.width * scale)
            height = int(media_box.size.height * scale)

            color_space = CGColorSpaceCreateDeviceRGB()
            ctx = CGBitmapContextCreate(
                None, width, height, 8, width * 4,
                color_space, kCGImageAlphaPremultipliedFirst
            )
            if ctx is None:
                continue

            # 白底 + 缩放 + 绘制 PDF 页面
            CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 1.0)
            CGContextFillRect(ctx, CGRectMake(0, 0, width, height))
            CGContextScaleCTM(ctx, scale, scale)
            CGContextDrawPDFPage(ctx, page)

            # 从 bitmap context 获取原始 BGRA 数据 → PIL Image → PNG bytes
            raw_data = CGBitmapContextGetData(ctx)
            if raw_data is None:
                continue

            buf = raw_data.as_buffer(width * height * 4)
            pil_image = PILImage.frombuffer(
                "RGBA", (width, height), buf, "raw", "BGRA", 0, 1
            )
            # 转为白色背景的 RGB
            rgb_image = PILImage.new("RGB", pil_image.size, (255, 255, 255))
            rgb_image.paste(pil_image, mask=pil_image.split()[-1])

            png_buf = io.BytesIO()
            rgb_image.save(png_buf, format="PNG")
            b64 = base64.b64encode(png_buf.getvalue()).decode("ascii")
            data_urls.append(f"data:image/png;base64,{b64}")

        if not data_urls:
            raise RuntimeError(f"PDF 渲染失败，未生成任何图片: {file_path}")

        if page_count > max_pages:
            logger.info(f"PDF 共 {page_count} 页，仅渲染前 {max_pages} 页")

        return data_urls

    @staticmethod
    def _render_office_to_images(file_path: Path) -> list[str]:
        """用 AppleScript 调用 Office 或 iWork 将文档转为 PDF，再渲染为图片。

        尝试链：Microsoft Office → Apple iWork → 抛出异常
        """
        with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as tmp:
            pdf_path = Path(tmp.name)

        try:
            suffix = file_path.suffix.lower()
            if suffix in (".pptx", ".ppt"):
                _pptx_to_pdf(file_path, pdf_path)
            elif suffix in (".xlsx", ".xls"):
                _xlsx_to_pdf(file_path, pdf_path)
            else:
                raise RuntimeError(f"AppleScript 不支持此格式: {suffix}")

            if not pdf_path.exists() or pdf_path.stat().st_size == 0:
                raise RuntimeError(f"AppleScript 未生成有效 PDF: {pdf_path}")

            return FileSummarizer._render_pdf_pages(pdf_path)
        finally:
            pdf_path.unlink(missing_ok=True)

    async def _submit_multipage_vision(
        self, file_path: Path, data_urls: list[str], native_text: str = ""
    ) -> dict[str, Any]:
        """将多页渲染图片提交给视觉模型，可选附带原生文本做图文双轨混合投喂。

        两步流水线：
        1. 视觉模型直接 OCR/转录（不用 structured output，function calling
           不支持 image_url）
        2. 将转录文本交给文本模型做结构化分类

        当 native_text 非空时，提示词引导模型将精确文本作为事实依据，
        图片用于理解图表/趋势/排版。
        """
        from langchain_core.messages import HumanMessage

        if not data_urls:
            raise RuntimeError("没有可提交的页面图片")

        # ── 构建提示词：有原生文本 → 图文双轨混合投喂；无文本 → 纯视觉 OCR ──
        if native_text.strip():
            text_prompt = (
                f"你收到了一个复杂的图文混排文档（文件名：{file_path.name}），"
                f"共 {len(data_urls)} 页。\n\n"
                f"系统已为你提取了该文档内部极其精确的原生纯文本，请直接作为事实依据引用。\n"
                f"同时，为了防止文档中的【核心图表、折线图、架构排版】丢失，"
                f"下方一并附带了该文档各页面的视觉截图。\n"
                f"请结合文字和图片中展现的趋势、结构，进行最全面的深度总结和关联分析：\n\n"
                f"--- 原生纯文本开始 ---\n{native_text}\n--- 原生纯文本结束 ---"
            )
        else:
            text_prompt = (
                f"请仔细阅读这个文档（文件名：{file_path.name}），"
                f"共 {len(data_urls)} 页。"
                f"请用 markdown 格式完整转录/描述所有页面的内容，"
                f"保留关键信息、数据和结构。"
            )

        content_blocks: list[dict] = [{"type": "text", "text": text_prompt}]
        for i, url in enumerate(data_urls, 1):
            content_blocks.append({
                "type": "image_url",
                "image_url": {"url": url},
            })

        user_message = HumanMessage(content=content_blocks)
        return await self._invoke_vision_llm(user_message, file_path)

    # ------------------------------------------------------------------
    # Shared LLM invocation
    # ------------------------------------------------------------------

    async def _invoke_llm(
        self, user_message, file_path: Path,
        use_llm: Any | None = None,
    ) -> dict[str, Any]:
        """Send a text-only message to the LLM with structured output.

        Returns a dict with title, summary, tags, content, target_date,
        reminders (list of ExtractedTodo) and schedules (list of ExtractedSchedule).
        """
        from langchain_core.messages import SystemMessage

        llm = use_llm or self.text_llm
        structured_llm = llm.with_structured_output(
            UnifiedAgentResult, method="function_calling"
        )

        try:
            result: UnifiedAgentResult = await _retry_llm_call(
                structured_llm.ainvoke,
                [
                    SystemMessage(content=CLASSIFY_PROMPT),
                    user_message,
                ],
            )
            return {
                "title": result.title,
                "summary": result.summary,
                "tags": result.tags,
                "content": result.content,
                "target_date": result.target_date,
                "reminders": [
                    {
                        "title": r.title,
                        "context": r.context,
                        "due_date": r.due_date,
                        "priority": r.priority,
                    }
                    for r in result.reminders
                ],
                "schedules": [
                    {
                        "title": s.title,
                        "context": s.context,
                        "target_date": s.target_date,
                    }
                    for s in result.schedules
                ],
            }
        except Exception as e:
            logger.warning(f"LLM summarization failed for {file_path.name}: {e}")
            return await self._fallback_extract(file_path)

    async def _invoke_vision_llm(
        self, user_message, file_path: Path,
    ) -> dict[str, Any]:
        """Two-step vision summarization.

        Step 1 — 视觉模型转录（不用 structured output，function calling 不支持 image_url）
        Step 2 — 文本模型分类（用 structured output 做结构化提取）
        """
        from langchain_core.messages import HumanMessage, SystemMessage

        vp = self.vision_profile
        tp = self.text_profile

        # Step 1: transcribe images with vision model (plain response)
        logger.info(
            f"Vision Step 1/2 — 转录 {file_path.name} | "
            f"模型={vp.model} | thinking={'开' if vp.thinking_enabled else '关'}"
        )
        try:
            vision_response = await _retry_llm_call(
                self.vision_llm.ainvoke,
                [
                    SystemMessage(content=(
                        "你是一个专业的文档数字化助手。请仔细阅读用户提供的图片，"
                        "用 markdown 格式完整转录/描述所有文字内容和视觉信息。"
                        "保留原文的层级结构、表格、列表等格式。"
                    )),
                    user_message,
                ],
            )
            transcription = vision_response.content
        except Exception as e:
            logger.warning(f"Vision transcription failed for {file_path.name}: {e}")
            return await self._fallback_extract(file_path)

        logger.info(
            f"Vision Step 1/2 — 转录完成 {file_path.name} "
            f"({len(transcription)} chars)"
        )

        # Step 2: classify transcribed text with structured output
        logger.info(
            f"Vision Step 2/2 — 分类 {file_path.name} | "
            f"模型={tp.model} | thinking={'开' if tp.thinking_enabled else '关'}"
        )
        max_chars = 32000
        truncated = transcription if len(transcription) <= max_chars else (
            transcription[:max_chars]
            + f"\n\n---\n\n> ⚠️ 转录内容已截断，原共 {len(transcription)} 字符"
        )

        text_message = HumanMessage(content=[
            {
                "type": "text",
                "text": (
                    f"文件名：{file_path.name}\n"
                    f"以下是图片/文档中提取的 markdown 内容：\n\n"
                    f"--- 内容开始 ---\n{truncated}\n--- 内容结束 ---\n\n"
                    f"请仔细阅读以上内容，为其分类并生成一份详细的 markdown 摘要。"
                ),
            },
        ])

        try:
            result = await self._invoke_llm(text_message, file_path)
            return result
        except Exception:
            logger.warning(f"Structured classification failed for {file_path.name}")
            raise

    async def _fallback_extract(self, file_path: Path) -> dict[str, Any]:
        """Raise an error when LLM summarization fails — never expose raw extracted text to users."""
        raise RuntimeError(f"LLM summarization failed for {file_path.name}, no fallback available")


# ---------------------------------------------------------------------------
# AppleScript helpers (管道 D) — macOS 原生 Office/iWork → PDF
# ---------------------------------------------------------------------------


def _pptx_to_pdf(input_path: Path, output_path: Path) -> None:
    """将 PPT/PPTX 转为 PDF。尝试链：PowerPoint → Keynote → 报错。"""
    # 尝试 Microsoft PowerPoint
    if _run_applescript("Microsoft PowerPoint", input_path, output_path):
        logger.info(f"PowerPoint 导出成功: {output_path.name}")
        return
    # 尝试 Apple Keynote
    if _run_applescript("Keynote", input_path, output_path):
        logger.info(f"Keynote 导出成功: {output_path.name}")
        return
    raise RuntimeError(
        "无法转换 PPTX：Microsoft PowerPoint 和 Keynote 均不可用"
    )


def _xlsx_to_pdf(input_path: Path, output_path: Path) -> None:
    """将 XLS/XLSX 转为 PDF。尝试链：Excel → Numbers → 报错。"""
    if _run_applescript("Microsoft Excel", input_path, output_path):
        logger.info(f"Excel 导出成功: {output_path.name}")
        return
    if _run_applescript("Numbers", input_path, output_path):
        logger.info(f"Numbers 导出成功: {output_path.name}")
        return
    raise RuntimeError(
        "无法转换 XLSX：Microsoft Excel 和 Numbers 均不可用"
    )


def _run_applescript(app_name: str, input_path: Path, output_path: Path) -> bool:
    """运行 AppleScript 让 macOS 应用将文件导出为 PDF。返回是否成功。"""

    scripts: dict[str, str] = {
        "Microsoft PowerPoint": (
            f'tell application "Microsoft PowerPoint"\n'
            f'    open POSIX file "{input_path}"\n'
            f'    save active presentation in POSIX file "{output_path}" as save as PDF\n'
            f'    close active presentation\n'
            f'end tell'
        ),
        "Keynote": (
            f'tell application "Keynote"\n'
            f'    open POSIX file "{input_path}"\n'
            f'    tell front document\n'
            f'        export to POSIX file "{output_path}" as PDF\n'
            f'    end tell\n'
            f'    close front document\n'
            f'end tell'
        ),
        "Microsoft Excel": (
            f'tell application "Microsoft Excel"\n'
            f'    open POSIX file "{input_path}"\n'
            f'    set wb to active workbook\n'
            f'    save workbook as wb filename POSIX file "{output_path}" '
            f'file format PDF file format\n'
            f'    close active workbook\n'
            f'end tell'
        ),
        "Numbers": (
            f'tell application "Numbers"\n'
            f'    open POSIX file "{input_path}"\n'
            f'    tell front document\n'
            f'        export to POSIX file "{output_path}" as PDF\n'
            f'    end tell\n'
            f'    close front document\n'
            f'end tell'
        ),
    }

    script = scripts.get(app_name)
    if script is None:
        logger.warning(f"AppleScript: 不支持的应用 {app_name}")
        return False

    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            text=True,
            timeout=60,
        )
        if result.returncode != 0:
            logger.warning(
                f"AppleScript {app_name} 失败: {result.stderr.strip()[:200]}"
            )
            return False
        return output_path.exists() and output_path.stat().st_size > 0
    except subprocess.TimeoutExpired:
        logger.warning(f"AppleScript {app_name} 超时")
        return False
    except FileNotFoundError:
        logger.warning("osascript 不可用（非 macOS 系统？）")
        return False


# ---------------------------------------------------------------------------
# Native extraction & detection functions (Phase 1 — 补齐底层 5 大能力矩阵)
# ---------------------------------------------------------------------------


def detect_visual_elements(file_path: str) -> bool:
    """【能力矩阵 1】轻量级视觉元素探测器。

    毫秒级扫描 PDF/PPTX 内部是否含有内嵌图片、统计图表或非文本视觉区。
    用于网关判断是否需要走图文混合通道还是纯文本直通车。
    """
    _, suffix = os.path.splitext(file_path.lower())
    try:
        if suffix in (".pptx", ".ppt"):
            from pptx import Presentation as _Prs
            prs = _Prs(file_path)
            for slide in prs.slides:
                for shape in slide.shapes:
                    if shape.has_chart:
                        logger.info(f"🔮 探测器：PPT 发现图表 -> {shape.name}")
                        return True
                    if hasattr(shape, "shape_type") and shape.shape_type == 13:
                        logger.info(f"🔮 探测器：PPT 发现内嵌图片 -> {shape.name}")
                        return True
        elif suffix == ".pdf":
            from pypdf import PdfReader as _PdfReader
            reader = _PdfReader(file_path)
            for page_idx, page in enumerate(reader.pages):
                if page.images and len(page.images.keys()) > 0:
                    logger.info(
                        f"🔮 探测器：PDF 第 {page_idx + 1} 页发现内嵌图片元素"
                    )
                    return True
    except Exception:
        logger.opt(exception=True).warning(f"视觉元素探测异常 ({file_path})")
    return False


def extract_pdf_text_via_quartz(pdf_path: str) -> str:
    """【能力矩阵 2】白嫖 Mac Quartz 内核提取 PDF 原生纯文本。

    零外部二进制依赖，完美识别可流式阅读的 PDF 文本流。
    与 _render_pdf_pages 形成“文字+图片”双轨互补。
    """
    if not HAS_MAC_NATIVE:
        logger.warning("macOS 原生 Quartz 库未加载，无法执行底层 PDF 文本抽取")
        return ""

    try:
        url = NSURL.fileURLWithPath_(pdf_path)
        doc = PDFDocument.alloc().initWithURL_(url)
        if not doc:
            return ""

        pages_text: list[str] = []
        for i in range(doc.pageCount()):
            page = doc.pageAtIndex_(i)
            page_string = page.string()
            if page_string and page_string.strip():
                pages_text.append(f"--- Page {i + 1} ---\n{page_string.strip()}")

        return "\n\n".join(pages_text)
    except Exception:
        logger.opt(exception=True).error(f"Quartz PDF 文本提取失败: {pdf_path}")
        return ""


def extract_pptx_text_locally(pptx_path: str) -> str:
    """【能力矩阵 3】使用 python-pptx 遍历线性结构抽取文字。

    按幻灯片序号拼接，保留标题/正文层级关系。
    """
    try:
        from pptx import Presentation as _Prs
        prs = _Prs(pptx_path)
        slide_texts: list[str] = []
        for idx, slide in enumerate(prs.slides):
            texts_in_slide: list[str] = []
            for shape in slide.shapes:
                if hasattr(shape, "text") and shape.text.strip():
                    texts_in_slide.append(shape.text.strip())
            if texts_in_slide:
                slide_texts.append(
                    f"### Slide {idx + 1}\n" + "\n".join(texts_in_slide)
                )
        return "\n\n".join(slide_texts)
    except Exception:
        logger.opt(exception=True).error(f"python-pptx 本地提取失败: {pptx_path}")
        return ""


def extract_excel_to_markdown_table(xlsx_path: str) -> str:
    """【能力矩阵 4】使用 pandas + openpyxl 将 Excel 转化为全大模型通用的 Markdown 数据表。

    批量加载所有 Sheets，调用 .to_markdown(index=False) 动态转化。
    """
    try:
        import pandas as pd
        excel_file = pd.ExcelFile(xlsx_path)
        sheets_md: list[str] = []
        for sheet_name in excel_file.sheet_names:
            df = pd.read_excel(xlsx_path, sheet_name=sheet_name)
            if df.empty:
                continue
            md_table = df.to_markdown(index=False)
            sheets_md.append(f"## Sheet: {sheet_name}\n{md_table}")
        return "\n\n".join(sheets_md)
    except Exception:
        logger.opt(exception=True).error(f"Excel 转 Markdown 失败: {xlsx_path}")
        return ""


# ---------------------------------------------------------------------------
# macOS Vision OCR — 当 MULTIMODAL 模型不支持 vision 时的本地 OCR 降级
# ---------------------------------------------------------------------------


def extract_text_via_mac_vision(image_bytes: bytes) -> str:
    """用 macOS Vision 框架对单张图片进行本地 OCR，返回提取的文本。

    VNRecognizeTextRequest 支持中/英/日/韩等多语言，
    零外部依赖，毫秒级完成。
    """
    if not HAS_MAC_VISION:
        raise RuntimeError(
            "macOS Vision 框架不可用（非 macOS 系统或 PyObjC 未安装）。"
            "请在 MULTIMODAL 槽位使用支持 vision 的模型，或在 macOS 上运行。"
        )

    data = NSData.dataWithBytes_length_(image_bytes, len(image_bytes))
    handler = VNImageRequestHandler.alloc().initWithData_options_(data, None)

    request = VNRecognizeTextRequest.alloc().init()
    request.setRecognitionLevel_(1)  # Accurate (0 = Fast)
    request.setUsesLanguageCorrection_(True)

    success, error = handler.performRequests_error_([request], None)
    if not success:
        error_msg = str(error) if error else "未知错误"
        logger.warning(f"macOS Vision OCR 失败: {error_msg}")
        return ""

    observations = request.results()
    if not observations:
        return ""

    texts = []
    for obs in observations:
        text = obs.text()
        if text and text.strip():
            texts.append(text.strip())
    return "\n".join(texts)


def _ocr_data_urls(data_urls: list[str]) -> str:
    """对一组 base64 data URL 逐个 OCR，返回按页拼接的文本。"""
    import base64

    page_texts: list[str] = []
    for i, url in enumerate(data_urls, 1):
        b64_part = url.split(",", 1)[1] if "," in url else url
        img_bytes = base64.b64decode(b64_part)
        text = extract_text_via_mac_vision(img_bytes)
        if text.strip():
            page_texts.append(f"--- Page {i} ---\n{text.strip()}")
    return "\n\n".join(page_texts)


# ---------------------------------------------------------------------------
# FileWatchHandler — watchdog event handler
# ---------------------------------------------------------------------------


class FileWatchHandler(FileSystemEventHandler):
    """Handles file creation and deletion events in the watched directory.

    Uses a dedicated asyncio event loop running in a background thread so
    that async LLM calls work from the synchronous watchdog callback.
    """

    def __init__(
        self,
        loop: asyncio.AbstractEventLoop,
        callback,
        delete_callback=None,
        file_extensions: set[str] | None = None,
    ):
        super().__init__()
        self._loop = loop
        self._callback = callback
        self._delete_callback = delete_callback
        self._extensions = file_extensions or FileParser.SUPPORTED_SUFFIXES
        self._debounce: set[str] = set()  # prevent double-fire

    def on_created(self, event):
        if event.is_directory:
            return
        path = Path(event.src_path)
        if path.suffix.lower() not in self._extensions:
            return
        # skip hidden / temp files
        if path.name.startswith(".") or path.name.startswith("~$"):
            return
        normalized = str(path.resolve())
        if normalized in self._debounce:
            return
        self._debounce.add(normalized)
        # Clear debounce after a short delay
        threading.Timer(2.0, lambda: self._debounce.discard(normalized)).start()

        logger.info(f"New file detected: {path.name}")
        asyncio.run_coroutine_threadsafe(self._callback(path), self._loop)

    def on_deleted(self, event):
        if event.is_directory:
            return
        path = Path(event.src_path)
        # skip hidden / temp files
        if path.name.startswith(".") or path.name.startswith("~$"):
            return
        if self._delete_callback is None:
            return

        logger.info(f"File deleted: {path.name}")
        asyncio.run_coroutine_threadsafe(self._delete_callback(path), self._loop)


# ---------------------------------------------------------------------------
# FileWatcher — public API
# ---------------------------------------------------------------------------


class FileWatcher:
    """Manages the watchdog observer for a configurable directory.

    Usage::

        watcher = FileWatcher()
        watcher.set_services(memo_service, calendar_service)
        watcher.set_on_file(handler)  # async callback(path) → None
        watcher.start("/path/to/watch")
        watcher.stop()
    """

    def __init__(self):
        self._observer: Observer | None = None
        self._thread: threading.Thread | None = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._handler_callback = None
        self._delete_callback = None
        self._watch_dir: Path | None = None
        self._running = False
        self._memo_service = None
        self._calendar_service = None
        self._summarizer = FileSummarizer()

    def set_services(self, memo_service, calendar_service) -> None:
        """Share the server's singleton services to reuse DB connections."""
        self._memo_service = memo_service
        self._calendar_service = calendar_service

    # ------------------------------------------------------------------
    # Start / stop
    # ------------------------------------------------------------------

    def start(self, watch_dir: str | Path, loop: asyncio.AbstractEventLoop | None = None) -> None:
        """Start watching *watch_dir* for new files."""
        self.stop()
        self._watch_dir = Path(watch_dir).resolve()
        self._watch_dir.mkdir(parents=True, exist_ok=True)
        self._loop = loop or asyncio.get_event_loop()

        handler = FileWatchHandler(
            loop=self._loop,
            callback=self._on_file_detected,
            delete_callback=self._on_file_deleted,
        )
        self._observer = Observer()
        self._observer.schedule(handler, str(self._watch_dir), recursive=False)
        self._observer.start()
        self._running = True
        logger.info(f"FileWatcher started, watching: {self._watch_dir}")

    def stop(self) -> None:
        self._running = False
        if self._observer is not None:
            self._observer.stop()
            self._observer.join(timeout=3)
            self._observer = None
            logger.info("FileWatcher stopped")

    @property
    def watch_dir(self) -> Path | None:
        return self._watch_dir

    @property
    def running(self) -> bool:
        return self._running

    # ------------------------------------------------------------------
    # Callbacks
    # ------------------------------------------------------------------

    def set_on_file(self, callback) -> None:
        """Set an async ``callback(path: Path) → None`` for newly detected files."""
        self._handler_callback = callback

    def set_on_file_deleted(self, callback) -> None:
        """Set an async ``callback(path: Path) → None`` for deleted files."""
        self._delete_callback = callback

    async def _on_file_detected(self, path: Path) -> None:
        if self._handler_callback:
            await self._handler_callback(path)

    async def _on_file_deleted(self, path: Path) -> None:
        if self._delete_callback:
            await self._delete_callback(path)

# ---------------------------------------------------------------------------
# Processing pipeline (module-level, reusable)
# ---------------------------------------------------------------------------


class ProcessResult(BaseModel):
    """Result of processing a file through the pipeline."""

    status: Literal["created", "skipped", "error"] = "created"
    type: str | None = None  # always "document" in the new paradigm
    data: dict[str, Any] | None = None  # {parent: {...}, children: {todos: N, schedules: M}}
    reason: str | None = None  # why it was skipped / what error occurred


def _replace_extracted_markers(
    content: str,
    todo_child_ids: list[str],
    schedule_child_ids: list[str],
) -> str:
    """Replace LLM-inserted {extracted:N} markers with jarvis:// scheme links.

    Markers are numbered: first all reminders (0..len(reminders)-1),
    then all schedules (len(reminders)..len(reminders)+len(schedules)-1).
    """
    import re

    total_reminders = len(todo_child_ids)
    total_schedules = len(schedule_child_ids)

    def _replacer(match: re.Match) -> str:
        text = match.group(1)
        n = int(match.group(2))
        if n < total_reminders:
            child_id = todo_child_ids[n]
            return f"[{text}](jarvis://todo/{child_id})"
        elif n < total_reminders + total_schedules:
            child_id = schedule_child_ids[n - total_reminders]
            return f"[{text}](jarvis://schedule/{child_id})"
        else:
            # Marker index out of range — leave as-is
            return match.group(0)

    return re.sub(
        r"\[([^\]]+)\]\{extracted:(\d+)\}",
        _replacer,
        content,
    )


def _parse_target_date(date_str: str | None) -> str:
    """Convert various target_date formats to ISO 8601."""
    if not date_str:
        return datetime.now(timezone.utc).isoformat()
    try:
        dt = datetime.strptime(date_str, "%Y-%m-%d %H:%M:%S")
        return dt.isoformat()
    except ValueError:
        try:
            dt = datetime.strptime(date_str, "%Y-%m-%d")
            return dt.isoformat()
        except ValueError:
            return datetime.now(timezone.utc).isoformat()


