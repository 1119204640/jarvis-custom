"""
Jarvis — Chainlit web client.

Usage:
    uv run chainlit run src/client/chainlit_web.py
"""

import chainlit as cl
from langchain_core.messages import AIMessage, HumanMessage
from loguru import logger

from src.server.agent import Agent


@cl.on_chat_start
async def on_chat_start() -> None:
    agent = Agent()
    await agent.connect()
    cl.user_session.set("agent", agent)
    cl.user_session.set("history", [])

    await cl.Message(
        content=(
            "# ✅ Jarvis 已就绪\n\n"
            "已连接到 Actual Budget。你可以问我：\n\n"
            '- "我有几个账户？"\n'
            '- "这个月在餐饮上花了多少钱？"\n'
            '- "记一笔：今天午饭 35 元，用支付宝"\n'
            '- `/clear` — 清空对话历史'
        )
    ).send()


@cl.on_chat_end
async def on_chat_end() -> None:
    agent: Agent | None = cl.user_session.get("agent")
    if agent is not None:
        await agent.disconnect()
        logger.info("Agent disconnected")


@cl.on_message
async def on_message(message: cl.Message) -> None:
    agent: Agent = cl.user_session.get("agent")
    history: list = cl.user_session.get("history")

    user_input = message.content.strip()

    if user_input == "/clear":
        history.clear()
        cl.user_session.set("history", history)
        await cl.Message(content="✅ 对话历史已清空。").send()
        return

    msg = cl.Message(content="")
    await msg.send()

    try:
        full_reply = ""
        async for chunk in agent.astream(user_input, history):
            await msg.stream_token(chunk)
            full_reply += chunk

        await msg.update()

        history.append(HumanMessage(content=user_input))
        history.append(AIMessage(content=full_reply))
        cl.user_session.set("history", history)

    except Exception as e:
        logger.error(f"Agent error: {e}")
        await msg.update()
        await cl.ErrorMessage(content=f"出错了：{e}").send()
