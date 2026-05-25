"""
Actual Budget API client — thin MCP SSE transport.

Connects to a running actual-mcp SSE server, discovers tools dynamically,
and converts them to LangChain StructuredTool objects on the fly.

No per-tool hardcoding — every tool the MCP server exposes is
automatically available to the agent.
"""

from __future__ import annotations

import re
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from typing import Any

from langchain_core.tools import StructuredTool
from mcp import ClientSession
from mcp.client.sse import sse_client
from mcp.types import CallToolResult, Tool
from pydantic import BaseModel, Field, create_model
from loguru import logger

from server.constants import ACTUAL_API_URL

# ---------------------------------------------------------------------------
# JSON Schema → Pydantic model
# ---------------------------------------------------------------------------
# Handles the subset of JSON Schema that Zod → toJSONSchema produces.
# Covers: string, number, integer, boolean, array, nested object, $ref, anyOf.

_JSON_TYPE_MAP: dict[str, type] = {
    "string": str,
    "number": float,
    "integer": int,
    "boolean": bool,
}


def _extract_ref_name(ref: str) -> str:
    return ref.rsplit("/", 1)[-1]


def _field_name_safe(name: str) -> str:
    """Avoid collisions with Pydantic reserved names like 'id' on inner models."""
    return f"{name}_" if name in ("id",) else name


def _json_type_to_python(schema: dict, defs: dict | None = None) -> type:  # noqa: C901
    """Convert a JSON Schema property dict to a Python type."""
    if "$ref" in schema and defs is not None:
        ref_name = _extract_ref_name(schema["$ref"])
        if ref_name in defs:
            return _json_schema_to_pydantic_model(ref_name, defs[ref_name], defs)
        return dict

    if "anyOf" in schema:
        for opt in schema["anyOf"]:
            if opt.get("type") != "null":
                return _json_type_to_python(opt, defs)
        return str

    t = schema.get("type", "string")

    # Handle JSON Schema union types like ["string", "null"] — pick first non-null type
    if isinstance(t, list):
        for item in t:
            if item != "null":
                t = item
                break
        else:
            t = "string"

    if t == "array":
        items = schema.get("items", {})
        item_type = _json_type_to_python(items, defs)
        return list[item_type]  # type: ignore[valid-type]

    if t == "object" and "properties" in schema:
        return _json_schema_to_pydantic_model(
            schema.get("title", "Nested"), schema, defs
        )

    return _JSON_TYPE_MAP.get(t, str)


def _json_schema_to_pydantic_model(
    name: str, schema: dict, defs: dict | None = None
) -> type[BaseModel]:
    """Recursively convert a JSON Schema object to a Pydantic BaseModel."""
    properties = schema.get("properties", {})
    required: set[str] = set(schema.get("required", []))
    defs = defs or schema.get("$defs", {})

    fields: dict[str, Any] = {}
    for field_name, field_schema in properties.items():
        py_type = _json_type_to_python(field_schema, defs)
        desc = field_schema.get("description", "")
        safe_name = _field_name_safe(field_name)
        if field_name not in required:
            default = field_schema.get("default", None)
            fields[safe_name] = (py_type | None, Field(default, description=desc))
        else:
            fields[safe_name] = (py_type, Field(..., description=desc))

    safe_name = re.sub(r"[^a-zA-Z0-9]", "_", name) or "ToolInput"
    return create_model(safe_name, **fields)  # type: ignore[call-overload]


def _name_pascal(name: str) -> str:
    """kebab-case → PascalCase: 'get-accounts' → 'GetAccounts'."""
    return "".join(part.capitalize() for part in name.replace("-", "_").split("_"))


# ---------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------


@dataclass
class ActualBudgetClient:
    """Async client for Actual Budget via MCP SSE.

    Usage::

        client = ActualBudgetClient()
        await client.connect()
        tools = await client.to_langchain_tools()   # dynamic discovery
        # ... pass tools to your LLM agent ...
        result = await client.call_tool("get-accounts", {})
        await client.disconnect()
    """

    mcp_url: str = ACTUAL_API_URL
    _transport: Any = field(default=None, init=False, repr=False)
    _session: ClientSession | None = field(default=None, init=False, repr=False)
    _read: Any = field(default=None, init=False, repr=False)
    _write: Any = field(default=None, init=False, repr=False)

    # ------------------------------------------------------------------
    # Connection lifecycle
    # ------------------------------------------------------------------

    async def connect(self) -> None:
        """Open SSE transport and initialise MCP session."""
        if self._session is not None:
            return
        logger.info(f"Creating SSE transport to {self.mcp_url} ...")
        self._transport = sse_client(url=self.mcp_url)    # 一条 websocket 通道
        logger.info("Entering SSE context (awaiting endpoint event) ...")
        self._read, self._write = await self._transport.__aenter__()  # 发起 SSE 连接
        logger.info("SSE transport established, creating session ...")
        self._session = ClientSession(self._read, self._write) # 一个会话
        await self._session.__aenter__()  # 启动 _receive_loop（消息接收循环）
        logger.info("Initializing MCP session ...")
        await self._session.initialize()
        logger.info(f"Connected to MCP server at {self.mcp_url}")

    async def disconnect(self) -> None:
        if self._session is None:
            return
        await self._session.__aexit__(None, None, None)
        self._session = None
        await self._transport.__aexit__(None, None, None)
        self._transport = None
        self._read = None
        self._write = None
        logger.info("Disconnected from MCP server")

    @asynccontextmanager
    async def session(self):
        """Context manager that keeps a single long-lived session."""
        await self.connect()
        try:
            yield self
        finally:
            await self.disconnect()

    # ------------------------------------------------------------------
    # Generic tool execution
    # ------------------------------------------------------------------

    async def call_tool(self, name: str, arguments: dict[str, Any] | None = None) -> str:
        """Call any MCP tool by name and return its text content."""
        if self._session is None:
            raise RuntimeError("Not connected. Call `await client.connect()` first.")
        result: CallToolResult = await self._session.call_tool(name, arguments or {})
        parts: list[str] = []
        for block in result.content:
            if hasattr(block, "text"):
                parts.append(block.text)
        return "\n".join(parts)

    # ------------------------------------------------------------------
    # Dynamic tool discovery → LangChain tools
    # ------------------------------------------------------------------

    async def list_tools_raw(self) -> list[Tool]:
        """Return the raw MCP Tool objects (name, description, inputSchema)."""
        if self._session is None:
            raise RuntimeError("Not connected.")
        return list((await self._session.list_tools()).tools)

    async def to_langchain_tools(self) -> list[StructuredTool]:
        """Discover all MCP tools and convert them to LangChain StructuredTool instances.

        This is the key — no hardcoded per-tool methods. When actual-mcp
        adds or removes tools, the agent picks them up automatically.
        """
        mcp_tools = await self.list_tools_raw()
        logger.info(f"Discovered {len(mcp_tools)} MCP tools")
        lc_tools: list[StructuredTool] = []

        for mt in mcp_tools:
            try:
                lc_tools.append(self._mcp_to_langchain_tool(mt))
            except Exception:
                logger.opt(exception=True).warning(
                    f"Failed to convert MCP tool '{mt.name}' to LangChain tool"
                )

        return lc_tools

    def _mcp_to_langchain_tool(self, mt: Tool) -> StructuredTool:
        """Convert a single MCP Tool to a LangChain StructuredTool."""
        schema = mt.inputSchema
        model_name = _name_pascal(mt.name) + "Input"
        args_model = _json_schema_to_pydantic_model(model_name, schema)

        async def _handler(**kwargs: Any) -> str:
            clean = {k: v for k, v in kwargs.items() if v is not None}
            return await self.call_tool(mt.name, clean)

        return StructuredTool(
            name=mt.name,
            description=mt.description or "",
            args_schema=args_model,
            coroutine=_handler,
        )
