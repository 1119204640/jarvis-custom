"""
Actual Budget Agent — LLM-powered financial assistant.

Uses LangGraph ReAct agent + DeepSeek to control Actual Budget via natural
language.  Every tool is discovered dynamically from the MCP server — no
per-tool hardcoding.
"""

from __future__ import annotations

from datetime import datetime

from langchain.agents import create_agent
from langchain_openai import ChatOpenAI
from langchain_core.messages import HumanMessage
from loguru import logger

from server.actual_api import ActualBudgetClient
from server.constants import LLM_MODEL, LLM_KEY, LLM_URL, SYSTEM_PROMPT


class Agent:
    """ReAct agent that controls Actual Budget via MCP tools."""

    def __init__(self):
        self.client = ActualBudgetClient()
        self.llm = ChatOpenAI(
            model=LLM_MODEL,
            base_url=LLM_URL,
            api_key=LLM_KEY,
            temperature=0,
            extra_body={"thinking": {"type": "disabled"}},
        )
        self.agent = None  # built lazily in connect()

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    async def connect(self) -> None:
        """Connect to MCP and build the agent graph with discovered tools."""
        logger.info("Connecting to Actual Budget MCP server...")
        await self.client.connect()

        tools = await self.client.to_langchain_tools()
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
        await self.client.disconnect()

    # ------------------------------------------------------------------
    # Chat
    # ------------------------------------------------------------------

    async def achat(self, message: str, history: list | None = None) -> str:
        """Non-streaming chat. Returns the agent's reply as a string."""
        self._ensure_ready()
        messages: list = (history or []) + [HumanMessage(content=message)]
        result = await self.agent.ainvoke({"messages": messages})
        return result["messages"][-1].content

    async def astream(self, message: str, history: list | None = None):
        """Stream the agent's reply, yielding text chunks."""
        self._ensure_ready()
        messages: list = (history or []) + [HumanMessage(content=message)]
        async for event in self.agent.astream_events(
            {"messages": messages}, version="v2"
        ):
            if event.get("event") == "on_chat_model_stream":
                content = event["data"]["chunk"].content
                if content:
                    yield content

    def _ensure_ready(self) -> None:
        if self.agent is None:
            raise RuntimeError("Agent not built yet. Call `await agent.connect()` first.")
