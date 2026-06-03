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
import contextlib
import os
import queue
import signal
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from urllib.parse import urlparse

import socketio
import uvicorn
from dotenv import load_dotenv
from loguru import logger

load_dotenv()

from .agent import Agent
from .calendar_service import CalendarService, create_calendar_tools
from .file_queue import FileProcessingQueue
from .file_watcher import FileWatcher
from .gateway import TaskType, get_gateway, init_gateway
import yaml

from .constants import CONFIG_FILE, MODEL_META
from .memo_service import DATA_DIR, MemoService, create_asset_tools

# Initialize the global ModelGateway singleton at module import time.
# This runs once, before any Socket.IO handlers or FileWatcher can fire.
_init_gw = init_gateway()

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

# Per-session state: sid → {agent, stream_task}
_sessions: dict[str, dict] = {}

# MemoService singleton — shared across all agent sessions and REST handlers
_memo_service: MemoService | None = None
_asset_tools: list | None = None

# CalendarService singleton
_calendar_service: CalendarService | None = None
_calendar_tools: list | None = None

# FileWatcher singleton — monitors user's file management directory
_file_watcher: FileWatcher | None = None
_watched_dir: str | None = None

# Unified file processing queue — all three paths converge here
_file_queue: FileProcessingQueue | None = None


def _save_watched_dir(path: str) -> None:
    """Persist the watch directory path to config.yaml so it survives restarts."""
    config: dict = {}
    if CONFIG_FILE.exists():
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                data = yaml.safe_load(f)
            if isinstance(data, dict):
                config = data
        except Exception:
            pass
    config["watch_dir"] = path
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        yaml.safe_dump(config, f, allow_unicode=True, default_flow_style=False)


def _load_watched_dir() -> str | None:
    """Load the persisted watch directory path from config.yaml, with migration from old txt file."""
    # Migration: old watch_dir.txt → config.yaml
    old_file = DATA_DIR / "watch_dir.txt"
    if old_file.exists():
        old_path = old_file.read_text(encoding="utf-8").strip()
        old_file.unlink()
        if old_path:
            _save_watched_dir(old_path)
            return old_path

    if CONFIG_FILE.exists():
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                config = yaml.safe_load(f)
            if isinstance(config, dict):
                return config.get("watch_dir")
        except Exception:
            pass
    return None


def _get_file_watcher() -> FileWatcher:
    global _file_watcher
    if _file_watcher is None:
        _ensure_memo_service()
        _ensure_calendar_service()
        _file_watcher = FileWatcher()
        _file_watcher.set_services(_memo_service, _calendar_service)
    return _file_watcher


async def _on_new_file_detected(path) -> None:
    """Callback when watchdog detects a new file in the watched directory."""
    from pathlib import Path as _Path
    file_path = _Path(str(path))
    filename = file_path.name
    logger.info(f"New file detected: {filename}")
    await _emit_progress("file_detected", f"检测到新文件: {filename}")
    if _file_queue is not None:
        await _file_queue.submit_file(file_path, _Path(_watched_dir))


async def _on_file_deleted(path) -> None:
    """Callback when watchdog detects a file deletion in the watched directory.

    The associated SQLite record and generated .md asset are intentionally
    preserved — they live independently from the original source file.  The
    Flutter UI reflects the broken link via the ``source_status`` field so the
    user can still read the LLM-generated content.
    """
    from pathlib import Path as _Path

    file_path = _Path(str(path))
    logger.info(f"Source file deleted (assets preserved): {file_path.name}")




async def _emit_progress(stage: str, message: str, sid: str | None = None) -> None:
    """向客户端发送进度事件。如果未指定 sid 则广播给所有已连接会话。"""
    payload = {"stage": stage, "message": message}
    if sid:
        await sio.emit("progress", payload, to=sid)
    else:
        await sio.emit("progress", payload)


async def _emit_data_changed(action: str, data: dict | None = None) -> None:
    """向所有客户端广播数据变更事件，触发 UI 刷新。"""
    await sio.emit("data_changed", {"action": action, "data": data or {}})


def _ensure_memo_service() -> None:
    """Eagerly initialize the MemoService singleton so REST API works without
    a prior Socket.IO connection."""
    global _memo_service, _asset_tools
    if _memo_service is None:
        _memo_service = MemoService()
        _asset_tools = create_asset_tools(_memo_service)


def _ensure_calendar_service() -> None:
    """Eagerly initialize the CalendarService singleton."""
    global _calendar_service, _calendar_tools
    if _calendar_service is None:
        _calendar_service = CalendarService()
        _calendar_tools = create_calendar_tools(_calendar_service)


def _get_asset_tools() -> list:
    _ensure_memo_service()
    return _asset_tools


def _get_calendar_tools() -> list:
    _ensure_calendar_service()
    return _calendar_tools


# ---------------------------------------------------------------------------
# Connection lifecycle
# ---------------------------------------------------------------------------


@sio.event
async def connect(sid: str, environ: dict) -> None:
    qs = environ.get("QUERY_STRING", "")
    logger.info(f"Socket.IO connect sid={sid} query={qs}")

    gw = get_gateway()
    if not gw.available_providers:
        logger.warning(f"Client {sid} rejected: no LLM provider configured")
        await sio.emit(
            "error",
            {
                "message": "尚未添加任何 LLM 提供商，请在设置页面填写 API Key 并点击「测试并添加」"
            },
            to=sid,
        )
        await sio.disconnect(sid)
        return

    agent_llm = gw.create_llm(TaskType.MULTIMODAL)
    agent = Agent(llm=agent_llm, extra_tools=_get_asset_tools() + _get_calendar_tools())
    await agent.connect()
    _sessions[sid] = {
        "agent": agent,
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

    message_id = str(uuid.uuid4())

    await sio.emit("stream_start", {"messageId": message_id}, to=sid)
    await _emit_progress("chat_processing", "正在处理...", sid=sid)

    # Run streaming in a tracked asyncio task so we can cancel it
    async def _stream() -> None:
        full_reply = ""
        try:
            async for chunk in agent.astream(user_text):
                # Yield dict = progress event, str = text token
                if isinstance(chunk, dict):
                    await _emit_progress(chunk["type"], chunk["message"], sid=sid)
                else:
                    full_reply += chunk
                    await sio.emit(
                        "stream_token",
                        {"messageId": message_id, "token": chunk},
                        to=sid,
                    )
            await sio.emit("stream_end", {"messageId": message_id}, to=sid)
            await _emit_progress("chat_done", "处理完成", sid=sid)

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

        except asyncio.CancelledError:
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
        except Exception:
            logger.opt(exception=True).error("Stream error")
            await _emit_progress("chat_error", "处理出错", sid=sid)
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
from fastapi import UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles

# ---------------------------------------------------------------------------
# loguru → Socket.IO log broadcast
# ---------------------------------------------------------------------------

_log_queue: queue.Queue | None = None
_log_broadcast_task: asyncio.Task | None = None
_log_sink_tls = threading.local()


def _log_sink(message) -> None:
    """loguru sink: intercept WARNING/ERROR and push to the thread-safe queue."""
    if getattr(_log_sink_tls, "active", False):
        return
    try:
        _log_sink_tls.active = True
        record = message.record
        level = record["level"].name.lower()
        if level not in ("warning", "error"):
            return
        if _log_queue is not None:
            try:
                _log_queue.put_nowait({
                    "level": level,
                    "message": record["message"],
                    "timestamp": record["time"].isoformat(),
                })
            except queue.Full:
                pass
    finally:
        _log_sink_tls.active = False


async def _broadcast_logs() -> None:
    """Background task: drain the thread-safe queue and emit via Socket.IO."""
    loop = asyncio.get_running_loop()
    while True:
        try:
            payload = await loop.run_in_executor(None, _log_queue.get)
            await sio.emit("log", payload)
        except Exception:
            pass


def _setup_log_broadcast() -> None:
    """Register the loguru sink and initialise the thread-safe queue."""
    global _log_queue
    _log_queue = queue.Queue(maxsize=200)
    logger.add(_log_sink, level="WARNING", enqueue=True)


async def _start_log_broadcast() -> None:
    """Launch the background broadcast task in the running event loop."""
    global _log_broadcast_task
    _log_broadcast_task = asyncio.create_task(_broadcast_logs())


async def _stop_log_broadcast() -> None:
    """Cancel the broadcast task."""
    if _log_broadcast_task is not None:
        _log_broadcast_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await _log_broadcast_task


@contextlib.asynccontextmanager
async def _lifespan(app: fastapi.FastAPI):
    """Startup: init queue, restore file watcher if persisted from a previous session."""
    global _file_queue
    _setup_log_broadcast()
    await _start_log_broadcast()

    # Create and start the unified file processing queue
    _ensure_memo_service()
    _ensure_calendar_service()
    _file_queue = FileProcessingQueue(
        memo_service=_memo_service,
        calendar_service=_calendar_service,
    )
    async def _emit_queue_snapshot(snapshot: list[dict]) -> None:
        """Push the full file-processing queue snapshot to all connected clients."""
        await sio.emit("queue_status", {"jobs": snapshot})

    _file_queue.set_progress_callbacks(
        emit_progress=_emit_progress,
        emit_data_changed=_emit_data_changed,
        emit_queue_snapshot=_emit_queue_snapshot,
    )
    await _file_queue.start()

    try:
        await _restore_watched_dir()
    except Exception:
        logger.opt(exception=True).warning("Failed to restore watched directory")
    yield
    if _file_queue is not None:
        await _file_queue.stop()
    await _stop_log_broadcast()

fastapi_app = fastapi.FastAPI(lifespan=_lifespan)
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


# ---------------------------------------------------------------------------
# Memo REST API
# ---------------------------------------------------------------------------


@fastapi_app.get("/api/assets")
async def list_assets(tag: str | None = None, q: str | None = None,
                     limit: int = 20, offset: int = 0):
    svc = _memo_service
    if svc is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)
    if q:
        results = await svc.search_assets(q)
    else:
        results = await svc.list_assets(tag, limit, offset)
    return {"data": results}


@fastapi_app.post("/api/assets")
async def create_asset(body: dict):
    svc = _memo_service
    if svc is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)
    process_async = body.get("process_async", False)
    content = body.get("content", "")
    title = body.get("title", "")

    # Fix 4: reject empty content for async processing (avoid wasted LLM calls)
    if process_async and (not content or not content.strip()):
        return JSONResponse(
            {"error": "content must not be empty for async processing"},
            status_code=400,
        )

    result = await svc.create_asset(
        title=title,
        content=content,
        tags=body.get("tags"),
    )
    if process_async and result and result.get("id"):
        asyncio.create_task(
            _file_queue.submit_inline(result["id"], title, content)
        )
    return {"data": result, "processing": process_async}


@fastapi_app.get("/api/assets/{asset_id}")
async def get_asset(asset_id: str):
    svc = _memo_service
    if svc is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)
    result = await svc.get_asset(asset_id)
    if result is None:
        return JSONResponse({"error": "not found"}, status_code=404)
    return {"data": result}


@fastapi_app.put("/api/assets/{asset_id}")
async def update_asset(asset_id: str, body: dict):
    svc = _memo_service
    if svc is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)
    result = await svc.update_asset(
        asset_id,
        title=body.get("title"),
        content=body.get("content"),
        tags=body.get("tags"),
    )
    if result is None:
        return JSONResponse({"error": "not found"}, status_code=404)
    return {"data": result}


@fastapi_app.put("/api/assets/{asset_id}/pin")
async def pin_memo(asset_id: str):
    svc = _memo_service
    if svc is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)
    ok = await svc.set_pinned(asset_id, True)
    if not ok:
        return JSONResponse({"error": "not found"}, status_code=404)
    return {"status": "pinned"}


@fastapi_app.put("/api/assets/{asset_id}/unpin")
async def unpin_memo(asset_id: str):
    svc = _memo_service
    if svc is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)
    ok = await svc.set_pinned(asset_id, False)
    if not ok:
        return JSONResponse({"error": "not found"}, status_code=404)
    return {"status": "unpinned"}


@fastapi_app.delete("/api/assets/{asset_id}")
async def delete_asset(asset_id: str):
    svc = _memo_service
    if svc is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)
    ok = await svc.delete_asset(asset_id)
    if not ok:
        return JSONResponse({"error": "not found"}, status_code=404)
    return {"status": "deleted"}


# ---------------------------------------------------------------------------
# Reminder REST API
# ---------------------------------------------------------------------------


@fastapi_app.get("/api/todos")
async def list_todos(status: str | None = None,
                         limit: int = 50, offset: int = 0):
    svc = _memo_service
    if svc is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)
    results = await svc.list_todos(status, limit, offset)
    return {"data": results}


@fastapi_app.post("/api/todos")
async def create_todo(body: dict):
    svc = _memo_service
    if svc is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)
    result = await svc.create_todo(
        title=body.get("title", ""),
        description=body.get("description"),
        due_date=body.get("due_date"),
        priority=body.get("priority"),
    )
    return {"data": result}


@fastapi_app.get("/api/todos/upcoming")
async def upcoming_reminders(days: int = 7):
    svc = _memo_service
    if svc is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)
    results = await svc.get_upcoming_todos(days)
    return {"data": results}


@fastapi_app.get("/api/todos/{todo_id}")
async def get_todo(todo_id: str):
    svc = _memo_service
    if svc is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)
    result = await svc.get_todo(todo_id)
    if result is None:
        return JSONResponse({"error": "not found"}, status_code=404)
    return {"data": result}


@fastapi_app.put("/api/todos/{todo_id}")
async def update_todo(todo_id: str, body: dict):
    svc = _memo_service
    if svc is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)
    result = await svc.update_todo(
        todo_id,
        title=body.get("title"),
        description=body.get("description"),
        due_date=body.get("due_date"),
        priority=body.get("priority"),
        status=body.get("status"),
    )
    if result is None:
        return JSONResponse({"error": "not found"}, status_code=404)
    return {"data": result}


@fastapi_app.delete("/api/todos/{todo_id}")
async def delete_todo(todo_id: str):
    svc = _memo_service
    if svc is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)
    ok = await svc.delete_todo(todo_id)
    if not ok:
        return JSONResponse({"error": "not found"}, status_code=404)
    return {"status": "deleted"}


@fastapi_app.put("/api/todos/{todo_id}/complete")
async def complete_todo(todo_id: str):
    svc = _memo_service
    if svc is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)
    result = await svc.complete_todo(todo_id)
    if result is None:
        return JSONResponse({"error": "not found"}, status_code=404)
    return {"data": result}


# ---------------------------------------------------------------------------
# Parent-Child relationship endpoints
# ---------------------------------------------------------------------------


@fastapi_app.get("/api/assets/{asset_id}/children")
async def get_asset_children(asset_id: str):
    """Get all child nodes (todos + schedules) for a given asset."""
    svc = _memo_service
    if svc is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)
    children = await svc.get_children(asset_id)
    todos = [c for c in children if c.get("type") == "todo"]
    schedules = [c for c in children if c.get("type") == "schedule"]
    return {"data": {"todos": todos, "schedules": schedules}}


@fastapi_app.get("/api/todos/{todo_id}/parent")
async def get_todo_parent(todo_id: str):
    """Get the parent asset for a given todo."""
    svc = _memo_service
    if svc is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)
    parent = await svc.get_parent(todo_id)
    if parent is None:
        return JSONResponse({"error": "parent not found"}, status_code=404)
    return {"data": parent}


# ---------------------------------------------------------------------------
# Unified node endpoint — open source file in system file manager
# ---------------------------------------------------------------------------


@fastapi_app.post("/api/nodes/{node_id}/open-source")
async def open_source_file(node_id: str):
    """Reveal the original source file in the OS file manager (Finder / Explorer).

    Looks up the node across memos, reminders, and calendar events.  Only
    works when ``source_status`` is ``"linked"`` (source file still present).
    """
    import platform
    import subprocess

    source_file: str | None = None

    # 1) Try nodes table (memos + reminders)
    svc = _memo_service
    if svc is not None:
        info = await svc.get_source_file_by_id(node_id)
        if info and info.get("source_file"):
            source_file = info["source_file"]

    # 2) Try events table
    if source_file is None and _calendar_service is not None:
        event = await asyncio.to_thread(_calendar_service.get_event, node_id)
        if event and event.get("source_file"):
            source_file = event["source_file"]

    if not source_file:
        return JSONResponse(
            {"error": "No source file associated with this node"},
            status_code=404,
        )

    # Resolve source_file relative to watch_dir
    if not _watched_dir:
        return JSONResponse(
            {"error": "No watch directory configured"},
            status_code=400,
        )

    from pathlib import Path as _Path
    full_path = _Path(_watched_dir) / source_file
    if not full_path.exists():
        return JSONResponse(
            {"error": f"Source file no longer exists: {source_file}"},
            status_code=404,
        )

    try:
        system = platform.system()
        if system == "Darwin":
            subprocess.Popen(["open", "-R", str(full_path)])
        elif system == "Windows":
            subprocess.Popen(["explorer", "/select,", str(full_path)])
        else:
            # Linux: open the containing folder
            subprocess.Popen(["xdg-open", str(full_path.parent)])
        return {"status": "opened", "path": str(full_path)}
    except Exception as e:
        logger.opt(exception=True).error(f"Failed to open source file: {full_path}")
        return JSONResponse(
            {"error": f"Failed to open file: {e}"},
            status_code=500,
        )


@fastapi_app.put("/api/nodes/{node_id}/category")
async def reclassify_node(node_id: str, body: dict):
    """Re-classify a node (memo/reminder/schedule) to a different category.

    Accepts ``{"category": "<new_category>"}`` where new_category is one of:
    ``"asset"``, ``"todo"``, ``"schedule (plan)"``, ``"schedule (record)"``.

    Moves data between the nodes and events tables as needed, updates the
    SQLite type/status fields, and rewrites the Markdown YAML frontmatter.
    """
    new_category = body.get("category", "")
    valid_categories = {"asset", "todo", "schedule (plan)", "schedule (record)"}
    if new_category not in valid_categories:
        return JSONResponse(
            {"error": f"invalid category: {new_category!r}. Must be one of {sorted(valid_categories)}"},
            status_code=400,
        )

    svc = _memo_service
    cal = _calendar_service
    if svc is None or cal is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)

    # ---- 1. Resolve the node across both tables ----
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    old_category: str | None = None
    node_data: dict | None = None

    # Try nodes table (memo / reminder)
    node_row = await svc._get_node_any(node_id)
    if node_row:
        old_category = node_row["type"]  # 'asset' or 'todo'
        node_data = dict(node_row)

    # Try events table (schedule plan / record)
    event_data = await asyncio.to_thread(cal.get_event, node_id)
    if event_data:
        old_category = f"schedule ({event_data['type']})"  # 'schedule (plan)' or 'schedule (record)'
        node_data = event_data

    if old_category is None or node_data is None:
        return JSONResponse({"error": "node not found"}, status_code=404)

    if old_category == new_category:
        return {"status": "unchanged", "category": old_category}

    logger.info(f"Reclassify {node_id}: {old_category} → {new_category}")

    # ---- 2. Determine target tables ----
    old_is_nodes = old_category in ("asset", "todo")
    new_is_nodes = new_category in ("asset", "todo")

    # ---- 3. Execute the move ----
    try:
        if old_is_nodes and new_is_nodes:
            # Same table (nodes): just update type + possibly file_path
            if old_category == "todo" and new_category == "asset":
                # reminder → memo: create individual .md, remove from master
                node_id2 = str(uuid.uuid4())
                md_rel = f"vault/{node_id2}.md"
                title = node_data.get("title", "")
                desc = node_data.get("description") or ""
                md_text = svc._markdown_content(title, desc)
                await svc._write_file(md_rel, md_text)
                await svc._update_node_raw(
                    node_id, type="asset", file_path=md_rel, updated_at=now,
                )
                await svc._remove_master_line(node_id)
            elif old_category == "asset" and new_category == "todo":
                # memo → reminder: switch to master_reminders.md
                await svc._update_node_raw(
                    node_id, type="todo", file_path="vault/master_todos.md",
                    status="pending", updated_at=now,
                )
                reminder = await svc.get_todo(node_id)
                if reminder:
                    await svc.append_to_master_file([reminder])

        elif not old_is_nodes and not new_is_nodes:
            # Same table (events): just update type
            new_type = "plan" if new_category == "schedule (plan)" else "record"
            await asyncio.to_thread(cal.update_event, node_id, type=new_type)

        elif old_is_nodes and not new_is_nodes:
            # nodes → events: delete from nodes, create in events
            old_data = dict(node_data)
            title = old_data.get("title", "")
            desc = old_data.get("description") or old_data.get("content") or ""
            source_file = old_data.get("source_file")
            source_format = old_data.get("source_format")
            old_file_path = old_data.get("file_path", "")
            event_type = "plan" if new_category == "schedule (plan)" else "record"
            start_time = now
            if old_data.get("due_date"):
                start_time = old_data["due_date"]
            end_time = start_time

            # Create event (preserve parent_id for child items)
            parent_id = old_data.get("parent_id")
            new_event = await asyncio.to_thread(
                cal.create_event_from_file,
                title=title,
                description=desc,
                start_time=start_time,
                end_time=end_time,
                type=event_type,
                source_file=source_file,
                source_format=source_format,
                parent_id=parent_id,
            )
            new_event_id = new_event.get("id", "")

            # If it was a reminder, remove from master file
            if old_category == "todo":
                await svc._remove_master_line(node_id)

            # Delete old node (no file I/O)
            await svc._delete_node_raw(node_id)

            # Transfer .md to new event
            if old_file_path and old_file_path != "vault/master_todos.md" and new_event_id:
                new_md_rel = f"vault/{new_event_id}.md"
                try:
                    old_md = await svc._read_file(old_file_path)
                    if old_md:
                        await svc._write_file(new_md_rel, old_md)
                    cal.set_event_file_path(new_event_id, new_md_rel)
                except Exception:
                    pass
                # Delete old .md if it was a memo individual file
                if old_category == "asset":
                    try:
                        await svc._delete_file(old_file_path)
                    except Exception:
                        pass

            return {
                "status": "reclassified",
                "old_category": old_category,
                "new_category": new_category,
                "new_id": new_event_id,
            }

        else:  # !old_is_nodes and new_is_nodes
            # events → nodes: delete from events, create in nodes
            old_data = dict(node_data)
            title = old_data.get("title", "")
            desc = old_data.get("description", "")
            source_file = old_data.get("source_file")
            source_format = old_data.get("source_format")
            old_file_path = old_data.get("file_path", "")
            parent_id_val = old_data.get("parent_id")

            if new_category == "asset":
                node_id2 = str(uuid.uuid4())
                md_rel = f"vault/{node_id2}.md"
                await svc._insert_node_raw({
                    "id": node_id2, "type": "asset", "file_path": md_rel,
                    "title": title.strip(), "tags": "[]",
                    "created_at": now, "updated_at": now,
                    "pinned": 0, "source_file": source_file,
                    "source_format": source_format, "parent_id": parent_id_val,
                })
                md_text = svc._markdown_content(title, desc)
                await svc._write_file(md_rel, md_text)
                new_node_id = node_id2
            else:  # todo
                node_id2 = str(uuid.uuid4())
                await svc._insert_node_raw({
                    "id": node_id2, "type": "todo",
                    "file_path": "vault/master_todos.md",
                    "title": title.strip(), "tags": "[]",
                    "created_at": now, "updated_at": now,
                    "due_date": None, "priority": "medium", "status": "pending",
                    "source_file": source_file, "source_format": source_format,
                    "description": desc, "parent_id": parent_id_val,
                })
                reminder = await svc.get_todo(node_id2)
                if reminder:
                    await svc.append_to_master_file([reminder])
                new_node_id = node_id2

            # Delete old event
            await asyncio.to_thread(cal.delete_event, node_id)

            # Update or transfer .md
            if old_file_path:
                try:
                    old_md = await svc._read_file(old_file_path)
                    if old_md:
                        new_md_rel = f"vault/{new_node_id}.md"
                        await svc._write_file(new_md_rel, old_md)
                        if new_category == "asset":
                            await svc._update_node_raw(
                                new_node_id, file_path=new_md_rel,
                            )
                        try:
                            await svc._delete_file(old_file_path)
                        except Exception:
                            pass
                except Exception:
                    pass

            return {
                "status": "reclassified",
                "old_category": old_category,
                "new_category": new_category,
                "new_id": new_node_id,
            }

        return {
            "status": "reclassified",
            "old_category": old_category,
            "new_category": new_category,
        }

    except Exception as exc:
        logger.opt(exception=True).error(f"Reclassify failed for {node_id}: {exc}")
        return JSONResponse(
            {"error": f"reclassify failed: {exc}"},
            status_code=500,
        )




# ---------------------------------------------------------------------------
# Calendar / Events REST API
# ---------------------------------------------------------------------------


@fastapi_app.get("/api/events")
async def list_events(start: str | None = None, end: str | None = None):
    svc = _calendar_service
    if svc is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)
    results = await asyncio.to_thread(svc.list_events, start, end)
    return {"data": results}


@fastapi_app.get("/api/events/sync/status")
async def sync_status():
    svc = _calendar_service
    if svc is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)
    sync_state = await asyncio.to_thread(svc.get_sync_state, "google")
    has_token = await asyncio.to_thread(svc.has_oauth_token, "google")
    return {
        "data": {
            "google_connected": has_token,
            "sync_state": sync_state,
        }
    }


@fastapi_app.post("/api/events/sync")
async def trigger_sync():
    svc = _calendar_service
    if svc is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)

    token = await asyncio.to_thread(svc.get_oauth_token, "google")
    if not token or not token.get("access_token"):
        return JSONResponse({"error": "Google Calendar not connected"}, status_code=400)

    from .google_calendar_client import sync_google_calendar

    result = await sync_google_calendar(svc, token["access_token"])
    return {"data": result}


@fastapi_app.post("/api/events")
async def create_event(body: dict):
    svc = _calendar_service
    if svc is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)
    result = await asyncio.to_thread(
        svc.create_event,
        title=body.get("title", ""),
        description=body.get("description", ""),
        start_time=body.get("start_time", ""),
        end_time=body.get("end_time", ""),
        is_all_day=body.get("is_all_day", False),
        color=body.get("color"),
        type=body.get("type", "plan"),
        source=body.get("source", "local"),
    )
    return {"data": result}


@fastapi_app.get("/api/events/{event_id}")
async def get_event(event_id: str):
    svc = _calendar_service
    if svc is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)
    result = await asyncio.to_thread(svc.get_event, event_id)
    if result is None:
        return JSONResponse({"error": "not found"}, status_code=404)
    return {"data": result}


@fastapi_app.put("/api/events/{event_id}")
async def update_event(event_id: str, body: dict):
    svc = _calendar_service
    if svc is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)
    result = await asyncio.to_thread(
        svc.update_event,
        event_id,
        title=body.get("title"),
        description=body.get("description"),
        start_time=body.get("start_time"),
        end_time=body.get("end_time"),
        is_all_day=body.get("is_all_day"),
        color=body.get("color"),
        type=body.get("type"),
        source=body.get("source"),
    )
    if result is None:
        return JSONResponse({"error": "not found"}, status_code=404)

    # Sync update to Google Calendar if this is a Google-sourced event
    if result.get("source") == "google" and result.get("external_id"):
        asyncio.create_task(_update_google_event_bg(
            result["external_id"],
            title=body.get("title"),
            description=body.get("description"),
            start_time=body.get("start_time"),
            end_time=body.get("end_time"),
            color=body.get("color"),
            is_all_day=body.get("is_all_day"),
        ))

    return {"data": result}


async def _delete_google_event_bg(google_event_id: str):
    """Best-effort background deletion of a Google Calendar event."""
    try:
        svc = _calendar_service
        if svc is None:
            return
        token = await asyncio.to_thread(svc.get_oauth_token, "google")
        if not token or not token.get("access_token"):
            logger.warning(f"No Google token, skipping cloud delete for {google_event_id}")
            return
        from .google_calendar_client import delete_google_event
        result = await delete_google_event(token["access_token"], google_event_id)
        if not result["success"]:
            logger.warning(
                f"Failed to delete Google event {google_event_id}: {result.get('error')}"
            )
    except Exception as exc:
        logger.opt(exception=True).error(
            f"Error deleting Google event {google_event_id}: {exc}"
        )


async def _update_google_event_bg(
    google_event_id: str,
    title: str | None = None,
    description: str | None = None,
    start_time: str | None = None,
    end_time: str | None = None,
    color: str | None = None,
    is_all_day: bool | None = None,
):
    """Best-effort background update of a Google Calendar event."""
    try:
        svc = _calendar_service
        if svc is None:
            return
        token = await asyncio.to_thread(svc.get_oauth_token, "google")
        if not token or not token.get("access_token"):
            logger.warning(f"No Google token, skipping cloud update for {google_event_id}")
            return
        from .google_calendar_client import update_google_event, _map_color_to_google

        updates: dict = {}
        if title is not None:
            updates["summary"] = title
        if description is not None:
            updates["description"] = description
        if start_time is not None:
            dt = datetime.fromisoformat(start_time)
            if is_all_day:
                updates["start"] = {"date": dt.strftime("%Y-%m-%d")}
                updates["end"] = {"date": (dt + timedelta(days=1)).strftime("%Y-%m-%d")}
            else:
                updates["start"] = {"dateTime": start_time, "timeZone": "Asia/Shanghai"}
        if end_time is not None:
            if not (is_all_day and "end" in updates):
                dt = datetime.fromisoformat(end_time)
                if is_all_day:
                    updates["end"] = {"date": (dt + timedelta(days=1)).strftime("%Y-%m-%d")}
                else:
                    updates["end"] = {"dateTime": end_time, "timeZone": "Asia/Shanghai"}
        if color is not None:
            google_color = _map_color_to_google(color)
            if google_color:
                updates["colorId"] = google_color

        if not updates:
            return

        result = await update_google_event(token["access_token"], google_event_id, updates)
        if not result["success"]:
            logger.warning(
                f"Failed to update Google event {google_event_id}: {result.get('error')}"
            )
    except Exception as exc:
        logger.opt(exception=True).error(
            f"Error updating Google event {google_event_id}: {exc}"
        )


@fastapi_app.delete("/api/events/{event_id}")
async def delete_event(event_id: str):
    svc = _calendar_service
    if svc is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)

    # 先查出事件信息（需要判断是否是 Google 事件）
    event = await asyncio.to_thread(svc.get_event, event_id)
    if not event:
        return JSONResponse({"error": "not found"}, status_code=404)

    # 删除本地记录
    await asyncio.to_thread(svc.delete_event, event_id)

    # 如果是 Google 事件，后台删除云端（不阻塞响应）
    if event.get("source") == "google" and event.get("external_id"):
        asyncio.create_task(_delete_google_event_bg(event["external_id"]))

    return {"status": "deleted"}


# ---------------------------------------------------------------------------
# Google Calendar OAuth endpoints
# ---------------------------------------------------------------------------


@fastapi_app.get("/api/events/google/oauth/status")
async def google_oauth_status():
    svc = _calendar_service
    if svc is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)
    has_token = await asyncio.to_thread(svc.has_oauth_token, "google")
    token = await asyncio.to_thread(svc.get_oauth_token, "google")
    return {
        "data": {
            "connected": has_token,
            "expiry": token.get("token_expiry") if token else None,
        }
    }


@fastapi_app.get("/api/events/google/auth-url")
async def google_auth_url():
    """Return the Google OAuth authorization URL for the user to visit."""
    import os

    client_id = os.environ.get("GOOGLE_CLIENT_ID", "")
    redirect_uri = os.environ.get(
        "GOOGLE_REDIRECT_URI", "http://localhost:8000/api/events/google/callback"
    )
    if not client_id:
        return JSONResponse(
            {"error": "GOOGLE_CLIENT_ID not configured in .env"}, status_code=500
        )

    scopes = "https://www.googleapis.com/auth/calendar https://www.googleapis.com/auth/calendar.events"
    auth_url = (
        "https://accounts.google.com/o/oauth2/v2/auth"
        f"?client_id={client_id}"
        f"&redirect_uri={redirect_uri}"
        "&response_type=code"
        "&access_type=offline"
        "&prompt=consent"
        f"&scope={scopes}"
    )
    return {"data": {"auth_url": auth_url}}


@fastapi_app.get("/api/events/google/callback")
async def google_oauth_callback(code: str, state: str | None = None):
    """Exchange OAuth code for tokens and save to oauth_tokens."""
    import os

    import httpx

    client_id = os.environ.get("GOOGLE_CLIENT_ID", "")
    client_secret = os.environ.get("GOOGLE_CLIENT_SECRET", "")
    redirect_uri = os.environ.get(
        "GOOGLE_REDIRECT_URI", "http://localhost:8000/api/events/google/callback"
    )

    if not client_id or not client_secret:
        return JSONResponse(
            {"error": "Google OAuth credentials not configured"}, status_code=500
        )

    try:
        async with httpx.AsyncClient() as http:
            resp = await http.post(
                "https://oauth2.googleapis.com/token",
                data={
                    "code": code,
                    "client_id": client_id,
                    "client_secret": client_secret,
                    "redirect_uri": redirect_uri,
                    "grant_type": "authorization_code",
                },
            )
            token_data = resp.json()

        if "error" in token_data:
            return JSONResponse(
                {"error": token_data.get("error_description", token_data["error"])},
                status_code=400,
            )

        access_token = token_data["access_token"]
        refresh_token = token_data.get("refresh_token")
        expires_in = token_data.get("expires_in", 3600)

        from datetime import datetime, timedelta, timezone

        expiry = (
            datetime.now(timezone.utc) + timedelta(seconds=expires_in)
        ).isoformat()

        svc = _calendar_service
        if svc is None:
            return JSONResponse({"error": "service not ready"}, status_code=503)

        await asyncio.to_thread(
            svc.save_oauth_token,
            "google",
            access_token=access_token,
            refresh_token=refresh_token,
            token_expiry=expiry,
        )

        return {"data": {"status": "connected", "expiry": expiry}}

    except Exception as exc:
        logger.opt(exception=True).error(f"OAuth callback error: {exc}")
        return JSONResponse({"error": str(exc)}, status_code=500)


@fastapi_app.post("/api/events/google/oauth")
async def google_oauth_save(body: dict):
    """Directly save OAuth tokens (for manual setup or mobile flow)."""
    svc = _calendar_service
    if svc is None:
        return JSONResponse({"error": "service not ready"}, status_code=503)

    await asyncio.to_thread(
        svc.save_oauth_token,
        "google",
        access_token=body.get("access_token", ""),
        refresh_token=body.get("refresh_token"),
        token_expiry=body.get("token_expiry"),
    )
    return {"data": {"status": "saved"}}


# ---------------------------------------------------------------------------
# Image upload
# ---------------------------------------------------------------------------


@fastapi_app.post("/api/upload")
async def upload_image(file: UploadFile):
    # Allow if content-type looks like an image, or if the filename extension does
    ct = file.content_type or ""
    if not ct.startswith("image/"):
        ext = (file.filename or "").split(".")[-1].lower() if file.filename else ""
        if ext not in ("png", "jpg", "jpeg", "gif", "webp", "bmp", "svg"):
            return JSONResponse(
                {"error": "only image files are allowed"}, status_code=400
            )

    ext = file.filename.split(".")[-1] if file.filename and "." in file.filename else "png"
    filename = f"{uuid.uuid4()}.{ext}"
    contents = await file.read()

    upload_dir = DATA_DIR / "uploads"
    upload_dir.mkdir(parents=True, exist_ok=True)
    (upload_dir / filename).write_bytes(contents)

    logger.info(f"Uploaded image: {filename} ({len(contents)} bytes)")
    return {"data": {"url": f"/uploads/{filename}", "filename": filename}}


# ---------------------------------------------------------------------------
# Serve uploaded files as static
# ---------------------------------------------------------------------------

(DATA_DIR / "uploads").mkdir(parents=True, exist_ok=True)

fastapi_app.mount(
    "/uploads",
    StaticFiles(directory=str(DATA_DIR / "uploads")),
    name="uploads",
)

# ---------------------------------------------------------------------------
# File management — watch directory + file processing
# ---------------------------------------------------------------------------


@fastapi_app.post("/api/settings/watch-dir")
async def set_watch_dir(body: dict):
    """Set the file management directory to watch for new files."""
    global _watched_dir

    gw = get_gateway()
    if not gw.available_providers:
        return JSONResponse(
            {"error": "请先在设置页面添加 LLM 提供商（填写 API Key 并点击「测试并添加」），然后才能设置文件监控目录。文件处理依赖 LLM，没有可用模型时无法工作。"},
            status_code=400,
        )

    path = body.get("path", "").strip()
    if not path:
        return JSONResponse({"error": "path is required"}, status_code=400)

    from pathlib import Path as _Path
    dir_path = _Path(path).expanduser().resolve()
    if not dir_path.exists():
        dir_path.mkdir(parents=True, exist_ok=True)
    if not dir_path.is_dir():
        return JSONResponse({"error": "path must be a directory"}, status_code=400)

    _watched_dir = str(dir_path)

    # Persist so the watcher auto-restarts after server reboot
    _save_watched_dir(str(dir_path))

    # Update MemoService watch_dir (file storage location)
    _ensure_memo_service()
    _memo_service.watch_dir = str(dir_path)

    # Update CalendarService watch_dir (for source_status computation)
    _ensure_calendar_service()
    _calendar_service.watch_dir = str(dir_path)

    # Start or restart file watcher
    loop = asyncio.get_event_loop()
    watcher = _get_file_watcher()
    watcher.set_on_file(_on_new_file_detected)
    watcher.set_on_file_deleted(_on_file_deleted)
    watcher.start(str(dir_path), loop)

    # Clean up stale DB records where the .md file was deleted while the
    # server was not running (watcher can't catch those retroactively).
    stale = await _memo_service.cleanup_stale_nodes()
    if stale:
        logger.info(f"Startup cleanup: removed {stale} stale record(s)")

    logger.info(f"Watch directory set to: {_watched_dir}")

    # 检查多模态是否可用，不可用时返回醒目警告（不阻塞，纯文本文件仍可正常处理）
    warnings: list[str] = []
    if not gw.is_multimodal_available():
        mm_profile = gw.get_profile(TaskType.MULTIMODAL)
        mm_meta = MODEL_META.get(mm_profile.model, {})
        warnings.append(
            f"⚠️ 多模态视觉功能未启用：{mm_meta.get('name', mm_profile.model)} 的 API Key 未配置"
        )

    return {"data": {"watch_dir": _watched_dir, "watching": True}, "warnings": warnings if warnings else None}


@fastapi_app.get("/api/settings/watch-dir")
async def get_watch_dir():
    """Get the current file management directory and watcher status."""
    watcher = _get_file_watcher()
    return {
        "data": {
            "watch_dir": _watched_dir,
            "watching": watcher.running,
        }
    }


# ---------------------------------------------------------------------------
# Model profiles — runtime configuration
# ---------------------------------------------------------------------------


@fastapi_app.get("/api/settings/profiles")
async def get_profiles():
    """Return all TaskType → ModelProfile mappings plus model metadata.

    Includes credential pool info so the UI knows which providers are available
    and can warn about capability mismatches.
    """
    gw = get_gateway()
    profiles_dict = gw.profiles_to_dict()
    for profile in profiles_dict.values():
        profile["credential_match"] = gw.get_model_provider_match(profile["model"])

    # Build safe model metadata (credentials resolved from pool, never leak keys)
    safe_models = {}
    for key, meta in MODEL_META.items():
        safe_models[key] = dict(meta)
        safe_models[key]["has_credential"] = gw.has_credential_for_model(key)

    # Build provider summary for the UI
    providers = []
    for host, cred in gw.available_providers.items():
        provider_models = [
            key for key, meta in MODEL_META.items()
            if urlparse(meta.get("api_base", "")).netloc == host
        ]
        providers.append({
            "host": host,
            "base_url": cred["base_url"],
            "models": provider_models,
        })

    # 多模态可用性检查
    multimodal_available = gw.is_multimodal_available()
    mm_profile = gw.get_profile(TaskType.MULTIMODAL)
    mm_meta = MODEL_META.get(mm_profile.model, {})
    multimodal_info = {
        "available": multimodal_available,
        "model": mm_profile.model,
        "model_name": mm_meta.get("name", mm_profile.model),
        "supports_vision": mm_meta.get("supports_vision", False),
        "has_credential": gw.has_credential_for_model(mm_profile.model),
    }

    return {
        "data": {
            "profiles": profiles_dict,
            "models": safe_models,
            "has_credentials": bool(gw.available_providers),
            "configured_base_url": gw.base_url,
            "compatible_models": gw.get_compatible_models(),
            "verified_models": gw.get_verified_models(),
            "available_providers": providers,
            "profile_warnings": gw.get_all_profile_warnings(),
            "multimodal": multimodal_info,
        }
    }


@fastapi_app.put("/api/settings/profiles/{task_type}")
async def update_profile(task_type: str, body: dict):
    """Update a TaskType's model profile at runtime."""
    try:
        tt = TaskType(task_type.upper())
    except ValueError:
        return JSONResponse(
            {"error": f"Unknown task type: {task_type}. Valid: {[t.value for t in TaskType]}"},
            status_code=400,
        )

    gw = get_gateway()
    current = gw.get_profile(tt)

    model = body.get("model", current.model)
    thinking_enabled = body.get("thinking_enabled", current.thinking_enabled)
    thinking_effort = body.get("thinking_effort", current.thinking_effort)
    temperature = body.get("temperature", current.temperature)

    # Validate model exists in MODEL_META
    if model not in MODEL_META:
        return JSONResponse(
            {"error": f"Unknown model: {model}. Valid: {list(MODEL_META.keys())}"},
            status_code=400,
        )

    # Block thinking on models that don't support it
    if thinking_enabled and not MODEL_META[model]["supports_thinking"]:
        thinking_models = [m for m, meta in MODEL_META.items() if meta.get("supports_thinking")]
        hint = f"Choose a thinking-capable model: {', '.join(thinking_models)}" if thinking_models else "No thinking-capable model configured."
        return JSONResponse(
            {"error": f"{model} does not support thinking. {hint}"},
            status_code=400,
        )

    from .gateway import ModelProfile
    new_profile = ModelProfile(
        model=model,
        thinking_enabled=thinking_enabled,
        thinking_effort=thinking_effort,
        temperature=temperature,
    )

    try:
        gw.set_profile(tt, new_profile)
    except ValueError as e:
        return JSONResponse({"error": str(e)}, status_code=400)

    response_data: dict = {"profiles": gw.profiles_to_dict()}

    # Collect warnings: credential mismatch + capability warnings
    all_warnings: list[str] = []

    if not gw.get_model_provider_match(model):
        model_meta = MODEL_META[model]
        all_warnings.append(
            f"模型 {model}（{model_meta['provider']}）凭据未配置"
        )

    # 额外检查：MULTIMODAL 模型有凭据吗？
    if tt == TaskType.MULTIMODAL and not gw.has_credential_for_model(model):
        all_warnings.append(
            f"⚠️ {MODEL_META[model].get('name', model)} 的 API Key 未配置"
        )

    all_warnings.extend(gw.get_profile_warnings(tt))

    response = {"data": response_data}
    if all_warnings:
        response["warnings"] = all_warnings

    return response


# ---------------------------------------------------------------------------
# LLM connection config — runtime credentials from client
# ---------------------------------------------------------------------------

@fastapi_app.get("/api/settings/models/{model_key}")
async def get_model_credentials(model_key: str):
    """Return a single model's api_key and api_base from the credential pool.

    Used by the settings UI to auto-fill credentials when switching models.
    """
    if model_key not in MODEL_META:
        return JSONResponse({"error": f"Unknown model: {model_key}"}, status_code=404)

    meta = MODEL_META[model_key]
    model_api_base = meta.get("api_base", "").strip()

    gw = get_gateway()

    # Look up user-saved credential from the gateway pool
    api_key = ""
    if model_api_base:
        host = urlparse(model_api_base).netloc
        cred = gw.available_providers.get(host, {})
        api_key = cred.get("api_key", "")

    return {
        "data": {
            "model": model_key,
            "api_base": model_api_base or gw.base_url,
            "has_api_key": bool(api_key),
            "api_key": api_key,
        }
    }


@fastapi_app.get("/api/settings/llm")
async def get_llm_config():
    """Return current LLM config — base_url, has_key, compatible models, provider pool."""
    gw = get_gateway()
    providers = []
    for host, cred in gw.available_providers.items():
        provider_models = [
            key for key, meta in MODEL_META.items()
            if urlparse(meta.get("api_base", "")).netloc == host
        ]
        providers.append({
            "host": host,
            "base_url": cred["base_url"],
            "models": provider_models,
        })
    return {
        "data": {
            "base_url": gw.base_url,
            "has_key": bool(gw.api_key),
            "compatible_models": gw.get_compatible_models(),
            "providers": providers,
        }
    }


@fastapi_app.put("/api/settings/llm")
async def update_llm_config(body: dict):
    """Update LLM API key and base URL at runtime. Key is kept in memory only."""
    api_key = body.get("api_key", "").strip()
    base_url = body.get("base_url", "").strip()

    if not api_key:
        return JSONResponse({"error": "api_key is required"}, status_code=400)
    if not base_url:
        return JSONResponse({"error": "base_url is required"}, status_code=400)

    gw = get_gateway()
    gw.update_credentials(api_key=api_key, base_url=base_url)

    logger.info("LLM config updated via REST API")
    return {"data": {"base_url": base_url, "has_key": True}}


@fastapi_app.post("/api/settings/llm/test")
async def test_llm_connection(body: dict):
    """Test LLM API connectivity with the given credentials.

    On success, automatically adds the credential to the provider pool.
    """
    api_key = body.get("api_key", "").strip()
    base_url = body.get("base_url", "").strip()

    gw = get_gateway()
    result = gw.verify_credentials(api_key=api_key, base_url=base_url)

    if result["success"]:
        return {"data": result}
    else:
        return JSONResponse({"error": result["message"], "data": result}, status_code=400)


@fastapi_app.delete("/api/settings/llm")
async def remove_llm_provider(body: dict):
    """Remove a provider from the credential pool."""
    host = body.get("host", "").strip()
    if not host:
        return JSONResponse({"error": "host is required"}, status_code=400)

    gw = get_gateway()
    ok = gw.remove_credential(host)
    if not ok:
        return JSONResponse({"error": f"Provider {host} not found"}, status_code=404)

    logger.info(f"LLM provider removed: {host}")
    return {"data": {"removed": host}}


@fastapi_app.post("/api/files/scan")
async def scan_files():
    """Manually scan the watch directory and process all supported files."""
    gw = get_gateway()
    if not gw.available_providers:
        return JSONResponse(
            {"error": "请先在设置页面添加 LLM 提供商，文件处理依赖 LLM，没有可用模型时无法扫描。"},
            status_code=400,
        )
    if not _watched_dir:
        return JSONResponse({"error": "watch directory not set"}, status_code=400)

    from pathlib import Path as _Path

    dir_path = _Path(_watched_dir)
    if not dir_path.exists() or not dir_path.is_dir():
        return JSONResponse({"error": "watch directory does not exist"}, status_code=400)

    supported_files = [
        f for f in dir_path.iterdir()
        if f.is_file() and not f.name.startswith(".") and not f.name.startswith("~$")
        and f.suffix.lower() in _SUPPORTED_EXTENSIONS
    ]
    submitted = 0
    for f in sorted(supported_files, key=lambda x: x.stat().st_mtime, reverse=True):
        await _file_queue.submit_file(f, dir_path)
        submitted += 1

    return {"data": {"submitted": submitted, "files": [f.name for f in supported_files]}}


@fastapi_app.get("/api/files/watcher-status")
async def watcher_status():
    """Get the current file watcher status."""
    watcher = _get_file_watcher()
    return {
        "data": {
            "watching": watcher.running,
            "watch_dir": _watched_dir,
        }
    }


# Supported file extensions for scanning — single source of truth
from .file_watcher import FileParser
_SUPPORTED_EXTENSIONS = FileParser.SUPPORTED_SUFFIXES


# ---------------------------------------------------------------------------
# Wire up Socket.IO + FastAPI
# ---------------------------------------------------------------------------


@fastapi_app.post("/stop")
async def stop_server() -> dict:
    """Gracefully shut down the Jarvis server.

    Can be called from any client (REPL /stop command, curl, etc.):
        curl -X POST http://localhost:8000/stop
    """
    logger.info("Shutdown requested via /stop endpoint")
    if _file_watcher is not None:
        _file_watcher.stop()
    if _file_queue is not None:
        asyncio.create_task(_file_queue.stop())
    if _server_instance is not None:
        _server_instance.should_exit = True
    return {"status": "shutting_down"}
app = socketio.ASGIApp(sio, other_asgi_app=fastapi_app, socketio_path="ws/socket.io")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

async def _restore_watched_dir() -> None:
    """Auto-restart the file watcher if a watch_dir was persisted from a previous session."""
    global _watched_dir

    saved = _load_watched_dir()
    if not saved:
        return

    from pathlib import Path as _Path
    dir_path = _Path(saved).expanduser().resolve()
    if not dir_path.exists() or not dir_path.is_dir():
        logger.warning(f"Persisted watch_dir no longer exists, clearing: {saved}")
        _watched_dir = None
        _save_watched_dir("")
        return

    _watched_dir = str(dir_path)

    _ensure_memo_service()
    _memo_service.watch_dir = str(dir_path)

    _ensure_calendar_service()
    _calendar_service.watch_dir = str(dir_path)

    loop = asyncio.get_event_loop()
    watcher = _get_file_watcher()
    watcher.set_on_file(_on_new_file_detected)
    watcher.set_on_file_deleted(_on_file_deleted)
    watcher.start(str(dir_path), loop)

    stale = await _memo_service.cleanup_stale_nodes()
    if stale:
        logger.info(f"Startup cleanup: removed {stale} stale record(s)")

    logger.info(f"Restored watch directory from previous session: {_watched_dir}")


def main() -> None:
    global _server_instance, _memo_service, _calendar_service, _file_watcher

    # Eagerly init services so REST API is available from the start.
    _ensure_memo_service()
    _ensure_calendar_service()

    # File watcher auto-restore is handled by FastAPI lifespan (see _lifespan above).
    # Clean up stale DB records whose .md files were deleted while
    # the server was not running (watcher can't catch those retroactively).
    stale = asyncio.run(_memo_service.cleanup_stale_nodes())
    if stale:
        logger.info(f"Startup cleanup: removed {stale} stale record(s) from previous session")

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

    # Clean shutdown on SIGTERM / SIGINT.
    # Track count so repeated signals escalate to force exit.
    _signal_count = 0

    def _handle_signal(sig: int, frame) -> None:
        nonlocal _signal_count
        _signal_count += 1
        if _signal_count >= 3:
            logger.warning(f"Force exiting after {_signal_count} signals")
            os._exit(1)
        logger.info(f"Received signal {sig}, shutting down... (attempt {_signal_count})")
        if _server_instance is not None:
            _server_instance.should_exit = True

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    logger.info("Starting Jarvis standalone server on http://localhost:8000")
    logger.info("  Type /stop here or Ctrl+C to shut down gracefully.")
    try:
        _server_instance.run()
        logger.info("uvicorn run() returned normally (should_exit was set)")
    except KeyboardInterrupt:
        logger.info("Server interrupted via KeyboardInterrupt.")
    except Exception:
        logger.opt(exception=True).error("uvicorn run() exited with unexpected error")
    finally:
        # Ignore further SIGINT / SIGTERM during cleanup so that Python's
        # threading._shutdown atexit thread-join phase is not
        # interrupted by a second KeyboardInterrupt.
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if _file_watcher is not None:
            _file_watcher.stop()
            _file_watcher = None
        if _memo_service is not None:
            _memo_service.close()
            _memo_service = None
        if _calendar_service is not None:
            _calendar_service.close()
            _calendar_service = None
        # Use sys.exit instead of os._exit so Python's multiprocessing
        # resource_tracker can clean up semaphore objects properly.
        # Falls back to os._exit after 3 seconds if non-daemon threads are hung.
        threading.Thread(target=lambda: (time.sleep(3), os._exit(0)), daemon=True).start()
        sys.exit(0)


if __name__ == "__main__":
    main()
