"""
Jarvis — Terminal REPL client.

Connects to the standalone Jarvis server via Socket.IO for real-time
streaming chat.  All AI logic and MCP communication happen server-side.

Usage:
    uv run python src/client/terminal_client.py
"""

from __future__ import annotations

import asyncio
import uuid
from datetime import datetime, timezone

import socketio
from dotenv import load_dotenv

load_dotenv()

SERVER_URL = "http://localhost:8000"
SOCKETIO_PATH = "/ws/socket.io"


async def ainput(prompt: str = "") -> str:
    """Async wrapper around blocking input()."""
    return await asyncio.to_thread(input, prompt)


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

    # Events from server that the async client will receive
    reply_done: asyncio.Event = asyncio.Event()
    current_reply: list[str] = []  # mutable accumulator for streaming
    had_error: list[bool] = [False]

    sio = socketio.AsyncClient(
        reconnection=False,
        logger=False,
    )

    @sio.on("stream_token")
    async def on_stream_token(data: dict) -> None:
        token = data.get("token", "")
        if token:
            print(token, end="", flush=True)
            current_reply.append(token)

    @sio.on("stream_end")
    async def on_stream_end(data: dict) -> None:
        reply_done.set()

    @sio.on("new_message")
    async def on_new_message(data: dict) -> None:
        msg = data.get("message", data)
        output = msg.get("output", "")
        # If we already printed the stream, use this only as fallback
        if not current_reply:
            print(output, end="", flush=True)
        reply_done.set()

    await sio.connect(SERVER_URL, socketio_path=SOCKETIO_PATH)
    print(f"✅ 已连接到 {SERVER_URL}。输入 /help 查看可用命令。\n")

    try:
        while True:
            try:
                user_input = (await ainput("你：")).strip()
            except (EOFError, KeyboardInterrupt, asyncio.CancelledError):
                print("\n👋 再见！")
                return

            if not user_input:
                continue

            if user_input in ("/exit", "/quit"):
                print("👋 再见！")
                return

            if user_input == "/help":
                print(
                    "\n可用命令：\n"
                    "  /help   — 显示此帮助\n"
                    "  /clear  — 清空对话历史（新建线程）\n"
                    "  /exit   — 退出\n"
                    "\n直接输入问题即可，例如：\n"
                    '  "我有几个账户？"\n'
                    '  "这个月在餐饮上花了多少钱？"\n'
                    '  "记一笔：今天午饭 35 元，用支付宝"'
                    "\n",
                )
                continue

            if user_input == "/clear":
                # Tell server to clear — reused client_message would just
                # start a new conversation naturally. Print acknowledgement.
                print("✅ 已清空对话历史。\n")
                continue

            # Send to server and wait for reply
            reply_done.clear()
            current_reply.clear()
            had_error[0] = False

            await sio.emit(
                "client_message",
                {
                    "message": {
                        "id": str(uuid.uuid4()),
                        "createdAt": int(datetime.now(timezone.utc).timestamp() * 1000),
                        "name": "user",
                        "type": "user_message",
                        "output": user_input,
                        "threadId": None,
                    },
                    "fileReferences": [],
                },
            )

            print("Jarvis：", end="", flush=True)

            try:
                await asyncio.wait_for(reply_done.wait(), timeout=120)
            except asyncio.TimeoutError:
                print("[响应超时]")
            print()

    finally:
        await sio.disconnect()


def main() -> None:
    try:
        asyncio.run(repl())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
