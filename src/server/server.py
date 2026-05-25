"""
Jarvis — standalone FastAPI + Socket.IO server.

Provides a single backend that all clients (Flutter, terminal REPL,
Chainlit) can connect to.  Wraps the Agent so clients speak one unified
Socket.IO protocol regardless of their platform.

Usage:
    uv run python -m src.server.server
    uv run uvicorn src.server.server:app --host 0.0.0.0 --port 8000
"""

from __future__ import annotations

import asyncio
import signal
import sys
import threading
import uuid
from datetime import datetime, timezone

import socketio
import uvicorn
from dotenv import load_dotenv
from loguru import logger

load_dotenv()

from .agent import Agent

# ---------------------------------------------------------------------------
# Socket.IO server (ASGI mode so it mounts on FastAPI / uvicorn)
# ---------------------------------------------------------------------------

sio = socketio.AsyncServer(
    async_mode="asgi",
    cors_allowed_origins="*",
    logger=False,
)

# Reference to the uvicorn Server instance so the /stop endpoint can signal
# graceful shutdown from within a request handler.
_server_instance: uvicorn.Server | None = None

# Per-session state: sid → {agent, history, stream_task}
_sessions: dict[str, dict] = {}

# ---------------------------------------------------------------------------
# Connection lifecycle
# ---------------------------------------------------------------------------


@sio.event
async def connect(sid: str, environ: dict) -> None:
    qs = environ.get("QUERY_STRING", "")
    logger.info(f"Socket.IO connect sid={sid} query={qs}")

    agent = Agent()
    await agent.connect()
    _sessions[sid] = {
        "agent": agent,
        "history": [],
        "stream_task": None,
    }
    await sio.emit("connection_ok", {"sid": sid}, to=sid)


@sio.event
async def disconnect(sid: str) -> None:
    logger.info(f"Socket.IO disconnect sid={sid}")
    session = _sessions.pop(sid, None)
    if session is None:
        return
    if session["stream_task"] and not session["stream_task"].done():
        session["stream_task"].cancel()
    await session["agent"].disconnect()


# ---------------------------------------------------------------------------
# Chat
# ---------------------------------------------------------------------------


@sio.event
async def client_message(sid: str, data: dict) -> None:
    session = _sessions.get(sid)
    if session is None:
        logger.warning(f"client_message from unknown sid={sid}")
        return

    msg = data.get("message", data)
    user_text = msg.get("output", "")
    if not user_text:
        return

    agent: Agent = session["agent"]
    history: list = session["history"]

    message_id = str(uuid.uuid4())

    # Emit stream_start so clients know a reply is coming
    await sio.emit("stream_start", {"messageId": message_id}, to=sid)

    # Run streaming in a tracked asyncio task so we can cancel it
    async def _stream() -> None:
        full_reply = ""
        try:
            async for chunk in agent.astream(user_text, history):
                full_reply += chunk
                await sio.emit(
                    "stream_token",
                    {"messageId": message_id, "token": chunk},
                    to=sid,
                )
            await sio.emit("stream_end", {"messageId": message_id}, to=sid)

            # Also emit the full message for clients that prefer it
            await sio.emit(
                "new_message",
                {
                    "message": {
                        "id": message_id,
                        "name": "assistant",
                        "type": "assistant_message",
                        "output": full_reply,
                        "createdAt": int(datetime.now(timezone.utc).timestamp() * 1000),
                        "threadId": None,
                    }
                },
                to=sid,
            )

            history.append({"role": "user", "content": user_text})
            history.append({"role": "assistant", "content": full_reply})

        except asyncio.CancelledError:
            # Client stopped generation — send partial content
            if full_reply:
                await sio.emit(
                    "new_message",
                    {
                        "message": {
                            "id": message_id,
                            "name": "assistant",
                            "type": "assistant_message",
                            "output": full_reply + " [已停止]",
                            "createdAt": int(datetime.now(timezone.utc).timestamp() * 1000),
                            "threadId": None,
                        }
                    },
                    to=sid,
                )
                history.append({"role": "user", "content": user_text})
                history.append({"role": "assistant", "content": full_reply})
        except Exception:
            logger.opt(exception=True).error("Stream error")
            await sio.emit(
                "stream_end",
                {"messageId": message_id, "error": True},
                to=sid,
            )

    task = asyncio.create_task(_stream())
    session["stream_task"] = task


@sio.event
async def stop(sid: str) -> None:
    session = _sessions.get(sid)
    if session and session["stream_task"] and not session["stream_task"].done():
        logger.info(f"Cancelling generation for sid={sid}")
        session["stream_task"].cancel()


# ---------------------------------------------------------------------------
# FastAPI + ASGI app
# ---------------------------------------------------------------------------

import fastapi
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

fastapi_app = fastapi.FastAPI()
fastapi_app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@fastapi_app.get("/health")
async def health():
    return {"status": "ok", "clients": len(_sessions)}


@fastapi_app.post("/project/threads")
async def list_threads():
    # Compatible with Chainlit/Flutter thread API
    return JSONResponse({"data": [], "hasMore": False})


@fastapi_app.get("/auth/config")
async def auth_config():
    return {"providers": []}


@fastapi_app.post("/stop")
async def stop_server() -> dict:
    """Gracefully shut down the Jarvis server.

    Can be called from any client (REPL /stop command, curl, etc.):
        curl -X POST http://localhost:8000/stop
    """
    logger.info("Shutdown requested via /stop endpoint")
    if _server_instance is not None:
        _server_instance.should_exit = True
    return {"status": "shutting_down"}


# Wrap the FastAPI app with the Socket.IO ASGI middleware
# Socket.IO is mounted at /ws/socket.io (the path Flutter already uses)
app = socketio.ASGIApp(sio, other_asgi_app=fastapi_app, socketio_path="ws/socket.io")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    global _server_instance

    config = uvicorn.Config(app, host="0.0.0.0", port=8000, log_level="info")
    _server_instance = uvicorn.Server(config)

    # Daemon thread that reads stdin so the user can type /stop in the
    # server terminal to gracefully shut down (protects database integrity).
    def _stdin_reader() -> None:
        while True:
            try:
                line = sys.stdin.readline()
            except (EOFError, OSError):
                return
            if not line:
                return
            if line.strip() == "/stop":
                logger.info("Received /stop on stdin, shutting down gracefully...")
                if _server_instance is not None:
                    _server_instance.should_exit = True
                return

    threading.Thread(target=_stdin_reader, daemon=True).start()

    # Clean shutdown on SIGTERM (e.g. from process manager).
    def _handle_signal(sig: int, frame) -> None:
        logger.info(f"Received signal {sig}, shutting down...")
        _server_instance.should_exit = True

    signal.signal(signal.SIGTERM, _handle_signal)

    logger.info("Starting Jarvis standalone server on http://localhost:8000")
    logger.info("  Type /stop here or Ctrl+C to shut down gracefully.")
    try:
        _server_instance.run()
    except KeyboardInterrupt:
        logger.info("Server stopped.")


if __name__ == "__main__":
    main()
