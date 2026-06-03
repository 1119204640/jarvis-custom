"""
Calendar service — unified event storage + Google Calendar sync.

Uses SQLite (data/index.db) with three tables:
  events       — unified calendar events (local + Google)
  sync_state   — Google nextSyncToken for incremental sync
  oauth_tokens — OAuth access/refresh tokens

All public methods are synchronous — the caller wraps with
asyncio.to_thread() where needed.
"""

from __future__ import annotations

import sqlite3
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any

from loguru import logger

from .constants import ROOT_DIR
from .memo_service import compute_source_status

DATA_DIR = ROOT_DIR / "data"
DB_PATH = DATA_DIR / "index.db"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _now() -> str:
    return datetime.now().astimezone().isoformat()


def _dict_factory(cursor: sqlite3.Cursor, row: tuple) -> dict:
    return {col[0]: row[i] for i, col in enumerate(cursor.description)}


def _iso_to_dt(s: str | None) -> datetime | None:
    if not s:
        return None
    try:
        return datetime.fromisoformat(s)
    except (ValueError, TypeError):
        return None


# ---------------------------------------------------------------------------
# CalendarService
# ---------------------------------------------------------------------------


class CalendarService:
    """Unified calendar event store on top of SQLite."""

    def __init__(self, db_path: Path | str | None = None):
        self.db_path = Path(db_path) if db_path else DB_PATH
        self._watch_dir: Path | None = None
        DATA_DIR.mkdir(parents=True, exist_ok=True)

        self._conn = sqlite3.connect(str(self.db_path), check_same_thread=False)
        self._conn.row_factory = _dict_factory
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute("PRAGMA foreign_keys=ON")
        self._migrate()
        logger.info(f"CalendarService ready (db={self.db_path})")

    @property
    def watch_dir(self) -> Path | None:
        return self._watch_dir

    @watch_dir.setter
    def watch_dir(self, path: str | Path | None) -> None:
        if path is None:
            self._watch_dir = None
        else:
            self._watch_dir = Path(path).resolve()

    def close(self) -> None:
        self._conn.close()
        logger.info("CalendarService closed")

    # ------------------------------------------------------------------
    # Schema
    # ------------------------------------------------------------------

    def _migrate(self) -> None:
        self._conn.execute(
            """
            CREATE TABLE IF NOT EXISTS events (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL DEFAULT '',
                description TEXT NOT NULL DEFAULT '',
                start_time TEXT NOT NULL,
                end_time TEXT NOT NULL,
                is_all_day INTEGER NOT NULL DEFAULT 0,
                source TEXT NOT NULL DEFAULT 'local',
                external_id TEXT DEFAULT NULL,
                etag TEXT DEFAULT NULL,
                recurrence TEXT DEFAULT NULL,
                status TEXT DEFAULT 'confirmed',
                color TEXT DEFAULT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """
        )
        self._conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_events_start_time ON events(start_time)"
        )
        self._conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_events_source ON events(source)"
        )
        self._conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_events_external_id ON events(external_id)"
        )

        self._conn.execute(
            """
            CREATE TABLE IF NOT EXISTS sync_state (
                source TEXT PRIMARY KEY,
                next_sync_token TEXT DEFAULT NULL,
                last_synced_at TEXT DEFAULT NULL
            )
            """
        )

        self._conn.execute(
            """
            CREATE TABLE IF NOT EXISTS oauth_tokens (
                source TEXT PRIMARY KEY,
                access_token TEXT NOT NULL,
                refresh_token TEXT DEFAULT NULL,
                token_expiry TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """
        )

        # Add color column if migrating from older schema
        try:
            self._conn.execute("ALTER TABLE events ADD COLUMN color TEXT DEFAULT NULL")
        except sqlite3.OperationalError:
            pass

        # Add type column: 'record' (记录每日所做) or 'plan' (计划未来安排)
        try:
            self._conn.execute(
                "ALTER TABLE events ADD COLUMN type TEXT NOT NULL DEFAULT 'plan'"
            )
        except sqlite3.OperationalError:
            pass

        # Add file tracking columns
        try:
            self._conn.execute("ALTER TABLE events ADD COLUMN file_path TEXT DEFAULT NULL")
        except sqlite3.OperationalError:
            pass
        try:
            self._conn.execute("ALTER TABLE events ADD COLUMN source_file TEXT DEFAULT NULL")
        except sqlite3.OperationalError:
            pass
        try:
            self._conn.execute("ALTER TABLE events ADD COLUMN source_format TEXT DEFAULT NULL")
        except sqlite3.OperationalError:
            pass
        try:
            self._conn.execute("ALTER TABLE events ADD COLUMN parent_id TEXT DEFAULT NULL")
        except sqlite3.OperationalError:
            pass
        self._conn.execute("CREATE INDEX IF NOT EXISTS idx_events_parent_id ON events(parent_id)")

        self._conn.commit()

    # ------------------------------------------------------------------
    # Event CRUD
    # ------------------------------------------------------------------

    def _row_to_event(self, row: dict[str, Any]) -> dict[str, Any]:
        return {
            "id": row["id"],
            "title": row["title"],
            "description": row["description"],
            "start_time": row["start_time"],
            "end_time": row["end_time"],
            "is_all_day": bool(row["is_all_day"]),
            "type": row.get("type", "plan"),
            "source": row["source"],
            "external_id": row.get("external_id"),
            "etag": row.get("etag"),
            "recurrence": row.get("recurrence"),
            "status": row["status"],
            "color": row.get("color"),
            "file_path": row.get("file_path"),
            "source_file": row.get("source_file"),
            "source_format": row.get("source_format"),
            "source_status": compute_source_status(self._watch_dir, row.get("source_file")),
            "parent_id": row.get("parent_id"),
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }

    def create_event(
        self,
        title: str,
        start_time: str,
        end_time: str,
        description: str = "",
        is_all_day: bool = False,
        source: str = "local",
        external_id: str | None = None,
        recurrence: str | None = None,
        status: str = "confirmed",
        color: str | None = None,
        type: str = "plan",
        file_path: str | None = None,
        source_file: str | None = None,
        source_format: str | None = None,
    ) -> dict[str, Any]:
        event_id = str(uuid.uuid4())
        now = _now()

        self._conn.execute(
            """INSERT INTO events
               (id, title, description, start_time, end_time, is_all_day,
                source, external_id, recurrence, status, color, type,
                file_path, source_file, source_format, created_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                event_id,
                title.strip(),
                description.strip(),
                start_time,
                end_time,
                1 if is_all_day else 0,
                source,
                external_id,
                recurrence,
                status,
                color,
                type,
                file_path,
                source_file,
                source_format,
                now,
                now,
            ),
        )
        self._conn.commit()
        logger.info(f"Created event {event_id}: {title}")
        return self.get_event(event_id)  # type: ignore[return-value]

    def create_event_from_file(
        self,
        title: str,
        description: str = "",
        start_time: str = "",
        end_time: str = "",
        type: str = "plan",
        file_path_rel: str = "",
        source_file: str | None = None,
        source_format: str | None = None,
        parent_id: str | None = None,
    ) -> dict[str, Any]:
        """Create a calendar event from an imported file. The md already exists on disk."""
        event_id = str(uuid.uuid4())
        now = _now()

        self._conn.execute(
            """INSERT INTO events
               (id, title, description, start_time, end_time, is_all_day,
                source, recurrence, status, color, type,
                file_path, source_file, source_format, parent_id, created_at, updated_at)
               VALUES (?, ?, ?, ?, ?, 0, 'local', NULL, 'confirmed', NULL, ?,
                       ?, ?, ?, ?, ?, ?)""",
            (
                event_id, title.strip(), description.strip(),
                start_time, end_time, type,
                file_path_rel, source_file, source_format, parent_id, now, now,
            ),
        )
        self._conn.commit()
        logger.info(f"Created event from file {event_id}: {title}")
        return self.get_event(event_id) or {}

    def set_event_parent(self, event_id: str, parent_id: str) -> None:
        """Link an event to its parent asset."""
        self._conn.execute(
            "UPDATE events SET parent_id=? WHERE id=?",
            (parent_id, event_id),
        )
        self._conn.commit()

    def set_event_file_path(self, event_id: str, file_path: str) -> None:
        """Update an event's file_path."""
        self._conn.execute(
            "UPDATE events SET file_path=? WHERE id=?",
            (file_path, event_id),
        )
        self._conn.commit()

    def get_event(self, event_id: str) -> dict[str, Any] | None:
        row = self._conn.execute(
            "SELECT * FROM events WHERE id=?", (event_id,)
        ).fetchone()
        if not row:
            return None
        return self._row_to_event(row)

    def list_events(
        self, start_time: str | None = None, end_time: str | None = None
    ) -> list[dict[str, Any]]:
        """Return events ordered by start_time.

        If start_time and end_time are given, only events that overlap
        [start_time, end_time) are returned.
        """
        if start_time and end_time:
            rows = self._conn.execute(
                """SELECT * FROM events
                   WHERE start_time < ? AND end_time > ?
                   ORDER BY start_time ASC""",
                (end_time, start_time),
            ).fetchall()
        elif start_time:
            rows = self._conn.execute(
                "SELECT * FROM events WHERE end_time > ? ORDER BY start_time ASC",
                (start_time,),
            ).fetchall()
        elif end_time:
            rows = self._conn.execute(
                "SELECT * FROM events WHERE start_time < ? ORDER BY start_time ASC",
                (end_time,),
            ).fetchall()
        else:
            rows = self._conn.execute(
                "SELECT * FROM events ORDER BY start_time ASC"
            ).fetchall()

        return [self._row_to_event(r) for r in rows]

    def update_event(
        self,
        event_id: str,
        title: str | None = None,
        description: str | None = None,
        start_time: str | None = None,
        end_time: str | None = None,
        is_all_day: bool | None = None,
        recurrence: str | None = None,
        status: str | None = None,
        color: str | None = None,
        type: str | None = None,
        source: str | None = None,
    ) -> dict[str, Any] | None:
        row = self._conn.execute(
            "SELECT * FROM events WHERE id=?", (event_id,)
        ).fetchone()
        if not row:
            return None

        updates: dict[str, Any] = {"updated_at": _now()}
        if title is not None:
            updates["title"] = title.strip()
        if description is not None:
            updates["description"] = description.strip()
        if start_time is not None:
            updates["start_time"] = start_time
        if end_time is not None:
            updates["end_time"] = end_time
        if is_all_day is not None:
            updates["is_all_day"] = 1 if is_all_day else 0
        if recurrence is not None:
            updates["recurrence"] = recurrence
        if status is not None:
            updates["status"] = status
        if color is not None:
            updates["color"] = color
        if type is not None:
            updates["type"] = type
        if source is not None:
            updates["source"] = source

        set_clause = ", ".join(f"{k}=?" for k in updates)
        values = list(updates.values()) + [event_id]
        self._conn.execute(f"UPDATE events SET {set_clause} WHERE id=?", values)
        self._conn.commit()

        logger.info(f"Updated event {event_id}")
        return self.get_event(event_id)

    def delete_event(self, event_id: str) -> bool:
        row = self._conn.execute(
            "SELECT id FROM events WHERE id=?", (event_id,)
        ).fetchone()
        if not row:
            return False
        self._conn.execute("DELETE FROM events WHERE id=?", (event_id,))
        self._conn.commit()
        logger.info(f"Deleted event {event_id}")
        return True

    # ------------------------------------------------------------------
    # Google Calendar sync helpers
    # ------------------------------------------------------------------

    def upsert_google_event(
        self,
        external_id: str,
        title: str,
        start_time: str,
        end_time: str,
        description: str = "",
        is_all_day: bool = False,
        etag: str | None = None,
        recurrence: str | None = None,
        status: str = "confirmed",
        color: str | None = None,
    ) -> dict[str, Any]:
        """Insert or update a Google Calendar event by external_id."""
        now = _now()
        existing = self._conn.execute(
            "SELECT id FROM events WHERE source='google' AND external_id=?",
            (external_id,),
        ).fetchone()

        if existing:
            # Update (preserve existing type for Google events)
            self._conn.execute(
                """UPDATE events SET
                   title=?, description=?, start_time=?, end_time=?,
                   is_all_day=?, etag=?, recurrence=?, status=?, color=?,
                   updated_at=?
                   WHERE id=?""",
                (
                    title.strip(),
                    description.strip(),
                    start_time,
                    end_time,
                    1 if is_all_day else 0,
                    etag,
                    recurrence,
                    status,
                    color,
                    now,
                    existing["id"],
                ),
            )
            self._conn.commit()
            logger.info(f"Updated Google event {external_id}")
            return self.get_event(existing["id"])  # type: ignore[return-value]
        else:
            # Insert new
            event_id = str(uuid.uuid4())
            self._conn.execute(
                """INSERT INTO events
                   (id, title, description, start_time, end_time, is_all_day,
                    source, external_id, etag, recurrence, status, color, type,
                    created_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, 'google', ?, ?, ?, ?, ?, 'plan', ?, ?)""",
                (
                    event_id,
                    title.strip(),
                    description.strip(),
                    start_time,
                    end_time,
                    1 if is_all_day else 0,
                    external_id,
                    etag,
                    recurrence,
                    status,
                    color,
                    now,
                    now,
                ),
            )
            self._conn.commit()
            logger.info(f"Inserted Google event {external_id} as {event_id}")
            return self.get_event(event_id)  # type: ignore[return-value]

    def delete_google_events_except(self, keep_external_ids: set[str]) -> int:
        """Remove Google-sourced events whose external_id is NOT in the set."""
        if not keep_external_ids:
            cursor = self._conn.execute(
                "DELETE FROM events WHERE source='google'"
            )
        else:
            placeholders = ",".join("?" * len(keep_external_ids))
            cursor = self._conn.execute(
                f"""DELETE FROM events
                    WHERE source='google'
                      AND external_id NOT IN ({placeholders})""",
                tuple(keep_external_ids),
            )
        self._conn.commit()
        deleted = cursor.rowcount
        if deleted:
            logger.info(f"Deleted {deleted} stale Google events")
        return deleted

    # ------------------------------------------------------------------
    # Sync state
    # ------------------------------------------------------------------

    def get_sync_state(self, source: str) -> dict[str, str | None] | None:
        row = self._conn.execute(
            "SELECT * FROM sync_state WHERE source=?", (source,)
        ).fetchone()
        if not row:
            return None
        return {
            "source": row["source"],
            "next_sync_token": row["next_sync_token"],
            "last_synced_at": row["last_synced_at"],
        }

    def update_sync_state(
        self, source: str, sync_token: str | None = None
    ) -> None:
        now = _now()
        self._conn.execute(
            """INSERT INTO sync_state (source, next_sync_token, last_synced_at)
               VALUES (?, ?, ?)
               ON CONFLICT(source) DO UPDATE SET
               next_sync_token=excluded.next_sync_token,
               last_synced_at=excluded.last_synced_at""",
            (source, sync_token, now),
        )
        self._conn.commit()
        logger.info(f"Sync state updated for {source}: token={sync_token}")

    # ------------------------------------------------------------------
    # OAuth tokens
    # ------------------------------------------------------------------

    def get_oauth_token(self, source: str) -> dict[str, str | None] | None:
        row = self._conn.execute(
            "SELECT * FROM oauth_tokens WHERE source=?", (source,)
        ).fetchone()
        if not row:
            return None
        return {
            "source": row["source"],
            "access_token": row["access_token"],
            "refresh_token": row.get("refresh_token"),
            "token_expiry": row["token_expiry"],
            "updated_at": row["updated_at"],
        }

    def save_oauth_token(
        self,
        source: str,
        access_token: str,
        refresh_token: str | None = None,
        token_expiry: str | None = None,
    ) -> None:
        now = _now()
        self._conn.execute(
            """INSERT INTO oauth_tokens
               (source, access_token, refresh_token, token_expiry, updated_at)
               VALUES (?, ?, ?, ?, ?)
               ON CONFLICT(source) DO UPDATE SET
               access_token=excluded.access_token,
               refresh_token=excluded.refresh_token,
               token_expiry=excluded.token_expiry,
               updated_at=excluded.updated_at""",
            (source, access_token, refresh_token, token_expiry, now),
        )
        self._conn.commit()
        logger.info(f"OAuth token saved for {source}")

    def has_oauth_token(self, source: str) -> bool:
        row = self._conn.execute(
            "SELECT access_token FROM oauth_tokens WHERE source=?",
            (source,),
        ).fetchone()
        return row is not None


# ---------------------------------------------------------------------------
# LangChain tool factory
# ---------------------------------------------------------------------------


def create_calendar_tools(service: CalendarService) -> list:
    """Convert CalendarService methods to LangChain StructuredTool list."""
    import asyncio

    from langchain_core.tools import StructuredTool
    from pydantic import BaseModel, Field

    # --- Input models ---

    class ListEventsInput(BaseModel):
        start_time: str | None = Field(
            None, description="开始时间 (ISO 8601 格式)，例如 2026-05-28T00:00:00"
        )
        end_time: str | None = Field(
            None, description="结束时间 (ISO 8601 格式)"
        )

    class CreateEventInput(BaseModel):
        title: str = Field(..., description="日程标题")
        start_time: str = Field(..., description="开始时间 (ISO 8601)")
        end_time: str = Field(..., description="结束时间 (ISO 8601)")
        description: str = Field("", description="日程描述")
        is_all_day: bool = Field(False, description="是否全天日程")
        color: str | None = Field(None, description="颜色标记 (如 '#4285F4')")

    class UpdateEventInput(BaseModel):
        id: str = Field(..., description="日程 ID")
        title: str | None = Field(None, description="新标题")
        description: str | None = Field(None, description="新描述")
        start_time: str | None = Field(None, description="新开始时间")
        end_time: str | None = Field(None, description="新结束时间")
        is_all_day: bool | None = Field(None, description="是否全天日程")
        color: str | None = Field(None, description="颜色标记")

    class DeleteEventInput(BaseModel):
        id: str = Field(..., description="要删除的日程 ID")

    # --- Formatters ---

    def _format_event(e: dict) -> str:
        source_label = {"local": "📌 本地", "google": "🔗 Google"}.get(
            e.get("source", "local"), e.get("source", "")
        )
        all_day = "全天" if e.get("is_all_day") else ""
        return (
            f"📅 日程 (ID: {e['id']})\n"
            f"标题: {e['title']}\n"
            f"描述: {e.get('description') or '(空)'}\n"
            f"开始: {e['start_time']}  结束: {e['end_time']}  {all_day}\n"
            f"来源: {source_label}  状态: {e.get('status', 'confirmed')}\n"
            f"创建: {e['created_at']}  更新: {e['updated_at']}"
        )

    def _format_event_list(events: list[dict]) -> str:
        if not events:
            return "当前时间范围内暂无日程。"
        lines = [f"共 {len(events)} 条日程："]
        for e in events:
            start = e["start_time"][:16].replace("T", " ")
            lines.append(
                f"\n[{e['id'][:8]}] {e['title']}\n"
                f"    🕐 {start}  |  "
                f"{'📌' if e.get('source') == 'local' else '🔗'} "
                f"{e.get('source', '')}"
            )
        return "\n".join(lines)

    tools: list[StructuredTool] = []

    # --- List ---

    async def _list_events(**kwargs):
        return _format_event_list(
            await asyncio.to_thread(
                service.list_events,
                start_time=kwargs.get("start_time"),
                end_time=kwargs.get("end_time"),
            )
        )

    tools.append(
        StructuredTool(
            name="list_events",
            description="查看日程，可按时间范围筛选。输入开始时间和结束时间（ISO 8601 格式）。",
            args_schema=ListEventsInput,
            coroutine=_list_events,
        )
    )

    # --- Create ---

    async def _create_event(**kwargs):
        result = await asyncio.to_thread(
            service.create_event,
            title=kwargs["title"],
            start_time=kwargs.get("start_time", ""),
            end_time=kwargs.get("end_time", ""),
            description=kwargs.get("description", ""),
            is_all_day=kwargs.get("is_all_day", False),
            color=kwargs.get("color"),
        )
        return f"✅ 日程已创建\n{_format_event(result)}"

    tools.append(
        StructuredTool(
            name="create_event",
            description="创建一条新日程。需要标题、开始时间和结束时间（ISO 8601 格式）。",
            args_schema=CreateEventInput,
            coroutine=_create_event,
        )
    )

    # --- Update ---

    async def _update_event(**kwargs):
        event_id = kwargs.pop("id")
        result = await asyncio.to_thread(
            service.update_event,
            event_id,
            **{k: v for k, v in kwargs.items() if v is not None},
        )
        if result is None:
            return f"更新失败：未找到 ID 为 {event_id} 的日程。"
        return f"✅ 日程已更新\n{_format_event(result)}"

    tools.append(
        StructuredTool(
            name="update_event",
            description="更新一条已有日程。只更新提供的字段。",
            args_schema=UpdateEventInput,
            coroutine=_update_event,
        )
    )

    # --- Delete ---

    async def _delete_event(**kwargs):
        ok = await asyncio.to_thread(service.delete_event, kwargs["id"])
        if ok:
            return f"✅ 日程 {kwargs['id']} 已删除。"
        return f"删除失败：未找到 ID 为 {kwargs['id']} 的日程。"

    tools.append(
        StructuredTool(
            name="delete_event",
            description="删除一条日程。操作不可撤销，请先向用户确认。",
            args_schema=DeleteEventInput,
            coroutine=_delete_event,
        )
    )

    return tools
