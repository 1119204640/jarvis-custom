"""
Jarvis — Personal AI assistant entry point.

Usage:
    uv run python src/main.py
"""

import asyncio

from dotenv import load_dotenv
from langchain_core.messages import HumanMessage, AIMessage
from loguru import logger

load_dotenv()

from server.agent import Agent


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


async def ainput(prompt: str = "") -> str:
    """Async wrapper around blocking input()."""
    return await asyncio.to_thread(input, prompt)


# ---------------------------------------------------------------------------
# Interactive REPL
# ---------------------------------------------------------------------------


async def repl() -> None:
    print("╔══════════════════════════════════════════╗")
    print("║   Jarvis — Actual Budget AI Assistant    ║")
    print("╠══════════════════════════════════════════╣")
    print("║  命令：                                   ║")
    print("║    /help   — 显示帮助信息                  ║")
    print("║    /clear  — 清空对话历史                  ║")
    print("║    /exit   — 完全退出程序                  ║")
    print("╚══════════════════════════════════════════╝")
    print()

    agent = Agent()
    history: list = []

    try:
        await agent.connect()
        print("✅ 已连接到 Actual Budget。输入 /help 查看可用命令。\n")

        while True:
            try:
                user_input = (await ainput("你：")).strip()
            except (EOFError, KeyboardInterrupt, asyncio.CancelledError):
                print("\n👋 再见！")
                return

            if not user_input:
                continue

            # Commands
            if user_input == "/exit" or user_input == "/quit":
                print("👋 再见！")
                return
            if user_input == "/help":
                print(
                    "\n可用命令：\n"
                    "  /help   — 显示此帮助\n"
                    "  /clear  — 清空对话历史\n"
                    "  /exit   — 退出\n"
                    "\n直接输入问题即可，例如：\n"
                    '  "我有几个账户？"\n'
                    '  "这个月在餐饮上花了多少钱？"\n'
                    '  "记一笔：今天午饭 35 元，用支付宝"'
                    "\n",
                )
                continue
            if user_input == "/clear":
                history.clear()
                print("✅ 对话历史已清空。\n")
                continue

            # Send to agent
            try:
                print("Jarvis：", end="", flush=True)
                full_reply = ""
                async for chunk in agent.astream(user_input, history):
                    print(chunk, end="", flush=True)
                    full_reply += chunk
                print()

                history.append(HumanMessage(content=user_input))
                history.append(AIMessage(content=full_reply))

            except Exception as e:
                logger.error(f"Agent error: {e}")
                print(f"\n❌ 出错了：{e}\n")

    finally:
        await agent.disconnect()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> None:
    try:
        asyncio.run(repl())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
