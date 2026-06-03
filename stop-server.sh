#!/bin/bash
# Stop all Jarvis server components (actual-server, actual-mcp, Jarvis server)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_DIR="$SCRIPT_DIR/modules/actual-server"
SERVER_COMPOSE="$SERVER_DIR/docker-compose.yml"

echo "==> Stopping Jarvis server (port 8000)..."
if lsof -ti :8000 > /dev/null 2>&1; then
  kill -9 $(lsof -ti :8000) 2>/dev/null || true
  echo "    Stopped."
else
  echo "    Not running."
fi

echo "==> Stopping MCP server (port 3000)..."
if lsof -ti :3000 > /dev/null 2>&1; then
  kill -9 $(lsof -ti :3000) 2>/dev/null || true
  echo "    Stopped."
else
  echo "    Not running."
fi

echo "==> Stopping actual-server (port 5006)..."
if docker info > /dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "actual-server"; then
  cd "$SERVER_DIR"
  docker compose -f "$SERVER_COMPOSE" down 2>/dev/null || true
  echo "    Docker container stopped."
elif lsof -ti :5006 > /dev/null 2>&1; then
  kill -9 $(lsof -ti :5006) 2>/dev/null || true
  echo "    Native process stopped."
else
  echo "    Not running."
fi

echo "==> All server components stopped."
