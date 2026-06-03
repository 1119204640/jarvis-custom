#!/bin/bash
# Stop all Jarvis client processes (Flutter macOS, Flutter web, Chainlit, REPL)
set -e

STOPPED=0

echo "==> Stopping Flutter macOS client..."
FLUTTER_MACOS_PIDS=$(pgrep -f "flutter_application_1" 2>/dev/null || true)
if [ -n "$FLUTTER_MACOS_PIDS" ]; then
  kill -9 $FLUTTER_MACOS_PIDS 2>/dev/null || true
  echo "    Stopped."
  STOPPED=1
else
  echo "    Not running."
fi

echo "==> Stopping Flutter web client (Chrome)..."
FLUTTER_WEB_PIDS=$(pgrep -f "flutter.*run.*chrome" 2>/dev/null || true)
if [ -n "$FLUTTER_WEB_PIDS" ]; then
  kill -9 $FLUTTER_WEB_PIDS 2>/dev/null || true
  echo "    Stopped."
  STOPPED=1
else
  echo "    Not running."
fi

echo "==> Stopping Chainlit web UI..."
CHAINLIT_PIDS=$(pgrep -f "chainlit run" 2>/dev/null || true)
if [ -n "$CHAINLIT_PIDS" ]; then
  kill -9 $CHAINLIT_PIDS 2>/dev/null || true
  echo "    Stopped."
  STOPPED=1
else
  echo "    Not running."
fi

echo "==> Stopping terminal REPL..."
REPL_PIDS=$(pgrep -f "terminal_client" 2>/dev/null || true)
if [ -n "$REPL_PIDS" ]; then
  kill -9 $REPL_PIDS 2>/dev/null || true
  echo "    Stopped."
  STOPPED=1
else
  echo "    Not running."
fi

if [ "$STOPPED" -eq 0 ]; then
  echo "==> No client processes were running."
else
  echo "==> All client processes stopped."
fi
