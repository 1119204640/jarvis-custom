#!/bin/bash
# Start Jarvis Chainlit Web UI
# Usage: ./start-chainlit.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHES_DIR="$SCRIPT_DIR/patches"
MCP_DIR="$SCRIPT_DIR/modules/actual-mcp"

# ---------------------------------------------------------------------------
# 1. Check MCP server is running
# ---------------------------------------------------------------------------
echo "==> Checking MCP server..."
if pgrep -f "node build/index.js.*--sse.*--port 3000" > /dev/null; then
  echo "    MCP server is running on port 3000."
else
  echo "    WARNING: MCP server is not running."
  echo "    Start it first with: ./start-budget-server-and-mcp.sh"
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Apply patches (ensure submodule changes are intact)
# ---------------------------------------------------------------------------
echo "==> Applying patches to actual-mcp..."
cd "$MCP_DIR"
if git apply --check "$PATCHES_DIR/actual-mcp.patch" 2>/dev/null; then
  git apply "$PATCHES_DIR/actual-mcp.patch"
  echo "    Patch applied."
else
  echo "    Patch already applied or not needed."
fi

# ---------------------------------------------------------------------------
# 3. Start Chainlit
# ---------------------------------------------------------------------------
cd "$SCRIPT_DIR"
echo "==> Starting Chainlit web UI..."
echo "    Open http://localhost:8000 in your browser."
uv run chainlit run src/client/chainlit_web.py
