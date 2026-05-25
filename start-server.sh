#!/bin/bash
# Start Jarvis standalone server (FastAPI + Socket.IO)
# Usage: ./start-server.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHES_DIR="$SCRIPT_DIR/patches"
MCP_DIR="$SCRIPT_DIR/modules/actual-mcp"
SERVER_DIR="$SCRIPT_DIR/modules/actual-server"
SERVER_COMPOSE="$SERVER_DIR/docker-compose.yml"

# ---------------------------------------------------------------------------
# 1. Apply patches
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
# 2. Start actual-server (Docker)
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
# 3. Build and start actual-mcp
# ---------------------------------------------------------------------------
echo "==> Building actual-mcp..."
cd "$MCP_DIR"
if [ ! -d "node_modules" ]; then
  npm install
fi
npm run build --silent 2>/dev/null

if pgrep -f "node build/index.js.*--sse.*--port 3000" > /dev/null; then
  echo "    MCP server is already running on port 3000."
else
  echo "==> Starting MCP server on port 3000..."
  ACTUAL_SERVER_URL=http://localhost:5006 \
  ACTUAL_PASSWORD=leon0930 \
  NODE_OPTIONS="--require $SCRIPT_DIR/polyfill.cjs" \
  fnm exec --using=22 node build/index.js --sse --port 3000 --enable-write &
fi

# ---------------------------------------------------------------------------
# 4. Start Jarvis server
# ---------------------------------------------------------------------------
cd "$SCRIPT_DIR"
echo "==> Starting Jarvis server on http://localhost:8000..."
echo "    Terminal REPL:  uv run python src/client/terminal_client.py"
echo "    Flutter web:    cd src/client/flutter_application_1 && flutter run -d chrome"
cd "$SCRIPT_DIR/src"
uv run uvicorn server.server:app --host 0.0.0.0 --port 8000
