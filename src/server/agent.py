"""
Jarvis Agent — LLM-powered personal assistant.

Uses LangGraph ReAct agent + DeepSeek for natural language interaction.
The LLM instance is provided externally via the ModelGateway so that task-type
routing (model + thinking settings) is centralized.
"""

from __future__ import annotations

from datetime import datetime

from langchain.agents import create_agent
from langchain_openai import ChatOpenAI
from langchain_core.messages import HumanMessage
from loguru import logger

from .constants import SYSTEM_PROMPT


class Agent:
    """ReAct agent for asset (vault), todo, calendar, and file management."""

    def __init__(self, llm: ChatOpenAI, extra_tools: list | None = None):
        self.extra_tools = extra_tools or []
        self.llm = llm
        self.agent = None  # built lazily in connect()

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    async def connect(self) -> None:
        """Build the agent graph with provided tools."""
        tools = self.extra_tools
        logger.info(f"Building agent with {len(tools)} tools")

        now = datetime.now().astimezone()
        tz_name = now.tzname()
        time_hint = (
            f"\n\n当前时间：{now.strftime('%Y年%m月%d日 %H:%M:%S')}"
            f"（{now.strftime('%A')}，时区 {tz_name}）。"
            f"涉及日期、时间、时间范围的问题时，以此时间为准。"
        )

        self.agent = create_agent(
            self.llm,
            tools,
            system_prompt=SYSTEM_PROMPT + time_hint,
        )

    async def disconnect(self) -> None:
        pass

    # ------------------------------------------------------------------
    # Chat
    # ------------------------------------------------------------------

    async def achat(self, message: str) -> dict:
        """Non-streaming chat. Returns {"content": str, "reasoning_content": str|None}."""
        self._ensure_ready()
        result = await self.agent.ainvoke({"messages": [HumanMessage(content=message)]})
        final_msg = result["messages"][-1]
        reasoning = None
        if hasattr(final_msg, "additional_kwargs"):
            reasoning = final_msg.additional_kwargs.get("reasoning_content")
        return {"content": final_msg.content, "reasoning_content": reasoning}

    async def astream(self, message: str):
        """Stream the agent's reply, yielding text chunks and status dicts.

        Yields:
            str — text token from the LLM
            dict — progress event: {"type": "tool_start"|"tool_end", "message": str}
        """
        self._ensure_ready()
        async for event in self.agent.astream_events(
            {"messages": [HumanMessage(content=message)]}, version="v2"
        ):
            kind = event.get("event")
            if kind == "on_chat_model_stream":
                content = event["data"]["chunk"].content
                if content:
                    yield content
            elif kind == "on_tool_start":
                tool_name = event.get("name", "unknown")
                yield {"type": "tool_start", "message": f"调用工具: {tool_name}"}
            elif kind == "on_tool_end":
                tool_name = event.get("name", "unknown")
                yield {"type": "tool_end", "message": f"工具完成: {tool_name}"}

    def _ensure_ready(self) -> None:
        if self.agent is None:
            raise RuntimeError("Agent not built yet. Call `await agent.connect()` first.")
