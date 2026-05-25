#!/bin/bash
# Start Jarvis standalone server (FastAPI + Socket.IO)
# Usage: ./start-server.sh

set -e
trap 'exit 0' INT TERM

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
# 2. Start actual-server (Docker if available, otherwise native Node.js)
# ---------------------------------------------------------------------------
echo "==> Checking actual-server..."

# Check if Docker daemon is running
if docker info > /dev/null 2>&1; then
  echo "    Docker detected, using containerized actual-server."

  cd "$SERVER_DIR"

  # Ensure custom-sw.js is in place for Docker volume mount
  if [ ! -f "$SERVER_DIR/custom-sw.js" ]; then
    cp "$SCRIPT_DIR/custom-sw.js" "$SERVER_DIR/custom-sw.js"
  fi
  # Add volume mount for custom-sw.js to docker-compose.yml if not already present
  if ! grep -q "custom-sw.js" "$SERVER_COMPOSE"; then
    sed -i '' '/volumes:/a\
      - ./custom-sw.js:/app/node_modules/@actual-app/web/build/sw.js
' "$SERVER_COMPOSE"
  fi

  if docker ps --format '{{.Names}}' | grep -q "actual-server"; then
    echo "    actual-server is already running."
  else
    echo "    Starting actual-server (Docker, port 5006)..."
    docker compose -f "$SERVER_COMPOSE" up -d
    echo "    Waiting for server to be healthy..."
    until curl -s -o /dev/null http://localhost:5006/health; do sleep 1; done
    echo "    Server is ready."
  fi
else
  echo "    Docker not available, using native actual-server."

  cd "$SERVER_DIR"

  # Install dependencies if needed (vendored Yarn Berry)
  if [ ! -d "node_modules" ]; then
    echo "    Installing dependencies (yarn)..."
    node .yarn/releases/yarn-4.3.1.cjs install
  fi

  # Replace Workbox Service Worker with self-destructing one
  if [ -f "$SCRIPT_DIR/custom-sw.js" ]; then
    cp "$SCRIPT_DIR/custom-sw.js" "$SERVER_DIR/node_modules/@actual-app/web/build/sw.js"
  fi

  if lsof -ti :5006 > /dev/null 2>&1; then
    echo "    actual-server is already running on port 5006."
  else
    echo "    Starting actual-server (native, port 5006)..."
    ACTUAL_DATA_DIR="$SERVER_DIR/actual-data" \
    fnm exec --using=22 node app.js &
    echo "    Waiting for server to be healthy..."
    until curl -s -o /dev/null http://localhost:5006/health; do sleep 1; done
    echo "    Server is ready."
  fi
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
echo "    Stop server:   type /stop in this terminal (or Ctrl+C)"
echo "    Terminal REPL: ./start-client.sh -repl"
echo "    Chainlit web:  ./start-client.sh -chainlit"
echo "    Flutter web:   ./start-client.sh -flutter"
uv run python -m src.server.server
