"""
ModelGateway — centralized LLM routing based on task type.

Dynamically assembles API requests with the right model + thinking settings
per task type, following Claude Code's tiered-reasoning design.

Key rules enforced:
1. reasoning_content preservation / stripping per DeepSeek's API contract
2. Tool-call-loop atomicity (same model + thinking across a full ReAct cycle)
3. Flash-for-vision prevention (v4-flash does not support image_url)
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any
from urllib.parse import urlparse

import yaml
from langchain_openai import ChatOpenAI
from loguru import logger
from openai import OpenAI

from .constants import CREDENTIALS_FILE, DEFAULT_PROFILES, MODEL_META


# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------


class TaskType(str, Enum):
    TEXT = "TEXT"
    MULTIMODAL = "MULTIMODAL"


@dataclass
class ModelProfile:
    model: str
    thinking_enabled: bool = False
    thinking_effort: str = "high"  # "high" | "max" (only meaningful when thinking_enabled)
    temperature: float = 0.0


# ---------------------------------------------------------------------------
# Validation — 动态检查模型能力，不再硬编码禁止组合
# ---------------------------------------------------------------------------


def _validate_one(task_type: TaskType, profile: ModelProfile) -> None:
    meta = MODEL_META.get(profile.model, {})
    if task_type == TaskType.MULTIMODAL and not meta.get("supports_vision", False):
        logger.warning(
            f"⚠️ 多模态视觉不可用 | 模型: {meta.get('name', profile.model)} | "
            f"原因: supports_vision=false | "
            f"降级方案: macOS 本地 OCR 提取文字 → TEXT 模型处理 | "
            f"影响: 图片中的图表/排版/格式信息会丢失 | "
            f"建议: 切换为支持 vision 的模型以获得完整多模态体验"
        )
    if profile.thinking_enabled and not meta.get("supports_thinking", False):
        raise ValueError(
            f"{profile.model} does not support thinking. "
            f"Disable thinking or choose a model with supports_thinking=true."
        )


# ---------------------------------------------------------------------------
# Capability warnings — 提示当前任务模型的能力短板
# ---------------------------------------------------------------------------

def _capability_warnings(task_type: TaskType, profile: ModelProfile) -> list[str]:
    """Return human-readable warnings about capability mismatches for a task.

    These are advisory (not blocking) — the gateway will still create the LLM
    if credentials exist, or return None for MULTIMODAL otherwise.
    """
    meta = MODEL_META.get(profile.model, {})
    warnings: list[str] = []

    if task_type == TaskType.MULTIMODAL and not meta.get("supports_vision", False):
        warnings.append(
            f"⚠️ {meta.get('name', profile.model)} 不支持视觉识别"
        )

    return warnings


# ---------------------------------------------------------------------------
# ModelGateway
# ---------------------------------------------------------------------------


class ModelGateway:
    """Centralized LLM router that produces ChatOpenAI instances per task type."""

    def __init__(
        self,
        api_key: str = "",
        base_url: str = "",
        profiles: dict[str, dict[str, Any]] | None = None,
    ):
        self._api_key = api_key
        self._base_url = base_url
        self._cache: dict[str, ChatOpenAI] = {}
        self._profiles: dict[TaskType, ModelProfile] = {}
        self._verified_models: set[str] = set()
        # Multi-credential pool: host → {api_key, base_url}
        self._credentials: dict[str, dict[str, str]] = {}

        # Restore persisted credentials from data/credentials.yaml
        self._load_credentials()

        # If initial api_key/base_url given, seed the pool (overrides persisted)
        if api_key and base_url:
            self.add_credential(api_key, base_url)

        raw = profiles or DEFAULT_PROFILES
        for name, cfg in raw.items():
            task_type = TaskType(name)
            profile = ModelProfile(
                model=cfg["model"],
                thinking_enabled=cfg.get("thinking_enabled", False),
                thinking_effort=cfg.get("thinking_effort", "high"),
                temperature=cfg.get("temperature", 0.0),
            )
            self.set_profile(task_type, profile)

    # ------------------------------------------------------------------
    # Credential pool management
    # ------------------------------------------------------------------

    def add_credential(self, api_key: str, base_url: str) -> str:
        """Add a credential to the pool. Returns the provider key (host)."""
        if not api_key or not base_url:
            raise ValueError("api_key and base_url are required")
        host = urlparse(base_url).netloc
        self._credentials[host] = {"api_key": api_key, "base_url": base_url}

        # Also update the legacy single-credential fields (backward compat)
        self._api_key = api_key
        self._base_url = base_url

        # Clear LLM cache so next get_llm() picks up the new credential
        self._cache.clear()

        # Mark all models from this host as verified
        verified = [
            key for key, meta in MODEL_META.items()
            if urlparse(meta.get("api_base", "")).netloc == host
        ]
        self._verified_models.update(verified)

        logger.info(f"Credential added to pool: host={host}, verified_models={verified}")
        self._save_credentials()
        return host

    def remove_credential(self, host: str) -> bool:
        """Remove a credential from the pool. Returns False if not found."""
        if host not in self._credentials:
            return False
        del self._credentials[host]

        # Un-verify models that only belong to this host (no other credential covers them)
        still_covered: set[str] = set()
        for remaining_host in self._credentials:
            still_covered.update(
                key for key, meta in MODEL_META.items()
                if urlparse(meta.get("api_base", "")).netloc == remaining_host
            )

        self._verified_models = {m for m in self._verified_models if m in still_covered}

        # Update legacy fields to the most recently added credential
        if self._credentials:
            last_host = list(self._credentials.keys())[-1]
            last_cred = self._credentials[last_host]
            self._api_key = last_cred["api_key"]
            self._base_url = last_cred["base_url"]
        else:
            self._api_key = ""
            self._base_url = ""

        self._cache.clear()
        logger.info(f"Credential removed from pool: host={host}")
        self._save_credentials()
        return True

    def _load_credentials(self) -> None:
        """Load persisted credentials from data/credentials.yaml into the pool."""
        if not CREDENTIALS_FILE.exists():
            return
        try:
            with open(CREDENTIALS_FILE, "r", encoding="utf-8") as f:
                data = yaml.safe_load(f)
            if isinstance(data, dict):
                for host, cred in data.items():
                    if isinstance(cred, dict) and "api_key" in cred:
                        self._credentials[host] = {
                            "api_key": cred.get("api_key", ""),
                            "base_url": cred.get("base_url", ""),
                        }
                logger.info(f"Loaded {len(self._credentials)} credentials from {CREDENTIALS_FILE}")
        except Exception as exc:
            logger.warning(f"Failed to load credentials from {CREDENTIALS_FILE}: {exc}")

    def _save_credentials(self) -> None:
        """Persist the current credential pool to data/credentials.yaml."""
        try:
            CREDENTIALS_FILE.parent.mkdir(parents=True, exist_ok=True)
            with open(CREDENTIALS_FILE, "w", encoding="utf-8") as f:
                yaml.safe_dump(dict(self._credentials), f, allow_unicode=True, default_flow_style=False)
            logger.info(f"Saved {len(self._credentials)} credentials to {CREDENTIALS_FILE}")
        except Exception as exc:
            logger.warning(f"Failed to save credentials to {CREDENTIALS_FILE}: {exc}")

    @property
    def available_providers(self) -> dict[str, dict[str, str]]:
        """Return the credential pool. Keyed by host."""
        return dict(self._credentials)

    def has_credential_for_host(self, host: str) -> bool:
        """Check if we have a credential for the given host."""
        if not host:
            return False
        return host in self._credentials

    def has_credential_for_model(self, model_key: str) -> bool:
        """Check if we have a working credential for this model key."""
        meta = MODEL_META.get(model_key, {})
        model_base = meta.get("api_base", "")
        if not model_base:
            return False
        return urlparse(model_base).netloc in self._credentials

    # ------------------------------------------------------------------
    # Legacy credential management (backward compat)
    # ------------------------------------------------------------------

    def update_credentials(self, api_key: str, base_url: str) -> None:
        """Update API key and base URL at runtime. Adds to the credential pool."""
        self.add_credential(api_key, base_url)
        logger.info(f"Gateway credentials updated via update_credentials: base_url={base_url}")

    @property
    def api_key(self) -> str:
        return self._api_key

    @property
    def base_url(self) -> str:
        return self._base_url

    # ------------------------------------------------------------------
    # Provider / credential matching
    # ------------------------------------------------------------------

    def _configured_host(self) -> str:
        """Extract hostname from the configured base_url. Empty string if not set."""
        if not self._base_url:
            return ""
        return urlparse(self._base_url).netloc

    def get_model_provider_match(self, model_key: str) -> bool:
        """Check whether the model's provider has credentials in the pool."""
        meta = MODEL_META.get(model_key, {})
        model_base = meta.get("api_base", "")
        if not model_base:
            return False
        model_host = urlparse(model_base).netloc
        return model_host in self._credentials

    def get_compatible_models(self) -> list[str]:
        """Return model keys whose api_base host has credentials in the pool."""
        if not self._credentials:
            return []
        return [
            key for key, meta in MODEL_META.items()
            if urlparse(meta.get("api_base", "")).netloc in self._credentials
        ]

    # ------------------------------------------------------------------
    # Credential verification (connectivity test)
    # ------------------------------------------------------------------

    def verify_credentials(self, api_key: str, base_url: str) -> dict:
        """Test connectivity with the given credentials.

        On success, automatically adds the credential to the pool.
        """
        if not api_key:
            return {"success": False, "message": "API Key 不能为空", "verified_models": []}
        if not base_url:
            return {"success": False, "message": "API 地址不能为空", "verified_models": []}

        client = OpenAI(api_key=api_key, base_url=base_url, timeout=15.0)

        # Try listing models first (lightweight, no token cost)
        error_msg = ""
        try:
            models = client.models.list()
            count = len(models.data) if hasattr(models, "data") else 0
            logger.info(f"Credential test OK via /models: {count} models available at {base_url}")
        except Exception as exc:
            error_msg = str(exc)
            logger.warning(f"/models check failed for {base_url}: {error_msg}")
            # Fallback: try a minimal chat completion
            try:
                client.chat.completions.create(
                    model="gpt-3.5-turbo",
                    messages=[{"role": "user", "content": "hi"}],
                    max_tokens=1,
                )
                logger.info(f"Credential test OK via chat completion at {base_url}")
            except Exception as exc2:
                error_msg = str(exc2)
                logger.warning(f"Chat completion test also failed for {base_url}: {error_msg}")
                return {
                    "success": False,
                    "message": f"连接测试失败: {error_msg}",
                    "verified_models": [],
                }

        # Add to credential pool
        host = self.add_credential(api_key, base_url)

        verified = [
            key for key, meta in MODEL_META.items()
            if urlparse(meta.get("api_base", "")).netloc == host
        ]

        return {
            "success": True,
            "message": f"连接成功！已将 {host} 添加到可用 LLM 池（{len(verified)} 个模型）",
            "verified_models": verified,
            "host": host,
        }

    def is_model_verified(self, model_key: str) -> bool:
        """Check whether a specific model has been verified via connectivity test."""
        return model_key in self._verified_models

    def get_verified_models(self) -> list[str]:
        """Return all model keys that have passed connectivity verification."""
        return list(self._verified_models)

    # ------------------------------------------------------------------
    # Profile management
    # ------------------------------------------------------------------

    def get_profile(self, task_type: TaskType) -> ModelProfile:
        return self._profiles[task_type]

    def set_profile(self, task_type: TaskType, profile: ModelProfile) -> None:
        _validate_one(task_type, profile)
        self._profiles[task_type] = profile
        self._cache.pop(task_type.value, None)
        logger.info(
            f"Gateway profile updated: {task_type.value} → "
            f"{profile.model} thinking={'enabled' if profile.thinking_enabled else 'disabled'}"
        )

    @property
    def profiles(self) -> dict[TaskType, ModelProfile]:
        return dict(self._profiles)

    def profiles_to_dict(self) -> dict[str, dict[str, Any]]:
        """Return all profiles as a JSON-serializable dict for REST API responses."""
        return {
            key.value: {
                "model": profile.model,
                "thinking_enabled": profile.thinking_enabled,
                "thinking_effort": profile.thinking_effort,
                "temperature": profile.temperature,
            }
            for key, profile in self._profiles.items()
        }

    def is_multimodal_available(self) -> bool:
        """Check whether the MULTIMODAL task has a working LLM with credentials.

        Returns False when no credentials are configured for the MULTIMODAL
        model, meaning image/PDF vision processing will degrade to local OCR.
        """
        try:
            llm = self.get_llm(TaskType.MULTIMODAL)
        except Exception:
            return False
        return llm is not None

    def get_profile_warnings(self, task_type: TaskType) -> list[str]:
        """Return capability warnings for the current profile of a task."""
        profile = self._profiles.get(task_type)
        if profile is None:
            return []
        return _capability_warnings(task_type, profile)

    def get_all_profile_warnings(self) -> dict[str, list[str]]:
        """Return capability warnings for all task types."""
        return {
            tt.value: _capability_warnings(tt, self._profiles[tt])
            for tt in TaskType
        }

    # ------------------------------------------------------------------
    # LLM factory
    # ------------------------------------------------------------------

    def get_llm(self, task_type: TaskType) -> ChatOpenAI | None:
        """Return a cached ChatOpenAI for *task_type*. Safe for stateless calls.

        For MULTIMODAL, returns None when no credentials are configured so
        callers can gracefully degrade to local OCR + TEXT pipeline.
        """
        cache_key = task_type.value
        if cache_key not in self._cache:
            try:
                self._cache[cache_key] = self._create_llm(task_type)
            except ValueError as exc:
                if task_type == TaskType.MULTIMODAL:
                    logger.warning(
                        f"⚠️ 多模态模型不可用，图片/PDF 视觉处理将降级: {exc}"
                    )
                    self._cache[cache_key] = None
                else:
                    raise
        return self._cache[cache_key]

    def create_llm(self, task_type: TaskType) -> ChatOpenAI:
        """Return a fresh ChatOpenAI instance. Use for per-session / stateful calls."""
        return self._create_llm(task_type)

    def _uses_deepseek_thinking(self, model: str) -> bool:
        """Check MODEL_META for whether this model uses DeepSeek-format thinking.

        DeepSeek models send thinking via extra_body and emit reasoning_content
        in responses. Other providers use different mechanisms or none at all.
        """
        meta = MODEL_META.get(model, {})
        return meta.get("thinking_format", "") == "deepseek"

    def _resolve_credential(self, model_key: str) -> tuple[str, str]:
        """Resolve api_key and base_url for a model from the credential pool."""
        meta = MODEL_META.get(model_key, {})
        base_url = (meta.get("api_base", "") or "").strip()

        api_key = ""
        if base_url:
            host = urlparse(base_url).netloc
            cred = self._credentials.get(host, {})
            api_key = cred.get("api_key", "")

        if not base_url:
            base_url = self._base_url

        return api_key, base_url

    def _create_llm(self, task_type: TaskType) -> ChatOpenAI:
        profile = self._profiles[task_type]
        meta = MODEL_META.get(profile.model, {})

        api_key, base_url = self._resolve_credential(profile.model)

        if not api_key:
            provider = meta.get("provider", "未知")
            host_hint = ""
            if base_url:
                host_hint = f"（{urlparse(base_url).netloc}）"
            raise ValueError(
                f"模型 {meta.get('name', profile.model)}（{provider}）{host_hint} 的 API Key 未配置。"
                f"请在设置页面添加该提供商的凭据。"
            )

        extra_body: dict[str, Any] = {}
        if self._uses_deepseek_thinking(profile.model):
            extra_body["thinking"] = (
                {"type": "enabled"} if profile.thinking_enabled else {"type": "disabled"}
            )
            if profile.thinking_enabled:
                extra_body["reasoning_effort"] = profile.thinking_effort
        return ChatOpenAI(
            model=profile.model,
            base_url=base_url,
            api_key=api_key,
            temperature=profile.temperature,
            extra_body=extra_body if extra_body else None,
        )


# ---------------------------------------------------------------------------
# Module-level singleton
# ---------------------------------------------------------------------------

_gateway: ModelGateway | None = None


def init_gateway(
    api_key: str = "",
    base_url: str = "",
    profiles: dict | None = None,
) -> ModelGateway:
    """Initialize (or re-initialize) the global ModelGateway singleton."""
    global _gateway
    _gateway = ModelGateway(api_key=api_key, base_url=base_url, profiles=profiles)
    logger.info("ModelGateway initialized")

    # 启动时检查多模态可用性
    mm_llm = _gateway.get_llm(TaskType.MULTIMODAL)
    if mm_llm is None:
        mm_profile = _gateway.get_profile(TaskType.MULTIMODAL)
        mm_meta = MODEL_META.get(mm_profile.model, {})
        logger.warning(
            f"⚠️⚠️⚠️ 多模态视觉功能未启用 ⚠️⚠️⚠️\n"
            f"  模型: {mm_meta.get('name', mm_profile.model)}\n"
            f"  原因: 该模型的 API Key 未配置或凭据无效\n"
            f"  影响: 图片/PDF/Office 文件的视觉识别功能不可用\n"
            f"  降级: macOS 本地 OCR 将尝试提取文字（会丢失图表/排版信息）\n"
            f"  修复: 在设置页面为 {mm_meta.get('provider', '该提供商')} 添加 API Key 并测试连接\n"
            f"  注意: 纯文本对话和文件处理不受影响"
        )
    else:
        mm_profile = _gateway.get_profile(TaskType.MULTIMODAL)
        mm_meta = MODEL_META.get(mm_profile.model, {})
        if not mm_meta.get("supports_vision", False):
            logger.warning(
                f"⚠️ 多模态槽位使用非视觉模型 | "
                f"模型: {mm_meta.get('name', mm_profile.model)} | "
                f"supports_vision={mm_meta.get('supports_vision', False)}"
            )

    return _gateway


def get_gateway() -> ModelGateway:
    if _gateway is None:
        raise RuntimeError(
            "ModelGateway not initialized. Call init_gateway() before using any LLM."
        )
    return _gateway
