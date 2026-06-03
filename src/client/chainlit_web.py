"""
Jarvis — Chainlit web client.

Usage:
    uv run chainlit run src/client/chainlit_web.py
"""

import chainlit as cl
from loguru import logger

from src.server.agent import Agent
from src.server.gateway import TaskType, get_gateway, init_gateway

# Initialize the global ModelGateway singleton at module import time
_init_gw = init_gateway()


@cl.on_chat_start
async def on_chat_start() -> None:
    gw = get_gateway()
    agent_llm = gw.create_llm(TaskType.MULTIMODAL)
    agent = Agent(llm=agent_llm)
    await agent.connect()
    cl.user_session.set("agent", agent)

    await cl.Message(
        content=(
            "# Jarvis 已就绪\n\n"
            "我可以帮你管理备忘录、提醒事项和日程。你可以问我：\n\n"
            '- "帮我记个备忘录：明天开会讨论项目进度"\n'
            '- "这周有哪些待办提醒？"\n'
            '- "查看我的日程安排"\n'
            '- "随时告诉我你需要什么"'
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

    user_input = message.content.strip()

    msg = cl.Message(content="")
    await msg.send()

    try:
        full_reply = ""
        async for chunk in agent.astream(user_input):
            await msg.stream_token(chunk)
            full_reply += chunk

        await msg.update()

    except Exception as e:
        logger.error(f"Agent error: {e}")
        await msg.update()
        await cl.ErrorMessage(content=f"出错了：{e}").send()
