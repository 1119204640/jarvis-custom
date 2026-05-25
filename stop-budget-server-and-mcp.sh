#!/bin/bash
# Stop Actual Budget MCP Server
# Usage: ./stop-budget-server-and-mcp.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_DIR="$SCRIPT_DIR/modules/actual-server"
SERVER_COMPOSE="$SERVER_DIR/docker-compose.yml"

# ---------------------------------------------------------------------------
# 1. Stop MCP server
# ---------------------------------------------------------------------------
echo "==> Stopping MCP server..."
MCP_PID=$(pgrep -f "node build/index.js.*--sse.*--port 3000" 2>/dev/null || true)
if [ -n "$MCP_PID" ]; then
  kill "$MCP_PID" 2>/dev/null || true
  echo "    MCP server stopped (PID $MCP_PID)."
else
  echo "    MCP server is not running."
fi

# ---------------------------------------------------------------------------
# 2. Stop actual-server
# ---------------------------------------------------------------------------
echo "==> Stopping actual-server..."
if docker ps --format '{{.Names}}' | grep -q "actual-server"; then
  docker compose -f "$SERVER_COMPOSE" down
  echo "    actual-server stopped."
else
  echo "    actual-server is not running."
fi

echo "==> All services stopped."
