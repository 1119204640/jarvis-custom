#!/bin/bash
# Start Jarvis standalone server (FastAPI + Socket.IO)
# Usage: ./start-server.sh

set -e
trap 'exit 0' INT TERM

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

require_command() {
  local cmd="$1"
  local hint="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "缺少命令: $cmd"
    echo "$hint"
    exit 1
  fi
}

ensure_python_workspace() {
  require_command "git" "请先安装 Git。"
  require_command "uv" "请先安装 uv: https://docs.astral.sh/uv/getting-started/installation/"

  if [ ! -f "$SCRIPT_DIR/modules/chainlit/backend/pyproject.toml" ] || [ ! -f "$SCRIPT_DIR/modules/loguru/pyproject.toml" ]; then
    echo "==> Initializing git submodules for Python workspace..."
    git -C "$SCRIPT_DIR" submodule update --init --recursive
  fi
}

cd "$SCRIPT_DIR"
ensure_python_workspace
echo "==> Starting Jarvis server on http://localhost:8000..."
echo "    Stop server:   type /stop in this terminal (or Ctrl+C)"
echo "    Terminal REPL:   ./start-client.sh -repl"
echo "    Chainlit web:    ./start-client.sh -chainlit"
echo "    Flutter web:     ./start-client.sh -flutter"
echo "    Flutter macOS:   ./start-client.sh -macos"
uv run python -m src.server.server
