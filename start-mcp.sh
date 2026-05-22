#!/bin/bash
# Start Actual Budget MCP Server
# Usage: ./start-mcp.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MCP_DIR="$SCRIPT_DIR/modules/actual-mcp"
SERVER_COMPOSE="$SCRIPT_DIR/modules/actual-server/docker-compose.yml"

echo "==> Checking actual-server..."
if docker ps --format '{{.Names}}' | grep -q "actual-server"; then
  echo "    actual-server is already running."
else
  echo "    Starting actual-server..."
  docker compose -f "$SERVER_COMPOSE" up -d
  echo "    Waiting for server to be healthy..."
  until curl -s -o /dev/null http://localhost:5006/health; do sleep 1; done
  echo "    Server is ready."
fi

echo "==> Building actual-mcp..."
cd "$MCP_DIR"
npm run build --silent 2>/dev/null

if pgrep -f "node build/index.js.*--sse.*--port 3000" > /dev/null; then
  echo "    MCP server is already running on port 3000."
else
  echo "==> Starting MCP server on port 3000..."
  ACTUAL_SERVER_URL=http://localhost:5006 \
  ACTUAL_PASSWORD=leon0930 \
  NODE_OPTIONS="--require $MCP_DIR/polyfill.cjs" \
  fnm exec --using=22 node build/index.js --sse --port 3000 --enable-write
fi
