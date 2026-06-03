"""
Memo & Reminder service — FNode-style persistence.

Content lives in raw markdown files under data/memos/ and data/reminders/.
SQLite stores metadata (file path, tags, timestamps) like a filesystem inode table.

All public methods are async and use per-task database connections (aiosqlite)
to eliminate the SIGSEGV race condition caused by concurrent multi-threaded
access to a single sqlite3.Connection.
"""

from __future__ import annotations

import json
import re
import sqlite3
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, AsyncGenerator

import aiofiles
import aiosqlite
from loguru import logger

from .constants import ROOT_DIR

DATA_DIR = ROOT_DIR / "data"
VAULT_DIR = DATA_DIR / "vault"
DB_PATH = DATA_DIR / "index.db"

# 统一待办事项主文件 — 所有待办合并追加到此文件
MASTER_TODOS_REL = "vault/master_todos.md"


def compute_source_status(watch_dir: Path | str | None, source_file: str | None) -> str:
    """Compute the link status between a node and its original source file.

    Returns one of four states:
    - ``"native"`` — node was created directly (no source file)
    - ``"linked"`` — source file exists on disk
    - ``"source_deleted"`` — watch dir exists but the source file is gone
    - ``"association_lost"`` — watch dir itself no longer exists
    """
    if not source_file:
        return "native"
    if watch_dir is None:
        return "association_lost"
    wd = Path(watch_dir) if isinstance(watch_dir, str) else watch_dir
    if not wd.exists():
        return "association_lost"
    source_path = wd / source_file
    if not source_path.exists():
        return "source_deleted"
    return "linked"

# ---------------------------------------------------------------------------
# SQLite helpers
# ---------------------------------------------------------------------------

def _now() -> str:
    return datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S")


def _dict_factory(cursor: sqlite3.Cursor, row: tuple) -> dict:
    return {col[0]: row[i] for i, col in enumerate(cursor.description)}


# ---------------------------------------------------------------------------
# MemoService
# ---------------------------------------------------------------------------


class MemoService:
    """FNode-style persistence for memos and reminders.

    All public methods are async — each creates an independent aiosqlite
    connection, guaranteeing no concurrent access to the same connection.

    When ``watch_dir`` is set, md files are written to the user's file
    management directory instead of the default data/ directory.
    """

    def __init__(self, data_dir: Path | str | None = None):
        self.data_dir = Path(data_dir) if data_dir else DATA_DIR
        self.vault_dir = self.data_dir / "vault"
        self.db_path = self.data_dir / "index.db"
        self._watch_dir: Path | None = None

        # Ensure directories
        self.vault_dir.mkdir(parents=True, exist_ok=True)
        (self.data_dir / "uploads").mkdir(parents=True, exist_ok=True)

        # One-time migration using a temporary sync connection (startup only)
        conn = sqlite3.connect(str(self.db_path))
        conn.row_factory = _dict_factory
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        try:
            self._migrate_sync(conn)
        finally:
            conn.close()

        logger.info(f"MemoService ready (db={self.db_path})")

    # ------------------------------------------------------------------
    # Database connection factory
    # ------------------------------------------------------------------

    @asynccontextmanager
    async def _db(self) -> AsyncGenerator[aiosqlite.Connection, None]:
        """获取独立数据库连接，自动配置 PRAGMA 并关闭。

        每次调用都创建全新连接，任务结束后立即关闭，从根本上消除
        多线程并发访问同一 sqlite3.Connection 导致的 SIGSEGV 崩溃。
        """
        db = await aiosqlite.connect(str(self.db_path))
        try:
            db.row_factory = _dict_factory
            await db.execute("PRAGMA journal_mode=WAL")
            await db.execute("PRAGMA synchronous=NORMAL")
            await db.execute("PRAGMA busy_timeout=5000")
            await db.execute("PRAGMA foreign_keys=ON")
            yield db
        finally:
            await db.close()

    # ------------------------------------------------------------------
    # Watch dir
    # ------------------------------------------------------------------

    @property
    def watch_dir(self) -> Path | None:
        return self._watch_dir

    @watch_dir.setter
    def watch_dir(self, path: str | Path | None) -> None:
        if path is None:
            self._watch_dir = None
        else:
            p = Path(path).resolve()
            p.mkdir(parents=True, exist_ok=True)
            self._watch_dir = p
        logger.info(f"MemoService watch_dir set to: {self._watch_dir}")

    def _resolve_path(self, relative_path: str) -> Path:
        """Resolve a path to either watch_dir or default data_dir.

        Paths under memos/, reminders/, and uploads/ are app-managed
        generated files — they always live in data_dir, even when a
        watch_dir is configured.
        """
        if relative_path.startswith(("vault/", "uploads/")):
            return self.data_dir / relative_path
        if self._watch_dir:
            return self._watch_dir / relative_path
        return self.data_dir / relative_path

    def close(self) -> None:
        """No persistent connection to close — each task manages its own."""
        logger.info("MemoService closed")

    # ------------------------------------------------------------------
    # Schema (sync — called once from __init__ with a temp connection)
    # ------------------------------------------------------------------

    def _migrate_sync(self, conn: sqlite3.Connection) -> None:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS nodes (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL CHECK(type IN ('asset','todo')),
                file_path TEXT NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                tags TEXT NOT NULL DEFAULT '[]',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                due_date TEXT,
                priority TEXT CHECK(priority IN ('low','medium','high')),
                status TEXT CHECK(status IN ('pending','completed'))
            )
            """
        )
        conn.execute("CREATE INDEX IF NOT EXISTS idx_nodes_file_path ON nodes(file_path)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_nodes_type ON nodes(type)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_nodes_tags ON nodes(tags)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_nodes_due_date ON nodes(due_date)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_nodes_status ON nodes(status)")
        try:
            conn.execute("ALTER TABLE nodes ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0")
        except sqlite3.OperationalError:
            pass
        try:
            conn.execute("ALTER TABLE nodes ADD COLUMN source_file TEXT DEFAULT NULL")
        except sqlite3.OperationalError:
            pass
        try:
            conn.execute("ALTER TABLE nodes ADD COLUMN source_format TEXT DEFAULT NULL")
        except sqlite3.OperationalError:
            pass
        try:
            conn.execute("ALTER TABLE nodes ADD COLUMN summary TEXT DEFAULT NULL")
        except sqlite3.OperationalError:
            pass
        try:
            conn.execute("ALTER TABLE nodes ADD COLUMN description TEXT DEFAULT NULL")
        except sqlite3.OperationalError:
            pass
        try:
            conn.execute("ALTER TABLE nodes ADD COLUMN parent_id TEXT DEFAULT NULL")
        except sqlite3.OperationalError:
            pass
        conn.execute("CREATE INDEX IF NOT EXISTS idx_nodes_parent_id ON nodes(parent_id)")

        self._remove_unique_file_path_sync(conn)

        conn.execute("UPDATE nodes SET type='asset' WHERE type='memo'")
        conn.execute("UPDATE nodes SET type='todo' WHERE type='reminder'")

        conn.commit()

    def _remove_unique_file_path_sync(self, conn: sqlite3.Connection) -> None:
        """Rebuild the nodes table to fix schema drift (UNIQUE / CHECK constraints).

        SQLite does not support ALTER TABLE DROP CONSTRAINT, so we must
        recreate the table and migrate data. This also handles the v2 type
        rename (memo→asset, reminder→todo). Idempotent — skipped when the
        schema already matches.
        """
        row = conn.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='nodes'"
        ).fetchone()
        if row is None:
            return
        create_sql = row["sql"]
        has_unique = bool(re.search(
            r'(?:file_path|"file_path")\s+TEXT\s+NOT\s+NULL\s+UNIQUE',
            create_sql,
        ))
        has_old_check = bool(re.search(
            r"CHECK\s*\(\s*type\s+IN\s*\(\s*'memo'\s*,\s*'reminder'\s*\)\s*\)",
            create_sql,
        ))
        if not has_unique and not has_old_check:
            return

        reasons = []
        if has_unique:
            reasons.append("移除 UNIQUE 约束")
        if has_old_check:
            reasons.append("更新 CHECK 约束 (memo/reminder → asset/todo)")
        logger.info(f"迁移：重建 nodes 表（{', '.join(reasons)}）")

        conn.execute("PRAGMA foreign_keys=OFF")
        conn.execute("BEGIN")
        try:
            conn.execute("""
                CREATE TABLE nodes_new (
                    id TEXT PRIMARY KEY,
                    type TEXT NOT NULL CHECK(type IN ('asset','todo')),
                    file_path TEXT NOT NULL,
                    title TEXT NOT NULL DEFAULT '',
                    tags TEXT NOT NULL DEFAULT '[]',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    due_date TEXT,
                    priority TEXT CHECK(priority IN ('low','medium','high')),
                    status TEXT CHECK(status IN ('pending','completed')),
                    pinned INTEGER NOT NULL DEFAULT 0,
                    source_file TEXT DEFAULT NULL,
                    source_format TEXT DEFAULT NULL,
                    summary TEXT DEFAULT NULL,
                    description TEXT DEFAULT NULL,
                    parent_id TEXT DEFAULT NULL
                )
            """)
            conn.execute(
                """INSERT INTO nodes_new SELECT
                    id,
                    CASE type WHEN 'memo' THEN 'asset' WHEN 'reminder' THEN 'todo' ELSE type END,
                    file_path, title, tags, created_at, updated_at,
                    due_date, priority, status, pinned,
                    source_file, source_format, summary, description, parent_id
                FROM nodes"""
            )
            conn.execute("DROP TABLE nodes")
            conn.execute("ALTER TABLE nodes_new RENAME TO nodes")

            conn.execute("CREATE INDEX IF NOT EXISTS idx_nodes_type ON nodes(type)")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_nodes_tags ON nodes(tags)")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_nodes_due_date ON nodes(due_date)")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_nodes_status ON nodes(status)")

            conn.execute("COMMIT")
            logger.info("迁移完成：表已重建")
        except Exception:
            conn.execute("ROLLBACK")
            raise
        finally:
            conn.execute("PRAGMA foreign_keys=ON")

    # ------------------------------------------------------------------
    # File I/O (async — uses aiofiles to avoid blocking the event loop)
    # ------------------------------------------------------------------

    @staticmethod
    def _markdown_content(title: str, content: str) -> str:
        """将内容原样写入 .md 文件。预览模式由前端渲染，不在这里处理 # 符号。"""
        return content.strip() + "\n"

    @staticmethod
    def _parse_markdown(text: str) -> tuple[str, str]:
        """Parse markdown back into (title, content).

        Handles both plain format and files with YAML frontmatter (``---`` …
        ``---``).  Frontmatter lines are skipped so the caller always sees just
        the title + body.
        """
        lines = text.split("\n")
        title = ""
        body_lines: list[str] = []
        found_title = False
        in_frontmatter = False
        frontmatter_done = False

        for line in lines:
            if not frontmatter_done and not found_title:
                stripped = line.strip()
                if stripped == "---":
                    if not in_frontmatter:
                        in_frontmatter = True
                        continue
                    else:
                        in_frontmatter = False
                        frontmatter_done = True
                        continue
                if in_frontmatter:
                    continue

            if not found_title and line.startswith("#"):
                title = line.lstrip("#").strip()
                found_title = True
            elif found_title:
                body_lines.append(line)

        if not found_title:
            title = lines[0].strip() if lines else ""
        return title, "\n".join(body_lines).strip()

    async def _write_file(self, relative_path: str, content: str) -> None:
        path = self._resolve_path(relative_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        async with aiofiles.open(str(path), "w", encoding="utf-8") as f:
            await f.write(content)

    async def _read_file(self, relative_path: str) -> str:
        path = self._resolve_path(relative_path)
        if not path.exists():
            return ""
        async with aiofiles.open(str(path), encoding="utf-8") as f:
            return await f.read()

    async def _delete_file(self, relative_path: str) -> None:
        path = self._resolve_path(relative_path)
        if path.exists():
            path.unlink()  # unlink is fast enough to be sync

    # ------------------------------------------------------------------
    # Master reminders file helpers (async — uses aiofiles)
    # ------------------------------------------------------------------

    @property
    def _master_path(self) -> Path:
        return self._resolve_path(MASTER_TODOS_REL)

    async def _ensure_master_file(self) -> None:
        """Ensure master_reminders.md exists on disk."""
        p = self._master_path
        p.parent.mkdir(parents=True, exist_ok=True)
        if not p.exists():
            async with aiofiles.open(str(p), "w", encoding="utf-8") as f:
                await f.write("")

    @staticmethod
    def _format_todo_line(reminder: dict) -> str:
        """Format a single reminder as a master-file line.

        Returns: ``- [ ] 标题 @due(YYYY-MM-DD) #标签1 #标签2 <!-- rid:uuid -->``
        """
        node_id = reminder.get("id", "")
        title = reminder.get("title", "").strip()
        due = reminder.get("due_date") or ""
        if due and len(due) >= 10:
            due = due[:10]
        tags = reminder.get("tags", [])
        if isinstance(tags, str):
            try:
                tags = json.loads(tags)
            except (json.JSONDecodeError, TypeError):
                tags = []
        status = reminder.get("status", "pending")
        checkbox = "[x]" if status == "completed" else "[ ]"
        tag_str = " ".join(f"#{t}" for t in tags) if tags else ""
        due_str = f" @due({due})" if due else ""
        tail = f" {tag_str}" if tag_str else ""
        return f"{checkbox} {title}{due_str}{tail} <!-- rid:{node_id} -->"

    async def append_to_master_file(self, reminders: list[dict]) -> None:
        """将新提醒事项逐条追加到 master_reminders.md 末尾。

        每条格式：``- [ ] 标题 @due(YYYY-MM-DD) #标签 <!-- rid:uuid -->``
        """
        if not reminders:
            return
        await self._ensure_master_file()
        lines = [self._format_todo_line(r) for r in reminders]
        text = "\n".join(lines) + "\n"
        async with aiofiles.open(str(self._master_path), "a", encoding="utf-8") as f:
            await f.write(text)
        logger.info(
            f"Appended {len(reminders)} reminder(s) to {MASTER_TODOS_REL}"
        )

    async def _update_master_line(self, node_id: str, status: str) -> bool:
        """更新 master_reminders.md 中对应行的 checkbox 状态。

        status='completed' → ``[x]``, status='pending' → ``[ ]``.
        Returns True if the line was found and updated.
        """
        mp = self._master_path
        if not mp.exists():
            return False
        async with aiofiles.open(str(mp), encoding="utf-8") as f:
            text = await f.read()
        marker = f"<!-- rid:{node_id} -->"
        if marker not in text:
            return False

        new_checkbox = "[x]" if status == "completed" else "[ ]"
        new_lines: list[str] = []
        for line in text.split("\n"):
            if marker in line:
                line = re.sub(r"\[.\]", new_checkbox, line, count=1)
            new_lines.append(line)
        async with aiofiles.open(str(mp), "w", encoding="utf-8") as f:
            await f.write("\n".join(new_lines))
        return True

    async def _remove_master_line(self, node_id: str) -> bool:
        """从 master_reminders.md 中删除对应行。"""
        mp = self._master_path
        if not mp.exists():
            return False
        async with aiofiles.open(str(mp), encoding="utf-8") as f:
            text = await f.read()
        marker = f"<!-- rid:{node_id} -->"
        if marker not in text:
            return False

        new_lines = [
            line for line in text.split("\n")
            if marker not in line
        ]
        async with aiofiles.open(str(mp), "w", encoding="utf-8") as f:
            await f.write("\n".join(new_lines))
        return True

    async def _rewrite_master_line(self, node_id: str) -> bool:
        """重写 master_reminders.md 中对应整行（标题/日期/标签/状态变更后）。"""
        r = await self.get_todo(node_id)
        if r is None:
            return False
        mp = self._master_path
        if not mp.exists():
            return False
        async with aiofiles.open(str(mp), encoding="utf-8") as f:
            text = await f.read()
        marker = f"<!-- rid:{node_id} -->"
        if marker not in text:
            return False

        new_line = self._format_todo_line(r)
        new_lines = [
            new_line if marker in line else line
            for line in text.split("\n")
        ]
        async with aiofiles.open(str(mp), "w", encoding="utf-8") as f:
            await f.write("\n".join(new_lines))
        return True

    # ------------------------------------------------------------------
    # Asset CRUD (async)
    # ------------------------------------------------------------------

    async def create_asset(
        self, title: str, content: str = "", tags: list[str] | None = None,
        file_path_rel: str | None = None,
        source_file: str | None = None,
        source_format: str | None = None,
    ) -> dict[str, Any]:
        node_id = str(uuid.uuid4())
        relative_path = file_path_rel or f"vault/{node_id}.md"
        now = _now()
        tag_list = tags or []

        if not title or not title.strip():
            parsed, _ = self._parse_markdown(content)
            title = parsed or title

        md_text = self._markdown_content(title, content)
        await self._write_file(relative_path, md_text)

        async with self._db() as db:
            await db.execute(
                """INSERT INTO nodes (id, type, file_path, title, tags, created_at, updated_at,
                                      pinned, source_file, source_format)
                   VALUES (?, 'asset', ?, ?, ?, ?, ?, 0, ?, ?)""",
                (node_id, relative_path, title.strip(),
                 json.dumps(tag_list, ensure_ascii=False), now, now,
                 source_file, source_format),
            )
            await db.commit()

        logger.info(f"Created asset {node_id}: {title}")
        return await self.get_asset(node_id) or {}  # type: ignore[return-value]

    async def create_asset_from_file(
        self, title: str, content: str, tags: list[str] | None = None,
        file_path_rel: str = "", source_file: str | None = None,
        source_format: str | None = None, summary: str | None = None,
    ) -> dict[str, Any]:
        """Create a memo from an imported file. The md already exists on disk."""

        if not title or not title.strip():
            parsed, _ = self._parse_markdown(content)
            title = parsed or title
        # Guard against concurrent processing of the same file
        existing = await self.find_by_file_path(file_path_rel) if file_path_rel else None
        if existing:
            logger.info(f"Skipping create_asset_from_file: {file_path_rel} already tracked as {existing['id'][:8]}")
            return await self.get_asset(existing["id"]) or {}

        node_id = str(uuid.uuid4())
        now = _now()
        tag_list = tags or []

        async with self._db() as db:
            await db.execute(
                """INSERT INTO nodes (id, type, file_path, title, tags, created_at, updated_at,
                                      pinned, source_file, source_format, summary)
                   VALUES (?, 'asset', ?, ?, ?, ?, ?, 0, ?, ?, ?)""",
                (node_id, file_path_rel, title.strip(),
                 json.dumps(tag_list, ensure_ascii=False), now, now,
                 source_file, source_format, summary),
            )
            await db.commit()

        logger.info(f"Created memo from file {node_id}: {title}")
        return await self.get_asset(node_id) or {}

    async def find_by_file_path(self, file_path: str) -> dict[str, Any] | None:
        """Find a node by its file_path. Returns dict with 'id', 'type', and 'file_path' or None."""
        async with self._db() as db:
            cursor = await db.execute(
                "SELECT id, type, file_path FROM nodes WHERE file_path=?", (file_path,)
            )
            row = await cursor.fetchone()
        return dict(row) if row else None

    async def find_by_source_file(self, source_file: str) -> dict[str, Any] | None:
        """Find a node by its source_file. Returns dict with 'id', 'type', and 'file_path' or None."""
        async with self._db() as db:
            cursor = await db.execute(
                "SELECT id, type, file_path FROM nodes WHERE source_file=?", (source_file,)
            )
            row = await cursor.fetchone()
        return dict(row) if row else None

    async def get_source_file_by_id(self, node_id: str) -> dict[str, Any] | None:
        """Return {source_file, file_path, type} for a node by its id, or None."""
        async with self._db() as db:
            cursor = await db.execute(
                "SELECT source_file, file_path, type FROM nodes WHERE id=?", (node_id,)
            )
            row = await cursor.fetchone()
        if not row or not row["source_file"]:
            return None
        return dict(row)

    async def delete_by_file_path(self, file_path: str) -> bool:
        """Delete a node and its associated physical .md file by the file_path column.
        Returns True if a matching node was found and deleted."""
        async with self._db() as db:
            cursor = await db.execute(
                "SELECT id, file_path FROM nodes WHERE file_path=?", (file_path,)
            )
            row = await cursor.fetchone()
            if not row:
                return False
            await self._delete_file(row["file_path"])
            await db.execute("DELETE FROM nodes WHERE file_path=?", (file_path,))
            await db.commit()
        logger.info(f"Deleted node {row['id'][:8]} + file: {row['file_path']}")
        return True

    async def cleanup_stale_nodes(self) -> int:
        """Delete all nodes whose physical .md file no longer exists on disk.
        Returns the count of cleaned-up nodes."""
        async with self._db() as db:
            cursor = await db.execute(
                "SELECT id, file_path FROM nodes"
            )
            rows = await cursor.fetchall()

            deleted = 0
            for row in rows:
                path = self._resolve_path(row["file_path"])
                if not path.exists():
                    await db.execute("DELETE FROM nodes WHERE id=?", (row["id"],))
                    deleted += 1
                    logger.info(f"Cleaned up stale node {row['id'][:8]}: {row['file_path']}")

            if deleted > 0:
                await db.commit()
                logger.info(f"Cleaned up {deleted} stale node(s)")

        return deleted

    async def get_asset(self, node_id: str) -> dict[str, Any] | None:
        async with self._db() as db:
            cursor = await db.execute(
                "SELECT * FROM nodes WHERE id=? AND type='asset'", (node_id,)
            )
            row = await cursor.fetchone()
            if not row:
                return None
            path = self._resolve_path(row["file_path"])
            if not path.exists():
                return None
            raw_content = await self._read_file(row["file_path"])
            parsed_title, body = self._parse_markdown(raw_content)
            return {
                "id": row["id"],
                "title": row["title"] or parsed_title,
                "content": body,
                "raw_content": raw_content,
                "summary": row.get("summary"),
                "tags": json.loads(row["tags"]),
                "pinned": bool(row.get("pinned", False)),
                "parent_id": row.get("parent_id"),
                "children_count": await self._count_children(row["id"], db=db),
                "source_file": row.get("source_file"),
                "source_format": row.get("source_format"),
                "source_status": compute_source_status(self._watch_dir, row.get("source_file")),
                "created_at": row["created_at"],
                "updated_at": row["updated_at"],
            }

    async def list_assets(
        self, tag: str | None = None, limit: int = 20, offset: int = 0
    ) -> list[dict[str, Any]]:
        async with self._db() as db:
            if tag:
                cursor = await db.execute(
                    """SELECT * FROM nodes WHERE type='asset' AND tags LIKE ?
                       ORDER BY pinned DESC, updated_at DESC LIMIT ? OFFSET ?""",
                    (f'%"{tag}"%', limit, offset),
                )
            else:
                cursor = await db.execute(
                    "SELECT * FROM nodes WHERE type='asset' ORDER BY pinned DESC, updated_at DESC LIMIT ? OFFSET ?",
                    (limit, offset),
                )
            rows = await cursor.fetchall()

            results: list[dict[str, Any]] = []
            for row in rows:
                path = self._resolve_path(row["file_path"])
                if not path.exists():
                    continue
                content = await self._read_file(row["file_path"])
                parsed_title, body = self._parse_markdown(content)
                results.append({
                    "id": row["id"],
                    "title": row["title"] or parsed_title,
                    "content": body,
                    "summary": row.get("summary"),
                    "tags": json.loads(row["tags"]),
                    "pinned": bool(row.get("pinned", False)),
                    "parent_id": row.get("parent_id"),
                    "children_count": await self._count_children(row["id"], db=db),
                    "source_file": row.get("source_file"),
                    "source_format": row.get("source_format"),
                    "source_status": compute_source_status(self._watch_dir, row.get("source_file")),
                    "created_at": row["created_at"],
                    "updated_at": row["updated_at"],
                })
        return results

    async def search_assets(self, keyword: str) -> list[dict[str, Any]]:
        kw = f"%{keyword}%"
        async with self._db() as db:
            cursor = await db.execute(
                """SELECT * FROM nodes WHERE type='asset'
                   AND (title LIKE ? OR tags LIKE ?)
                   ORDER BY pinned DESC, updated_at DESC LIMIT 50""",
                (kw, kw),
            )
            rows = await cursor.fetchall()

            results: list[dict[str, Any]] = []
            seen: set[str] = set()
            for row in rows:
                path = self._resolve_path(row["file_path"])
                if not path.exists():
                    continue
                content = await self._read_file(row["file_path"])
                tags_list = json.loads(row["tags"])
                hit = (
                    keyword.lower() in row["title"].lower()
                    or keyword.lower() in content.lower()
                    or any(keyword.lower() in t.lower() for t in tags_list)
                )
                if not hit:
                    if keyword.lower() not in content.lower():
                        continue
                if row["id"] in seen:
                    continue
                seen.add(row["id"])
                parsed_title, body = self._parse_markdown(content)
                results.append({
                    "id": row["id"],
                    "title": row["title"] or parsed_title,
                    "content": body,
                    "summary": row.get("summary"),
                    "tags": tags_list,
                    "pinned": bool(row.get("pinned", False)),
                    "parent_id": row.get("parent_id"),
                    "children_count": await self._count_children(row["id"], db=db),
                    "source_file": row.get("source_file"),
                    "source_format": row.get("source_format"),
                    "source_status": compute_source_status(self._watch_dir, row.get("source_file")),
                    "created_at": row["created_at"],
                    "updated_at": row["updated_at"],
                })
        return results

    async def set_pinned(self, node_id: str, pinned: bool) -> bool:
        """Pin or unpin a memo. Returns True on success."""
        async with self._db() as db:
            cursor = await db.execute(
                "SELECT id FROM nodes WHERE id=? AND type='asset'", (node_id,)
            )
            row = await cursor.fetchone()
            if not row:
                return False
            await db.execute(
                "UPDATE nodes SET pinned=?, updated_at=? WHERE id=?",
                (1 if pinned else 0, _now(), node_id),
            )
            await db.commit()
        logger.info(f"{'Pinned' if pinned else 'Unpinned'} memo {node_id}")
        return True

    async def update_asset(
        self,
        node_id: str,
        title: str | None = None,
        content: str | None = None,
        tags: list[str] | None = None,
        summary: str | None = None,
    ) -> dict[str, Any] | None:
        async with self._db() as db:
            cursor = await db.execute(
                "SELECT * FROM nodes WHERE id=? AND type='asset'", (node_id,)
            )
            row = await cursor.fetchone()
            if not row:
                return None

        path = self._resolve_path(row["file_path"])
        if not path.exists():
            return None

        current_content = await self._read_file(row["file_path"])
        _, current_body = self._parse_markdown(current_content)

        new_body = content if content is not None else current_body
        new_summary = summary if summary is not None else row.get("summary")

        if title is not None:
            new_title = title
        elif content is not None and content.strip():
            parsed, _ = self._parse_markdown(content)
            new_title = parsed or row["title"]
        else:
            new_title = row["title"]

        new_tags = tags if tags is not None else json.loads(row["tags"])
        now = _now()

        md_text = self._markdown_content(new_title, new_body)
        await self._write_file(row["file_path"], md_text)

        async with self._db() as db:
            await db.execute(
                "UPDATE nodes SET title=?, tags=?, summary=?, updated_at=? WHERE id=?",
                (new_title.strip(), json.dumps(new_tags, ensure_ascii=False),
                 new_summary, now, node_id),
            )
            await db.commit()

        return {
            "id": node_id,
            "title": new_title.strip(),
            "content": new_body.strip(),
            "summary": new_summary,
            "tags": new_tags,
            "pinned": bool(row.get("pinned", False)),
            "created_at": row["created_at"],
            "updated_at": now,
        }

    async def delete_asset(self, node_id: str) -> bool:
        async with self._db() as db:
            cursor = await db.execute(
                "SELECT file_path FROM nodes WHERE id=? AND type='asset'", (node_id,)
            )
            row = await cursor.fetchone()
            if not row:
                return False
            await self._delete_file(row["file_path"])
            await db.execute("DELETE FROM nodes WHERE id=?", (node_id,))
            await db.commit()
        logger.info(f"Deleted asset {node_id}")
        return True

    # ------------------------------------------------------------------
    # Todo CRUD (async)
    # ------------------------------------------------------------------

    async def create_todo(
        self,
        title: str,
        description: str | None = None,
        due_date: str | None = None,
        priority: str | None = None,
        tags: list[str] | None = None,
        source_file: str | None = None,
        source_format: str | None = None,
    ) -> dict[str, Any]:
        node_id = str(uuid.uuid4())
        now = _now()
        pri = priority if priority in ("low", "medium", "high") else "medium"
        tag_list = tags or []

        await self._ensure_master_file()

        async with self._db() as db:
            await db.execute(
                """INSERT INTO nodes (id, type, file_path, title, tags, created_at, updated_at,
                                      due_date, priority, status, source_file, source_format, description)
                   VALUES (?, 'todo', ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?)""",
                (node_id, MASTER_TODOS_REL, title.strip(),
                 json.dumps(tag_list, ensure_ascii=False), now, now, due_date, pri,
                 source_file, source_format, description),
            )
            await db.commit()

        result = await self.get_todo(node_id)
        if result:
            await self.append_to_master_file([result])

        logger.info(f"Created todo {node_id}: {title}")
        return result or {}

    async def create_todo_from_file(
        self,
        title: str,
        description: str = "",
        due_date: str | None = None,
        priority: str = "medium",
        source_file: str | None = None,
        source_format: str | None = None,
        tags: list[str] | None = None,
    ) -> dict[str, Any]:
        """Create a reminder from an imported file. Stored in master_reminders.md.

        批量创建时不检查 source_file 去重 — 由调用方（FileProcessingQueue）在管道入口统一排查。
        """
        node_id = str(uuid.uuid4())
        now = _now()
        pri = priority if priority in ("low", "medium", "high") else "medium"
        tag_list = tags or []

        await self._ensure_master_file()

        async with self._db() as db:
            await db.execute(
                """INSERT INTO nodes (id, type, file_path, title, tags, created_at, updated_at,
                                      due_date, priority, status, source_file, source_format, description)
                   VALUES (?, 'todo', ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?)""",
                (node_id, MASTER_TODOS_REL, title.strip(),
                 json.dumps(tag_list, ensure_ascii=False), now, now, due_date, pri,
                 source_file, source_format, description),
            )
            await db.commit()

        logger.info(f"Created todo from file {node_id}: {title}")
        return await self.get_todo(node_id) or {}

    async def get_todo(self, node_id: str) -> dict[str, Any] | None:
        async with self._db() as db:
            cursor = await db.execute(
                "SELECT * FROM nodes WHERE id=? AND type='todo'", (node_id,)
            )
            row = await cursor.fetchone()
            if not row:
                return None
            parent_title = None
            if row.get("parent_id"):
                cursor2 = await db.execute(
                    "SELECT title FROM nodes WHERE id=?", (row["parent_id"],)
                )
                pr = await cursor2.fetchone()
                if pr:
                    parent_title = pr["title"]
        return {
            "id": row["id"],
            "title": row["title"],
            "description": row.get("description") or "",
            "tags": json.loads(row["tags"]) if row.get("tags") else [],
            "due_date": row["due_date"],
            "priority": row["priority"],
            "status": row["status"],
            "parent_id": row.get("parent_id"),
            "parent_title": parent_title,
            "source_file": row.get("source_file"),
            "source_format": row.get("source_format"),
            "source_status": compute_source_status(self._watch_dir, row.get("source_file")),
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }

    async def list_todos(
        self, status: str | None = None, limit: int = 50, offset: int = 0
    ) -> list[dict[str, Any]]:
        async with self._db() as db:
            if status:
                cursor = await db.execute(
                    """SELECT * FROM nodes WHERE type='todo' AND status=?
                       ORDER BY
                         CASE WHEN due_date IS NULL THEN 1 ELSE 0 END,
                         due_date ASC,
                         updated_at DESC
                       LIMIT ? OFFSET ?""",
                    (status, limit, offset),
                )
            else:
                cursor = await db.execute(
                    """SELECT * FROM nodes WHERE type='todo'
                       ORDER BY
                         CASE WHEN status='pending' THEN 0 ELSE 1 END,
                         CASE WHEN due_date IS NULL THEN 1 ELSE 0 END,
                         due_date ASC,
                         updated_at DESC
                       LIMIT ? OFFSET ?""",
                    (limit, offset),
                )
            rows = await cursor.fetchall()

            results: list[dict[str, Any]] = []
            for row in rows:
                parent_title = None
                if row.get("parent_id"):
                    cursor2 = await db.execute(
                        "SELECT title FROM nodes WHERE id=?", (row["parent_id"],)
                    )
                    pr = await cursor2.fetchone()
                    if pr:
                        parent_title = pr["title"]
                results.append({
                    "id": row["id"],
                    "title": row["title"],
                    "description": row.get("description") or "",
                    "tags": json.loads(row["tags"]) if row.get("tags") else [],
                    "due_date": row["due_date"],
                    "priority": row["priority"],
                    "status": row["status"],
                    "parent_id": row.get("parent_id"),
                    "parent_title": parent_title,
                    "source_file": row.get("source_file"),
                    "source_format": row.get("source_format"),
                    "source_status": compute_source_status(self._watch_dir, row.get("source_file")),
                    "created_at": row["created_at"],
                    "updated_at": row["updated_at"],
                })
        return results

    async def get_upcoming_todos(self, days: int = 7) -> list[dict[str, Any]]:
        """Reminders where due_date is between now and now+days, still pending."""
        now = datetime.now().astimezone()
        today = now.strftime("%Y-%m-%d")
        end_date = (now + timedelta(days=days)).strftime("%Y-%m-%d")

        async with self._db() as db:
            cursor = await db.execute(
                """SELECT * FROM nodes WHERE type='todo' AND status='pending'
                   AND due_date IS NOT NULL AND due_date >= ? AND due_date <= ?
                   ORDER BY due_date ASC, priority DESC""",
                (today, end_date),
            )
            rows = await cursor.fetchall()

            results: list[dict[str, Any]] = []
            for row in rows:
                parent_title = None
                if row.get("parent_id"):
                    cursor2 = await db.execute(
                        "SELECT title FROM nodes WHERE id=?", (row["parent_id"],)
                    )
                    pr = await cursor2.fetchone()
                    if pr:
                        parent_title = pr["title"]
                results.append({
                    "id": row["id"],
                    "title": row["title"],
                    "description": row.get("description") or "",
                    "tags": json.loads(row["tags"]) if row.get("tags") else [],
                    "due_date": row["due_date"],
                    "priority": row["priority"],
                    "status": row["status"],
                    "parent_id": row.get("parent_id"),
                    "parent_title": parent_title,
                    "source_file": row.get("source_file"),
                    "source_format": row.get("source_format"),
                    "source_status": compute_source_status(self._watch_dir, row.get("source_file")),
                    "created_at": row["created_at"],
                    "updated_at": row["updated_at"],
                })
        return results

    async def update_todo(
        self,
        node_id: str,
        title: str | None = None,
        description: str | None = None,
        due_date: str | None = None,
        priority: str | None = None,
        status: str | None = None,
    ) -> dict[str, Any] | None:
        async with self._db() as db:
            cursor = await db.execute(
                "SELECT * FROM nodes WHERE id=? AND type='todo'", (node_id,)
            )
            row = await cursor.fetchone()
            if not row:
                return None

        now = _now()

        updates: dict[str, Any] = {"updated_at": now}
        if title is not None:
            updates["title"] = title.strip()
        if due_date is not None:
            updates["due_date"] = due_date
        if priority is not None:
            updates["priority"] = priority
        if status is not None:
            updates["status"] = status
        if description is not None:
            updates["description"] = description

        set_clause = ", ".join(f"{k}=?" for k in updates)
        values = list(updates.values()) + [node_id]

        async with self._db() as db:
            await db.execute(f"UPDATE nodes SET {set_clause} WHERE id=?", values)
            await db.commit()

        # 同步更新 master_reminders.md 中的对应行
        if row["file_path"] == MASTER_TODOS_REL:
            await self._rewrite_master_line(node_id)

        return await self.get_todo(node_id)

    async def delete_todo(self, node_id: str) -> bool:
        async with self._db() as db:
            cursor = await db.execute(
                "SELECT file_path FROM nodes WHERE id=? AND type='todo'", (node_id,)
            )
            row = await cursor.fetchone()
            if not row:
                return False
            # 从 master_reminders.md 中移除对应行（不删除整个 master 文件）
            if row["file_path"] == MASTER_TODOS_REL:
                await self._remove_master_line(node_id)
            else:
                await self._delete_file(row["file_path"])
            await db.execute("DELETE FROM nodes WHERE id=?", (node_id,))
            await db.commit()
        logger.info(f"Deleted todo {node_id}")
        return True

    async def complete_todo(self, node_id: str) -> dict[str, Any] | None:
        async with self._db() as db:
            cursor = await db.execute(
                "SELECT * FROM nodes WHERE id=? AND type='todo'", (node_id,)
            )
            row = await cursor.fetchone()
            if not row:
                return None
            now = _now()
            await db.execute(
                "UPDATE nodes SET status='completed', updated_at=? WHERE id=?",
                (now, node_id),
            )
            await db.commit()
        # 同步更新 master_reminders.md 中对应行的 checkbox
        if row["file_path"] == MASTER_TODOS_REL:
            await self._update_master_line(node_id, "completed")
        return await self.get_todo(node_id)

    # ------------------------------------------------------------------
    # Parent-Child relationship queries (async)
    # ------------------------------------------------------------------

    async def _count_children(
        self, node_id: str, db: aiosqlite.Connection | None = None
    ) -> dict[str, int]:
        """Count child todos and schedules for a given parent node.

        When *db* is provided, reuses that connection (useful in list/search loops).
        Otherwise creates a fresh connection.
        """
        if db is None:
            async with self._db() as fresh_db:
                return await self._count_children(node_id, db=fresh_db)

        cursor = await db.execute(
            "SELECT COUNT(*) AS cnt FROM nodes WHERE parent_id=? AND type='todo'",
            (node_id,),
        )
        row = await cursor.fetchone()
        todo_count = row["cnt"]
        try:
            cursor2 = await db.execute(
                "SELECT COUNT(*) AS cnt FROM events WHERE parent_id=?",
                (node_id,),
            )
            row2 = await cursor2.fetchone()
            schedule_count = row2["cnt"]
        except sqlite3.OperationalError:
            schedule_count = 0
        return {"todos": todo_count, "schedules": schedule_count}

    async def get_children(self, parent_id: str) -> list[dict[str, Any]]:
        """Return all child nodes (todos + events) for a given parent asset."""
        children: list[dict[str, Any]] = []

        async with self._db() as db:
            # Child todos from nodes table
            cursor = await db.execute(
                "SELECT * FROM nodes WHERE parent_id=? AND type='todo' ORDER BY created_at ASC",
                (parent_id,),
            )
            todo_rows = await cursor.fetchall()
            for row in todo_rows:
                children.append({
                    "id": row["id"],
                    "type": "todo",
                    "title": row["title"],
                    "description": row.get("description") or "",
                    "due_date": row.get("due_date"),
                    "priority": row.get("priority"),
                    "status": row.get("status"),
                    "tags": json.loads(row["tags"]) if row.get("tags") else [],
                    "source_file": row.get("source_file"),
                    "source_format": row.get("source_format"),
                    "source_status": compute_source_status(self._watch_dir, row.get("source_file")),
                    "created_at": row["created_at"],
                    "updated_at": row["updated_at"],
                })

            # Child schedules from events table (via calendar_service)
            try:
                cursor2 = await db.execute(
                    "SELECT * FROM events WHERE parent_id=? ORDER BY start_time ASC",
                    (parent_id,),
                )
                event_rows = await cursor2.fetchall()
                for row in event_rows:
                    children.append({
                        "id": row["id"],
                        "type": "schedule",
                        "title": row["title"],
                        "description": row.get("description") or "",
                        "start_time": row.get("start_time"),
                        "end_time": row.get("end_time"),
                        "is_all_day": bool(row.get("is_all_day", False)),
                        "event_type": row.get("type", "plan"),
                        "source_file": row.get("source_file"),
                        "source_format": row.get("source_format"),
                        "source_status": compute_source_status(self._watch_dir, row.get("source_file")),
                        "created_at": row["created_at"],
                        "updated_at": row["updated_at"],
                    })
            except sqlite3.OperationalError:
                pass  # events table may not exist yet or parent_id column not added

        return children

    async def get_parent(self, node_id: str) -> dict[str, Any] | None:
        """Return the parent asset info for a child node (todo or event)."""
        async with self._db() as db:
            cursor = await db.execute(
                "SELECT parent_id FROM nodes WHERE id=? AND parent_id IS NOT NULL",
                (node_id,),
            )
            row = await cursor.fetchone()
            if not row:
                # Try events table
                try:
                    cursor2 = await db.execute(
                        "SELECT parent_id FROM events WHERE id=? AND parent_id IS NOT NULL",
                        (node_id,),
                    )
                    row = await cursor2.fetchone()
                except sqlite3.OperationalError:
                    pass
        if not row:
            return None
        return await self.get_asset(row["parent_id"])

    # ------------------------------------------------------------------
    # Cross-table helpers — for reclassify and file_queue linking
    # ------------------------------------------------------------------

    async def set_parent(self, node_id: str, parent_id: str, file_path: str) -> None:
        """Link a child node to its parent asset. Used by FileProcessingQueue."""
        async with self._db() as db:
            await db.execute(
                "UPDATE nodes SET parent_id=?, file_path=? WHERE id=?",
                (parent_id, file_path, node_id),
            )
            await db.commit()

    async def _get_node_any(self, node_id: str) -> dict[str, Any] | None:
        """Get any node by ID (asset or todo). Returns raw DB row or None."""
        async with self._db() as db:
            cursor = await db.execute(
                "SELECT * FROM nodes WHERE id=?", (node_id,)
            )
            row = await cursor.fetchone()
        return dict(row) if row else None

    async def _update_node_raw(self, node_id: str, **fields) -> None:
        """Update arbitrary fields on a node. For cross-cutting operations."""
        if not fields:
            return
        set_clause = ", ".join(f"{k}=?" for k in fields)
        values = list(fields.values()) + [node_id]
        async with self._db() as db:
            await db.execute(
                f"UPDATE nodes SET {set_clause} WHERE id=?", values
            )
            await db.commit()

    async def _delete_node_raw(self, node_id: str) -> bool:
        """Delete a node row without any file I/O. Returns True if deleted."""
        async with self._db() as db:
            cursor = await db.execute(
                "SELECT id FROM nodes WHERE id=?", (node_id,)
            )
            if not await cursor.fetchone():
                return False
            await db.execute("DELETE FROM nodes WHERE id=?", (node_id,))
            await db.commit()
        return True

    async def _insert_node_raw(self, fields: dict[str, Any]) -> str:
        """Insert a node row with arbitrary fields. Returns the new node_id."""
        node_id = fields.pop("id", str(uuid.uuid4()))
        columns = ", ".join(fields.keys())
        placeholders = ", ".join("?" for _ in fields)
        async with self._db() as db:
            await db.execute(
                f"INSERT INTO nodes (id, {columns}) VALUES (?, {placeholders})",
                (node_id, *fields.values()),
            )
            await db.commit()
        return node_id


# ---------------------------------------------------------------------------
# LangChain tool factory
# ---------------------------------------------------------------------------


def create_asset_tools(service: MemoService) -> list:
    """Convert MemoService methods to LangChain StructuredTool list (asset + todo).

    All service methods are now async — tools call them directly without
    ``asyncio.to_thread()`` wrappers, since each method already uses its
    own independent database connection.
    """
    from langchain_core.tools import StructuredTool
    from pydantic import BaseModel, Field

    # Memo input models
    class CreateAssetInput(BaseModel):
        title: str = Field(..., description="资产条目标题")
        content: str = Field("", description="资产条目正文（Markdown 格式）")
        tags: list[str] | None = Field(None, description="标签列表，如 ['工作','个人']")

    class ListAssetsInput(BaseModel):
        tag: str | None = Field(None, description="按标签筛选，留空则列出全部")
        limit: int = Field(20, description="返回条数上限")
        offset: int = Field(0, description="分页偏移量")

    class SearchAssetsInput(BaseModel):
        keyword: str = Field(..., description="搜索关键字，匹配标题和正文")

    class GetAssetInput(BaseModel):
        id: str = Field(..., description="资产条目 ID")

    class UpdateAssetInput(BaseModel):
        id: str = Field(..., description="要更新的资产条目 ID")
        title: str | None = Field(None, description="新标题")
        content: str | None = Field(None, description="新正文")
        tags: list[str] | None = Field(None, description="新标签列表")

    class DeleteAssetInput(BaseModel):
        id: str = Field(..., description="要删除的资产条目 ID")

    # Reminder input models
    class CreateTodoInput(BaseModel):
        title: str = Field(..., description="待办标题")
        description: str | None = Field(None, description="待办描述")
        due_date: str | None = Field(None, description="到期日期，格式 YYYY-MM-DD 或 YYYY-MM-DD HH:MM")
        priority: str | None = Field(None, description="优先级：low（低）/ medium（中）/ high（高）")

    class ListTodosInput(BaseModel):
        status: str | None = Field(None, description="按状态筛选：pending（待处理）或 completed（已完成），留空则全部")
        limit: int = Field(50, description="返回条数上限")
        offset: int = Field(0, description="分页偏移量")

    class GetUpcomingTodosInput(BaseModel):
        days: int = Field(7, description="未来几天内到期的提醒")

    class GetTodoInput(BaseModel):
        id: str = Field(..., description="待办 ID")

    class UpdateTodoInput(BaseModel):
        id: str = Field(..., description="要更新的待办 ID")
        title: str | None = Field(None, description="新标题")
        description: str | None = Field(None, description="新描述")
        due_date: str | None = Field(None, description="新到期日期")
        priority: str | None = Field(None, description="新优先级")
        status: str | None = Field(None, description="新状态：pending 或 completed")

    class DeleteTodoInput(BaseModel):
        id: str = Field(..., description="要删除的待办 ID")

    class CompleteTodoInput(BaseModel):
        id: str = Field(..., description="要标记为已完成的待办 ID")

    # Helper: format result dict as readable Chinese text
    def _format_asset(m: dict) -> str:
        tags_str = ", ".join(m.get("tags", [])) or "无"
        return (
            f"📄 资产条目 (ID: {m['id']})\n"
            f"标题: {m['title']}\n"
            f"内容: {m['content'] or '(空)'}\n"
            f"标签: {tags_str}\n"
            f"创建: {m['created_at']}  更新: {m['updated_at']}"
        )

    def _format_asset_list(memos: list[dict]) -> str:
        if not memos:
            return "暂无资产条目。"
        lines = [f"共 {len(memos)} 条资产条目："]
        for m in memos:
            tags_str = ", ".join(m.get("tags", [])) or "无"
            preview = m["content"][:60] + "..." if len(m.get("content", "")) > 60 else m.get("content", "")
            lines.append(
                f"\n[{m['id'][:8]}] {m['title']}\n"
                f"    {preview}\n"
                f"    🏷 {tags_str}  🕐 {m['updated_at']}"
            )
        return "\n".join(lines)

    def _format_todo(r: dict) -> str:
        pri_map = {"low": "🟢 低", "medium": "🟡 中", "high": "🔴 高"}
        status_str = "✅ 已完成" if r.get("status") == "completed" else "⏳ 待处理"
        return (
            f"📋 待办事项 (ID: {r['id']})\n"
            f"标题: {r['title']}\n"
            f"描述: {r.get('description') or '(空)'}\n"
            f"到期: {r.get('due_date') or '未设定'}\n"
            f"优先级: {pri_map.get(r.get('priority', 'medium'), r.get('priority'))}\n"
            f"状态: {status_str}\n"
            f"创建: {r['created_at']}  更新: {r['updated_at']}"
        )

    def _format_todo_list(reminders: list[dict]) -> str:
        if not reminders:
            return "暂无待办事项。"
        lines = [f"共 {len(reminders)} 条待办："]
        for r in reminders:
            due = r.get("due_date") or "未设定"
            status_mark = "✅" if r.get("status") == "completed" else "○"
            lines.append(
                f"\n{status_mark} [{r['id'][:8]}] {r['title']}\n"
                f"    📅 {due}  |  {'🔴' if r.get('priority') == 'high' else '🟡' if r.get('priority') == 'medium' else '🟢'} {r.get('priority', 'medium')}"
            )
        return "\n".join(lines)

    # Build tool list
    tools: list[StructuredTool] = []

    # --- Asset tools ---

    async def _create_asset_inner(**kwargs):
        return _format_asset(await service.create_asset(**kwargs))

    tools.append(StructuredTool(
        name="create_asset",
        description="创建一条新资产条目。包含标题、正文（Markdown）和标签。",
        args_schema=CreateAssetInput,
        coroutine=_create_asset_inner,
    ))

    async def _list_assets(**kwargs):
        return _format_asset_list(await service.list_assets(**kwargs))

    tools.append(StructuredTool(
        name="list_assets",
        description="列出所有资产条目，可按标签筛选，支持分页。",
        args_schema=ListAssetsInput,
        coroutine=_list_assets,
    ))

    async def _search_assets(**kwargs):
        return _format_asset_list(await service.search_assets(**kwargs))

    tools.append(StructuredTool(
        name="search_assets",
        description="按关键字搜索资产条目，匹配标题和正文。",
        args_schema=SearchAssetsInput,
        coroutine=_search_assets,
    ))

    async def _get_asset_inner(**kwargs):
        result = await service.get_asset(kwargs["id"])
        if result is None:
            return f"未找到 ID 为 {kwargs['id']} 的资产条目。"
        return _format_asset(result)

    tools.append(StructuredTool(
        name="get_asset",
        description="按 ID 查看单条资产条目的完整内容。",
        args_schema=GetAssetInput,
        coroutine=_get_asset_inner,
    ))

    async def _update_asset_inner(**kwargs):
        result = await service.update_asset(
            kwargs.pop("id"),
            **{k: v for k, v in kwargs.items() if v is not None},
        )
        if result is None:
            return "更新失败：未找到指定的资产条目。"
        return f"✅ 资产条目已更新\n{_format_asset(result)}"

    tools.append(StructuredTool(
        name="update_asset",
        description="更新一条已有资产条目。只更新提供的字段，未提供的保持不变。",
        args_schema=UpdateAssetInput,
        coroutine=_update_asset_inner,
    ))

    async def _delete_asset_inner(**kwargs):
        ok = await service.delete_asset(kwargs["id"])
        if ok:
            return f"✅ 备忘录 {kwargs['id']} 已删除。"
        return f"删除失败：未找到 ID 为 {kwargs['id']} 的资产条目。"

    tools.append(StructuredTool(
        name="delete_asset",
        description="删除一条备忘录。操作不可撤销，请先向用户确认。",
        args_schema=DeleteAssetInput,
        coroutine=_delete_asset_inner,
    ))

    # --- Todo tools ---

    async def _create_todo_inner(**kwargs):
        return _format_todo(
            await service.create_todo(
                title=kwargs["title"],
                description=kwargs.get("description"),
                due_date=kwargs.get("due_date"),
                priority=kwargs.get("priority"),
            )
        )

    tools.append(StructuredTool(
        name="create_todo",
        description="创建一条新待办事项。设置标题、描述、到期日期和优先级（low/medium/high）。",
        args_schema=CreateTodoInput,
        coroutine=_create_todo_inner,
    ))

    async def _list_todos_inner(**kwargs):
        return _format_todo_list(await service.list_todos(**kwargs))

    tools.append(StructuredTool(
        name="list_todos",
        description="列出所有待办事项，可按状态（pending/completed）筛选。",
        args_schema=ListTodosInput,
        coroutine=_list_todos_inner,
    ))

    async def _get_upcoming_todos(**kwargs):
        results = await service.get_upcoming_todos(kwargs.get("days", 7))
        if not results:
            return f"未来 {kwargs.get('days', 7)} 天内没有待处理的待办。"
        return f"📋 未来 {kwargs.get('days', 7)} 天内到期的待办：\n{_format_todo_list(results)}"

    tools.append(StructuredTool(
        name="get_upcoming_todos",
        description="查看未来 N 天内即将到期的待办事项（默认 7 天）。",
        args_schema=GetUpcomingTodosInput,
        coroutine=_get_upcoming_todos,
    ))

    async def _get_todo_inner(**kwargs):
        result = await service.get_todo(kwargs["id"])
        if result is None:
            return f"未找到 ID 为 {kwargs['id']} 的待办。"
        return _format_todo(result)

    tools.append(StructuredTool(
        name="get_todo",
        description="按 ID 查看单条提醒的完整详情。",
        args_schema=GetTodoInput,
        coroutine=_get_todo_inner,
    ))

    async def _update_todo_inner(**kwargs):
        node_id = kwargs.pop("id")
        result = await service.update_todo(
            node_id,
            **{k: v for k, v in kwargs.items() if v is not None},
        )
        if result is None:
            return "更新失败：未找到指定的待办。"
        return f"✅ 提醒已更新\n{_format_todo(result)}"

    tools.append(StructuredTool(
        name="update_todo",
        description="更新一条已有待办。只更新提供的字段，未提供的保持不变。",
        args_schema=UpdateTodoInput,
        coroutine=_update_todo_inner,
    ))

    async def _delete_todo_inner(**kwargs):
        ok = await service.delete_todo(kwargs["id"])
        if ok:
            return f"✅ 提醒 {kwargs['id']} 已删除。"
        return f"删除失败：未找到 ID 为 {kwargs['id']} 的待办。"

    tools.append(StructuredTool(
        name="delete_todo",
        description="删除一条待办事项。操作不可撤销，请先向用户确认。",
        args_schema=DeleteTodoInput,
        coroutine=_delete_todo_inner,
    ))

    async def _complete_todo(**kwargs):
        result = await service.complete_todo(kwargs["id"])
        if result is None:
            return f"操作失败：未找到 ID 为 {kwargs['id']} 的待办。"
        return f"✅ 已标记完成\n{_format_todo(result)}"

    tools.append(StructuredTool(
        name="complete_todo",
        description="将一条待办标记为「已完成」。",
        args_schema=CompleteTodoInput,
        coroutine=_complete_todo,
    ))

    return tools
