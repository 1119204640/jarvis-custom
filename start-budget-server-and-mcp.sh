#!/bin/bash
# Start Actual Budget MCP Server
# Usage: ./start-mcp.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MCP_DIR="$SCRIPT_DIR/modules/actual-mcp"
SERVER_DIR="$SCRIPT_DIR/modules/actual-server"
SERVER_COMPOSE="$SERVER_DIR/docker-compose.yml"
PATCHES_DIR="$SCRIPT_DIR/patches"

# ---------------------------------------------------------------------------
# 1. Apply patches to submodules（确保云部署时改动完整）
# ---------------------------------------------------------------------------
echo "==> Applying patches to actual-mcp..."
cd "$MCP_DIR"
if git apply --check "$PATCHES_DIR/actual-mcp.patch" 2>/dev/null; then
  git apply "$PATCHES_DIR/actual-mcp.patch"
  echo "    Patch applied."
else
  echo "    Patch already applied or not needed."
fi

echo "==> Applying patches to actual-server..."
cd "$SERVER_DIR"
if git apply --check "$PATCHES_DIR/actual-server.patch" 2>/dev/null; then
  git apply "$PATCHES_DIR/actual-server.patch"
  echo "    Patch applied."
else
  echo "    Patch already applied or not needed."
fi

# ---------------------------------------------------------------------------
# 2. Start actual-server
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 3. Build actual-mcp
# ---------------------------------------------------------------------------
echo "==> Building actual-mcp..."
cd "$MCP_DIR"
if [ ! -d "node_modules" ]; then
  npm install
fi
npm run build --silent 2>/dev/null

# ---------------------------------------------------------------------------
# 4. Start MCP server
# ---------------------------------------------------------------------------
if pgrep -f "node build/index.js.*--sse.*--port 3000" > /dev/null; then
  echo "    MCP server is already running on port 3000."
else
  echo "==> Starting MCP server on port 3000..."
  ACTUAL_SERVER_URL=http://localhost:5006 \
  ACTUAL_PASSWORD=leon0930 \
  NODE_OPTIONS="--require $SCRIPT_DIR/polyfill.cjs" \
  fnm exec --using=22 node build/index.js --sse --port 3000 --enable-write
fi
