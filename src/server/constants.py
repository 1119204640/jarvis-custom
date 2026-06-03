"""
应用常量 — 从 models.yaml 加载模型配置。

models.yaml 是用户可编辑的模型配置表，修改后重启服务器即可生效。
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml
from dotenv import load_dotenv
from loguru import logger

# 无论终端在哪里启动，这行代码都会根据 constants.py 的实际位置，精准计算出根目录
ROOT_DIR = Path(__file__).resolve().parent.parent.parent
DATA_DIR = ROOT_DIR / "data"
CREDENTIALS_FILE = DATA_DIR / "credentials.yaml"
CONFIG_FILE = DATA_DIR / "config.yaml"
load_dotenv(dotenv_path=ROOT_DIR / ".env")

# ---------------------------------------------------------------------------
# 从 models.yaml 加载模型元数据（API Key 通过设置页面填入，保存在 data/credentials.yaml）
# ---------------------------------------------------------------------------

_REQUIRED_TASKS = ("TEXT", "MULTIMODAL")


def _load_yaml_config() -> tuple[
    dict[str, dict[str, Any]],
    dict[str, dict[str, Any]],
]:
    yaml_path = ROOT_DIR / "models.yaml"

    if not yaml_path.exists():
        raise FileNotFoundError(
            f"找不到模型配置文件，期望路径: {yaml_path}\n"
            "请确保项目根目录下存在 models.yaml 配置文件。"
        )

    logger.info(f"Loading model config from: {yaml_path.name}")

    with open(yaml_path, "r", encoding="utf-8") as f:
        raw = yaml.safe_load(f)
    if not isinstance(raw, dict):
        raise ValueError(f"{yaml_path.name} 顶层必须是字典")

    # ---- 解析 models 段 ----
    raw_models: dict[str, Any] = raw.get("models", {}) or {}
    model_meta: dict[str, dict[str, Any]] = {}

    for model_id, cfg in raw_models.items():
        if not isinstance(cfg, dict):
            continue
        model_meta[model_id] = {
            "name": cfg.get("name", model_id),
            "desc": cfg.get("desc", ""),
            "api_base": cfg.get("api_base", ""),
            "provider": cfg.get("provider", ""),
            "supports_vision": bool(cfg.get("supports_vision", False)),
            "supports_thinking": bool(cfg.get("supports_thinking", False)),
            "thinking_format": cfg.get("thinking_format", ""),
            "formats": cfg.get("formats", {}),
        }

    # ---- 解析 profiles 段 ----
    raw_profiles: dict[str, Any] = raw.get("profiles", {}) or {}
    default_profiles: dict[str, dict[str, Any]] = {}

    for task_name, cfg in raw_profiles.items():
        if not isinstance(cfg, dict):
            continue
        default_profiles[task_name.upper()] = {
            "model": cfg.get("model", ""),
            "thinking_enabled": bool(cfg.get("thinking_enabled", False)),
            "thinking_effort": cfg.get("thinking_effort", "high"),
            "temperature": float(cfg.get("temperature", 0.0)),
        }

    # 确保四个任务类型都存在
    for task in _REQUIRED_TASKS:
        if task not in default_profiles:
            raise ValueError(
                f"models.yaml 的 profiles 段缺少必需的任务类型: {task}\n"
                f"需要配置: {', '.join(_REQUIRED_TASKS)}"
            )

    return model_meta, default_profiles


_MODEL_META, _DEFAULT_PROFILES = _load_yaml_config()

# 模块级常量
MODEL_META = _MODEL_META
DEFAULT_PROFILES = _DEFAULT_PROFILES

# ---------------------------------------------------------------------------
# Prompt 模板
# ---------------------------------------------------------------------------

# 文件处理并发上限
MAX_CONCURRENT_FILE_PROCESSING = 10

CLASSIFY_PROMPT = """你是一个智能文档处理助手。用户提交了一个文件，你需要将其作为**文档库中的一篇文档**进行处理。

## 你的任务（按顺序执行）

1. **通读全文**，理解内容的深层含义和结构
2. **为文档生成元数据**：title、summary、content（详细 markdown 摘要）、tags
3. **扫描可执行项**：识别文档中嵌入的待办事项，逐条填入 reminders 列表（没有则为空）
4. **扫描日程安排**：识别文档中提到的时间事件，逐条填入 schedules 列表（没有则为空）
5. **标记原文位置**：在 content 中对识别出的待办/日程的**对应原文句子**用 {extracted:N} 标记

## 核心原则

- 每个文件都是文档库中的一篇文档，你永远是先创建文档，再从中识别子项
- reminders 和 schedules 是**可选的**——识别不到就留空，不要强行捏造
- 文件名是用户的**强意图信号**，应体现在 title 和 tags 中

## 字段说明（全部必填）

### title
- 文档标题，取文件名或提炼文档核心主题，不超过 200 字

### summary
- 一句话核心摘要，不超过 200 字，用于列表展示

### content（重要）
- 详细的 markdown 格式摘要，篇幅与原文长度成正比：
  - 原文 < 500 字 → 摘要 100-300 字，保留核心要点
  - 原文 500-2000 字 → 摘要 300-800 字，分点梳理结构
  - 原文 2000-8000 字 → 摘要 800-2000 字，按章节/主题分段总结
  - 原文 > 8000 字 → 摘要 2000-4000 字，全面覆盖各部分要点
- 摘要应包含：核心论点、关键数据、日期、人名、术语、逻辑结构、值得注意的细节
- 用 markdown 标题、列表、加粗等格式组织，结构清晰易读
- **关键**：对于被识别为待办或日程的原文句子，用 `[原文句子]{{extracted:N}}` 格式标记
  - N 是 reminders 或 schedules 数组中的索引（从 0 开始）
  - 先编号所有 reminders（0, 1, 2...），再接着编号所有 schedules（从 reminders 长度开始）
  - 示例：如果提取了 2 个待办和 1 个日程，则待办编号 0、1，日程编号 2
  - 示例标记：`需要在[周五前完成项目报告]{{extracted:0}}，下周还要[参加团队周会]{{extracted:2}}`
- **不要**只是简单概括，要真正「消化」内容后再输出

### tags
- 提取 1-5 个中文关键词标签

### reminders（可选）
- 从文档中识别出的待办事项列表，逐条列出
- 每条包含：
  - title: 简洁明确的待办标题，不超过 200 字
  - context: 文档中该待办对应的**原文句子**（与 content 中标记的句子一致）
  - due_date: 格式 YYYY-MM-DD 或 YYYY-MM-DD HH:MM:SS，无法推断时填 null
  - priority: 紧迫且明确截止日期 → "high"，有截止但不急 → "medium"，无明确日期 → "low"
- 识别标准：待办清单格式（- [ ]、复选框等）、需要跟进的行动项、逐条列出的任务
- **如果文档中没有待办事项，留空 []**

### schedules（可选）
- 从文档中识别出的日程安排列表，逐条列出
- 每条包含：
  - title: 简洁明确的日程标题
  - context: 文档中该日程对应的**原文句子**（与 content 中标记的句子一致）
  - target_date: 格式 YYYY-MM-DD HH:MM:SS 或 YYYY-MM-DD
- 识别标准：含具体时间的未来计划（预约、会议、出行等）或过去记录（会议纪要、日志等）
- **如果文档中没有日程安排，留空 []**

### target_date
- 保留字段，始终填 null

## 完整示例

假设原文是：
```
项目进度报告
本周完成了API开发，需要在周五前提交代码审查。
下周一上午10点参加项目复盘会议。
```

则输出：
- title: "项目进度报告"
- summary: "本周完成API开发，周五前需提交代码审查，下周一有复盘会议"
- content: "## 项目进度报告\n\n本周完成了API开发工作。需要在[周五前提交代码审查]{{extracted:0}}。下周一[上午10点参加项目复盘会议]{{extracted:1}}。"
- tags: ["项目管理", "开发", "复盘"]
- reminders: [{"title": "提交代码审查", "context": "周五前提交代码审查", "due_date": "2026-06-06", "priority": "high"}]
- schedules: [{"title": "项目复盘会议", "context": "上午10点参加项目复盘会议", "target_date": "2026-06-09 10:00:00"}]
- target_date: null
"""

SYSTEM_PROMPT = """\
你是一个专业的个人AI助手，名叫 Jarvis。你可以帮助用户管理文档库、待办事项和日程。

## 文档库（保险库）
- 文档库是所有信息的母节点，每个文件或笔记都是一篇文档
- 创建、查看、搜索、更新、删除文档
- 每篇文档包含标题、正文（Markdown格式）和标签
- 可使用标签对文档分类（如"工作"、"个人"、"学习"）
- 支持按关键字搜索标题和正文内容
- 系统会自动分析文档内容，识别其中的待办事项和日程作为子节点

## 待办事项
- 待办事项是文档的子节点，由系统从文档中自动识别或用户手动创建
- 创建、查看、更新、删除待办事项
- 每条待办包含标题、描述、到期日期和优先级（low/medium/high）
- 可查看即将到期的待办（默认未来7天）
- 可将待办标记为已完成
- 可按状态（pending/completed）筛选待办
- 查看待办时可跳转回其所属的母文档

## 日程
- 日程也可以是文档的子节点，由系统从文档中自动识别或用户手动创建
- 查看、创建、更新、删除日程
- 每条日程包含标题、描述、开始/结束时间、是否全天
- 可按时间范围筛选日程
- 支持从 Google Calendar 同步日程（通过同步功能）
- 查看日程时可跳转回其所属的母文档

## 通用规则
- 金额单位以工具描述为准（有的用元/小数，有的用分/整数）
- 日期格式 YYYY-MM-DD 或 YYYY-MM-DD HH:MM
- 回答简洁，用中文
- 涉及写操作（创建/修改/删除）时，先向用户确认再执行
- 调用工具前，如果缺少必填参数，先查相关工具获取或向用户询问
"""
