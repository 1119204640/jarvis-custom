#!/usr/bin/env python3
"""Smoke-test the Jarvis server REST API.

Starts the server as a background subprocess, polls for health, runs
CRUD tests against memos and reminders, then stops the server cleanly.
Exit code 0 means all tests passed.
"""

from __future__ import annotations

import json
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zlib
from pathlib import Path

BASE = "http://localhost:8000"
ROOT = Path(__file__).resolve().parents[3]


def _req(method: str, path: str, body: dict | None = None) -> tuple[int, dict]:
    url = f"{BASE}{path}"
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read())
    except Exception as exc:
        return -1, {"error": str(exc)}


def _ok(message: str) -> None:
    print(f"  [OK] {message}")


def _fail(message: str, detail: str = "") -> None:
    print(f"  [FAIL] {message} {detail}")
    sys.exit(1)


def _png_chunk(chunk_type: bytes, data: bytes) -> bytes:
    chunk = chunk_type + data
    return (
        struct.pack(">I", len(data))
        + chunk
        + struct.pack(">I", zlib.crc32(chunk) & 0xFFFFFFFF)
    )


def main() -> None:
    print("=== Jarvis smoke test ===\n")

    print("[1] Starting server...")
    proc = subprocess.Popen(
        ["uv", "run", "python", "-m", "src.server.server"],
        cwd=str(ROOT),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

    ready = False
    deadline = time.time() + 30
    while time.time() < deadline:
        code, body = _req("GET", "/health")
        if code == 200 and body.get("status") == "ok":
            ready = True
            break
        time.sleep(0.3)

    if not ready:
        _fail("server did not become healthy within 30s")

    _ok("server healthy")

    print("\n[2] Asset CRUD...")

    code, body = _req(
        "POST",
        "/api/assets",
        {
            "title": "Smoke Test",
            "content": "Hello from run_jarvis_smoke.py",
            "tags": ["smoke", "test"],
        },
    )
    if code != 200 or "data" not in body or "id" not in body["data"]:
        _fail("create asset", str(body))
    asset_id = body["data"]["id"]
    _ok(f"create (id={asset_id[:8]}...)")

    code, body = _req("GET", f"/api/assets/{asset_id}")
    if code != 200 or body["data"]["title"] != "Smoke Test":
        _fail("get asset", str(body))
    _ok("get")

    code, body = _req(
        "PUT",
        f"/api/assets/{asset_id}",
        {
            "title": "Smoke Test UPDATED",
            "content": "Updated body",
        },
    )
    if code != 200 or body["data"]["title"] != "Smoke Test UPDATED":
        _fail("update asset", str(body))
    _ok("update")

    code, body = _req("GET", "/api/assets")
    if code != 200 or not isinstance(body.get("data"), list):
        _fail("list assets", str(body))
    _ok(f"list ({len(body['data'])} assets)")

    code, body = _req("GET", "/api/assets?q=smoke")
    if code != 200:
        _fail("search assets", str(body))
    _ok("search")

    code, body = _req("DELETE", f"/api/assets/{asset_id}")
    if code != 200 or body.get("status") != "deleted":
        _fail("delete asset", str(body))
    _ok("delete")

    print("\n[3] Todo CRUD...")

    code, body = _req(
        "POST",
        "/api/todos",
        {
            "title": "Smoke Todo",
            "due_date": "2026-12-31",
            "priority": "high",
        },
    )
    if code != 200 or "data" not in body:
        _fail("create todo", str(body))
    todo_id = body["data"]["id"]
    _ok(f"create (id={todo_id[:8]}...)")

    code, body = _req("GET", f"/api/todos/{todo_id}")
    if code != 200 or body["data"]["title"] != "Smoke Todo":
        _fail("get todo", str(body))
    _ok("get")

    code, body = _req(
        "PUT",
        f"/api/todos/{todo_id}",
        {
            "title": "Smoke Todo UPDATED",
            "priority": "low",
        },
    )
    if code != 200 or body["data"]["priority"] != "low":
        _fail("update todo", str(body))
    _ok("update")

    code, body = _req("GET", "/api/todos")
    if code != 200 or not isinstance(body.get("data"), list):
        _fail("list todos", str(body))
    _ok(f"list ({len(body['data'])} todos)")

    code, body = _req("PUT", f"/api/todos/{todo_id}/complete")
    if code != 200 or body["data"]["status"] != "completed":
        _fail("complete todo", str(body))
    _ok("complete")

    code, body = _req("DELETE", f"/api/todos/{todo_id}")
    if code != 200 or body.get("status") != "deleted":
        _fail("delete todo", str(body))
    _ok("delete")

    print("\n[4] Image upload...")

    png = (
        b"\x89PNG\r\n\x1a\n"
        + _png_chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
        + _png_chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00\x00\xff"))
        + _png_chunk(b"IEND", b"")
    )

    boundary = "----SmokeBoundary"
    body_bytes = (
        f"--{boundary}\r\n"
        "Content-Disposition: form-data; name=\"file\"; filename=\"smoke.png\"\r\n"
        "Content-Type: image/png\r\n\r\n"
    ).encode() + png + f"\r\n--{boundary}--\r\n".encode()

    req = urllib.request.Request(
        f"{BASE}/api/upload",
        data=body_bytes,
        method="POST",
    )
    req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            upload_body = json.loads(resp.read())
        if "data" in upload_body and "url" in upload_body["data"]:
            _ok(f"upload -> {upload_body['data']['url']}")
        else:
            _fail("upload", str(upload_body))
    except Exception as exc:
        _fail("upload", str(exc))

    print("\n[5] Stopping server...")
    try:
        _req("POST", "/stop")
    except Exception:
        pass

    deadline = time.time() + 10
    while time.time() < deadline:
        code, _ = _req("GET", "/health")
        if code == -1:
            break
        time.sleep(0.3)
    else:
        _fail("server still responded to /health after /stop")

    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)

    _ok("server stopped cleanly")


if __name__ == "__main__":
    main()
