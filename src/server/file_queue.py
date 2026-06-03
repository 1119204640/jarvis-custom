"""
Unified file processing queue — all three entry points converge here.

Paths:
  1. App-created documents  → submit_inline()   (UPDATE existing DB record)
  2. Watchdog-detected files → submit_file()     (CREATE new DB record)
  3. Manual scan             → submit_file()     (CREATE new DB record)

Temp files for Path 1 are staged in data/queue/, processed through a single
pipeline, and final results land in data/vault/.
"""

from __future__ import annotations

import asyncio
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Awaitable, Callable, Literal

import aiofiles
from loguru import logger

from .constants import DATA_DIR, MAX_CONCURRENT_FILE_PROCESSING
from .file_watcher import (
    FileParser,
    FileSummarizer,
    _parse_target_date,
    _replace_extracted_markers,
)

# ---------------------------------------------------------------------------
# FileJob — unified task descriptor
# ---------------------------------------------------------------------------


@dataclass
class FileJob:
    """A file waiting to be processed by the unified LLM pipeline."""

    job_id: str
    mode: Literal["create", "update"]
    staging_path: Path  # path to the file for summarizer input
    origin_name: str  # display name for progress messages

    # Update mode only
    doc_id: str | None = None

    # Create mode only
    source_file: str | None = None  # relative path from watch_dir
    source_format: str | None = None


# ---------------------------------------------------------------------------
# FileProcessingQueue
# ---------------------------------------------------------------------------


class FileProcessingQueue:
    """Unified file processing pipeline with a bounded async queue and
    concurrent workers.

    All three entry points (inline docs, watchdog, manual scan) submit jobs
    here.  Jobs are processed by :meth:`_process_job`, and results land in
    ``data/vault/``.
    """

    def __init__(
        self,
        memo_service,
        calendar_service,
        max_concurrent: int = MAX_CONCURRENT_FILE_PROCESSING,
    ):
        self._memo = memo_service
        self._calendar = calendar_service
        self._max_concurrent = max_concurrent
        self._summarizer = FileSummarizer()
        self._queue_dir = DATA_DIR / "queue"

        # ------------------------------------------------------------------
        # Fix 2: bounded queue for backpressure under bulk scan
        # ------------------------------------------------------------------
        self._queue: asyncio.Queue[FileJob] = asyncio.Queue(maxsize=100)

        # ------------------------------------------------------------------
        # Fix 1: race-condition guard — memory set + asyncio.Lock
        # ------------------------------------------------------------------
        self._processing_paths: set[str] = set()
        self._processing_lock = asyncio.Lock()

        # Injected progress callbacks (set via set_progress_callbacks)
        self._emit_progress: Callable[[str, str], Awaitable[None]] | None = None
        self._emit_data_changed: Callable[[str, dict], Awaitable[None]] | None = None
        self._emit_queue_snapshot: Callable[[list[dict]], Awaitable[None]] | None = None

        # ------------------------------------------------------------------
        # Queue state tracking: job_id → {name, status, stage, mode}
        # status: "queued" | "processing" | "done" | "error"
        # ------------------------------------------------------------------
        self._job_states: dict[str, dict] = {}

        # ------------------------------------------------------------------
        # Fix 5: track active tasks so stop() can wait for graceful drain
        # ------------------------------------------------------------------
        self._running = False
        self._workers: list[asyncio.Task] = []
        self._active_tasks: dict[str, asyncio.Task] = {}

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    async def start(self) -> None:
        """Start N concurrent worker coroutines (Fix 3: real concurrency)."""
        self._running = True
        self._queue_dir.mkdir(parents=True, exist_ok=True)
        self._workers = [
            asyncio.create_task(self._worker_loop(i))
            for i in range(self._max_concurrent)
        ]
        logger.info(
            f"FileProcessingQueue started with {self._max_concurrent} workers "
            f"(queue maxsize={self._queue.maxsize})"
        )

    async def stop(self) -> None:
        """Gracefully shut down (Fix 5): drain in-flight jobs, then cancel workers.

        1. Set _running=False → workers stop accepting new jobs from the queue.
        2. Wait for currently executing _process_job calls to finish.
        3. Cancel idle workers (those blocked on queue.get()).
        """
        self._running = False

        # Wait for in-flight jobs to complete (workers currently inside _process_job)
        if self._active_tasks:
            logger.info(
                f"FileProcessingQueue waiting for {len(self._active_tasks)} "
                f"active job(s) to complete..."
            )
            await asyncio.gather(*self._active_tasks.values(), return_exceptions=True)

        # Cancel all workers (idle ones blocked on get(), or already-done ones)
        for w in self._workers:
            w.cancel()
        if self._workers:
            await asyncio.gather(*self._workers, return_exceptions=True)
        self._workers.clear()

        remaining = self._queue.qsize()
        if remaining:
            logger.warning(
                f"FileProcessingQueue stopped with {remaining} unprocessed job(s) "
                f"(dropped)"
            )
        logger.info("FileProcessingQueue stopped")

    def set_progress_callbacks(
        self,
        emit_progress: Callable[[str, str], Awaitable[None]],
        emit_data_changed: Callable[[str, dict], Awaitable[None]],
        emit_queue_snapshot: Callable[[list[dict]], Awaitable[None]] | None = None,
    ) -> None:
        """Inject Socket.IO progress emitters (avoids circular imports)."""
        self._emit_progress = emit_progress
        self._emit_data_changed = emit_data_changed
        self._emit_queue_snapshot = emit_queue_snapshot

    # ------------------------------------------------------------------
    # Public submission API
    # ------------------------------------------------------------------

    async def submit_inline(self, doc_id: str, title: str, content: str) -> None:
        """Path 1 — app-created document that needs LLM enrichment.

        Writes a temp .md into ``data/queue/`` and enqueues an **update** job.

        Raises ValueError if *content* is empty (Fix 4).
        """
        # Fix 4: reject empty content before any I/O
        if not content or not content.strip():
            raise ValueError("content must not be empty")

        # Fix 1: atomic dedup check + register under lock
        async with self._processing_lock:
            if doc_id in self._processing_paths:
                logger.info(f"Skipping inline doc {doc_id[:8]} — already in queue")
                return
            self._processing_paths.add(doc_id)

        self._queue_dir.mkdir(parents=True, exist_ok=True)
        staging = self._queue_dir / f"_inline_{doc_id}.md"
        staging.write_text(f"# {title}\n\n{content}", encoding="utf-8")

        job = FileJob(
            job_id=str(uuid.uuid4()),
            mode="update",
            staging_path=staging,
            origin_name=title,
            doc_id=doc_id,
        )
        # Record queue state
        self._job_states[job.job_id] = {
            "name": title,
            "status": "queued",
            "stage": "等待处理",
            "mode": "update",
        }
        # Fix 2: await on bounded queue — naturally blocks under bulk load
        await self._queue.put(job)
        await self._emit_queue_snapshot_if_needed()
        logger.info(f"Queued inline doc {doc_id[:8]} ({title})")

    async def submit_file(self, file_path: Path, watch_dir: Path) -> None:
        """Path 2/3 — file from watched directory (watchdog or manual scan).

        Deduplicates against both the in-memory processing set AND the DB
        under a single lock to close the TOCTOU race between watchdog and
        manual scan (Fix 1).
        """
        if not FileParser.is_supported(file_path):
            logger.info(f"Skipping unsupported file: {file_path.name}")
            return

        source_file = str(file_path.relative_to(watch_dir))
        source_format = file_path.suffix.lstrip(".")

        # Fix 1: memory-set check + DB check atomically under lock.
        # This closes the window where watchdog and manual scan both pass
        # find_by_source_file before either creates the DB record.
        async with self._processing_lock:
            if source_file in self._processing_paths:
                logger.info(
                    f"Skipping {file_path.name} — already being processed"
                )
                return

            existing = await self._memo.find_by_source_file(source_file)
            if existing is not None:
                logger.info(
                    f"Skipping {file_path.name} — already tracked as "
                    f"{existing['type']} ({existing['id'][:8]})"
                )
                return

            self._processing_paths.add(source_file)

        # Empty file check (non-vision files only) — outside lock to avoid
        # holding it during I/O.  Roll back the processing-path registration
        # if we bail out here.
        try:
            preview = file_path.read_text(encoding="utf-8", errors="replace")
            if not preview or not preview.strip():
                logger.info(f"Skipping empty file: {file_path.name}")
                async with self._processing_lock:
                    self._processing_paths.discard(source_file)
                return
        except Exception:
            pass  # binary files (images/PDFs) — let summarizer handle read errors

        job = FileJob(
            job_id=str(uuid.uuid4()),
            mode="create",
            staging_path=file_path,  # use original path directly
            origin_name=file_path.name,
            source_file=source_file,
            source_format=source_format,
        )
        # Record queue state
        self._job_states[job.job_id] = {
            "name": file_path.name,
            "status": "queued",
            "stage": "等待处理",
            "mode": "create",
        }
        # Fix 2: await on bounded queue — naturally blocks under bulk load
        await self._queue.put(job)
        await self._emit_queue_snapshot_if_needed()
        logger.info(f"Queued file {file_path.name} (source={source_file})")

    # ------------------------------------------------------------------
    # Worker
    # ------------------------------------------------------------------

    async def _worker_loop(self, worker_id: int) -> None:
        """Long-running consumer (Fix 3): pop jobs from the shared bounded
        queue and process them directly — no artificial semaphore needed
        because the fixed-size worker pool IS the concurrency limit."""
        logger.info(f"Worker {worker_id} started")
        while self._running:
            try:
                job = await asyncio.wait_for(self._queue.get(), timeout=1.0)
            except asyncio.TimeoutError:
                continue
            except asyncio.CancelledError:
                break

            # Fix 5: register this task so stop() can wait for it
            task = asyncio.current_task()
            if task is not None:
                self._active_tasks[job.job_id] = task

            try:
                await self._process_job(job)
            except Exception:
                logger.opt(exception=True).error(
                    f"Unhandled error processing job {job.job_id[:8]}"
                )
            finally:
                self._active_tasks.pop(job.job_id, None)
                self._queue.task_done()

        logger.info(f"Worker {worker_id} stopped")

    # ------------------------------------------------------------------
    # Unified pipeline
    # ------------------------------------------------------------------

    async def _process_job(self, job: FileJob) -> None:
        """Single unified pipeline with dedup-key cleanup in ``finally``."""

        is_create = job.mode == "create"
        stage_prefix = "file" if is_create else "doc"
        dedup_key = job.source_file if is_create else job.doc_id

        try:
            await self._process_job_impl(job, is_create, stage_prefix)
        finally:
            # Fix 1: always release the dedup guard, even on failure
            if dedup_key:
                async with self._processing_lock:
                    self._processing_paths.discard(dedup_key)

    async def _process_job_impl(
        self, job: FileJob, is_create: bool, stage_prefix: str
    ) -> None:
        """Core pipeline logic, wrapped by _process_job for cleanup."""

        # -- update queue state: processing started --
        if job.job_id in self._job_states:
            self._job_states[job.job_id]["status"] = "processing"
            self._job_states[job.job_id]["stage"] = "正在分析..."
            await self._emit_queue_snapshot_if_needed()

        # -- progress: started --
        await self._emit("progress", f"{stage_prefix}_processing",
                         f"正在分析: {job.origin_name}")

        # -- 1. summarise --
        try:
            result = await self._summarizer.summarize(job.staging_path)
        except Exception:
            logger.opt(exception=True).error(
                f"Summarization failed for {job.origin_name}")
            await self._emit("progress", f"{stage_prefix}_error",
                             f"处理失败: {job.origin_name}")
            if job.job_id in self._job_states:
                self._job_states[job.job_id]["status"] = "error"
                self._job_states[job.job_id]["stage"] = "处理失败"
                await self._emit_queue_snapshot_if_needed()
                asyncio.create_task(self._cleanup_job_state(job.job_id))
            return

        title = result.get("title") or job.origin_name
        tags = result.get("tags", [])
        llm_content = result.get("content", "")
        reminders = result.get("reminders", [])
        schedules = result.get("schedules", [])

        logger.info(
            f"Summarized {job.origin_name} → title={title} | tags={tags} | "
            f"reminders={len(reminders)} | schedules={len(schedules)}"
        )

        # -- 2. create or update parent document --
        if is_create:
            parent_id = str(uuid.uuid4())
            md_relative = f"vault/{parent_id}.md"
            await self._memo.create_asset_from_file(
                title=title,
                content=llm_content,
                tags=tags,
                file_path_rel=md_relative,
                source_file=job.source_file,
                source_format=job.source_format if job.source_format != "md" else None,
                summary=result.get("summary"),
            )
        else:
            parent_id = job.doc_id
            await self._memo.update_asset(
                parent_id, title=title, content=llm_content, tags=tags,
                summary=result.get("summary"),
            )
            asset_info = await self._memo.get_asset(parent_id)
            md_relative = (
                asset_info.get("file_path", f"vault/{parent_id}.md")
                if asset_info else f"vault/{parent_id}.md"
            )

        # -- 3. create child todos & schedules --
        todo_ids, sched_ids = await self._create_children(
            parent_id=parent_id,
            md_relative=md_relative,
            reminders=reminders,
            schedules=schedules,
            tags=tags,
            source_file=job.source_file,
            source_format=job.source_format if job.source_format != "md" else None,
        )

        # -- 4. replace {extracted:N} markers --
        if todo_ids or sched_ids:
            llm_content = _replace_extracted_markers(
                llm_content, todo_ids, sched_ids)
            if is_create:
                # Create mode: content lives in memory, written to vault in step 5
                pass
            else:
                # Update mode: persist marker-replaced content now
                await self._memo.update_asset(parent_id, content=llm_content)

        # -- 5. write vault .md (create mode only) --
        if is_create:
            await self._write_vault_md(parent_id, llm_content)

        # -- 6. cleanup staging file (inline docs only) --
        if not is_create:
            job.staging_path.unlink(missing_ok=True)

        # -- progress: done --
        children_stats = {"todos": len(todo_ids), "schedules": len(sched_ids)}
        detail_parts = [f"已保存为文档: {title}"]
        if children_stats["todos"] or children_stats["schedules"]:
            sub_parts = []
            if children_stats["todos"]:
                sub_parts.append(f"{children_stats['todos']}个待办")
            if children_stats["schedules"]:
                sub_parts.append(f"{children_stats['schedules']}个日程")
            detail_parts.append(f"（识别出{'，'.join(sub_parts)}）")
        msg = "".join(detail_parts)

        await self._emit("progress", f"{stage_prefix}_done", msg)
        await self._emit("data_changed",
                         "document_processed" if not is_create else "file_processed",
                         {"id": parent_id, "file": job.origin_name})

        # -- update queue state: done --
        if job.job_id in self._job_states:
            self._job_states[job.job_id]["status"] = "done"
            self._job_states[job.job_id]["stage"] = "处理完成"
            await self._emit_queue_snapshot_if_needed()
            asyncio.create_task(self._cleanup_job_state(job.job_id))

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    async def _create_children(
        self,
        parent_id: str,
        md_relative: str,
        reminders: list[dict],
        schedules: list[dict],
        tags: list[str],
        source_file: str | None,
        source_format: str | None,
    ) -> tuple[list[str], list[str]]:
        """Create child todos and schedules, linking them to *parent_id*.

        Returns (todo_child_ids, schedule_child_ids).
        """
        todo_ids: list[str] = []
        sched_ids: list[str] = []

        # -- child todos --
        if reminders:
            todo_list: list[dict[str, Any]] = []
            for item in reminders:
                r = await self._memo.create_todo_from_file(
                    title=item["title"],
                    description="",
                    due_date=item.get("due_date"),
                    priority=item.get("priority", "medium"),
                    source_file=source_file,
                    source_format=source_format,
                    tags=tags,
                )
                await self._memo.set_parent(r["id"], parent_id, md_relative)
                todo_list.append(r)
                todo_ids.append(r["id"])
            if todo_list:
                await self._memo.append_to_master_file(todo_list)

        # -- child schedules --
        if schedules and self._calendar:
            for item in schedules:
                sched_start = _parse_target_date(item.get("target_date"))
                ev = self._calendar.create_event_from_file(
                    title=item["title"],
                    description="",
                    start_time=sched_start,
                    end_time=sched_start,
                    type="plan",
                    file_path_rel=md_relative,
                    source_file=source_file,
                    source_format=source_format,
                )
                self._calendar.set_event_parent(ev["id"], parent_id)
                sched_ids.append(ev["id"])

        return todo_ids, sched_ids

    async def _write_vault_md(self, parent_id: str, content: str) -> None:
        """Write the final .md file into data/vault/."""
        md_relative = f"vault/{parent_id}.md"
        md_path = self._memo.data_dir / md_relative
        md_path.parent.mkdir(parents=True, exist_ok=True)
        async with aiofiles.open(str(md_path), "w", encoding="utf-8") as f:
            await f.write(content)
        logger.info(f"Wrote vault markdown: {md_relative} ({len(content)} chars)")

    # ------------------------------------------------------------------
    # Progress emission
    # ------------------------------------------------------------------

    async def _emit(self, event_type: str, stage_or_action: str,
                    message_or_data: str | dict) -> None:
        """Convenience wrapper that calls the injected callbacks if set."""
        if event_type == "progress" and self._emit_progress:
            await self._emit_progress(stage_or_action, str(message_or_data))
        elif event_type == "data_changed" and self._emit_data_changed:
            await self._emit_data_changed(
                stage_or_action,
                message_or_data if isinstance(message_or_data, dict) else {},
            )

    def get_queue_snapshot(self) -> list[dict]:
        """Return a snapshot of all current and recent jobs in the queue."""
        return [
            {
                "job_id": jid[:8],
                "name": state.get("name", ""),
                "status": state.get("status", "queued"),
                "stage": state.get("stage", ""),
                "mode": state.get("mode", "create"),
            }
            for jid, state in self._job_states.items()
        ]

    async def _emit_queue_snapshot_if_needed(self) -> None:
        """Push the full queue snapshot to clients if the callback is set."""
        if self._emit_queue_snapshot is not None:
            await self._emit_queue_snapshot(self.get_queue_snapshot())

    async def _cleanup_job_state(self, job_id: str, delay: float = 8.0) -> None:
        """Remove a job from the snapshot after *delay* seconds."""
        await asyncio.sleep(delay)
        if job_id in self._job_states:
            status = self._job_states[job_id].get("status", "")
            if status in ("done", "error"):
                self._job_states.pop(job_id, None)
                await self._emit_queue_snapshot_if_needed()
