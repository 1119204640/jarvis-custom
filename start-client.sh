#!/bin/bash
# Start Jarvis client (REPL, Chainlit, or Flutter)
# Usage:
#   ./start-client.sh           默认启动 Flutter web
#   ./start-client.sh -flutter  启动 Flutter web
#   ./start-client.sh -repl     启动终端 REPL
#   ./start-client.sh -chainlit 启动 Chainlit Web UI

set -e
trap 'exit 0' INT TERM

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLIENT="${1:--flutter}"

case "$CLIENT" in
  -repl)
    echo "==> Starting terminal REPL client..."
    cd "$SCRIPT_DIR"
    uv run python src/client/terminal_client.py
    ;;

  -chainlit)
    echo "==> Starting Chainlit web UI..."
    cd "$SCRIPT_DIR"
    uv run chainlit run src/client/chainlit_web.py
    ;;

  -flutter)
    echo "==> Starting Flutter web client..."
    cd "$SCRIPT_DIR/src/client/flutter_application_1"
    flutter run -d chrome
    ;;

  *)
    echo "Usage: $0 [-repl | -chainlit | -flutter]"
    echo ""
    echo "  (no flag)  默认启动 Flutter web"
    echo "  -flutter   启动 Flutter web"
    echo "  -repl      启动终端 REPL"
    echo "  -chainlit  启动 Chainlit Web UI"
    exit 1
    ;;
esac
