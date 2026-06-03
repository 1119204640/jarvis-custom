#!/bin/bash
# Start Jarvis client (REPL, Chainlit, Flutter web, or Flutter macOS)
# Usage:
#   ./start-client.sh             默认启动 Flutter web
#   ./start-client.sh -flutter    启动 Flutter web (Chrome)
#   ./start-client.sh -macos      启动 Flutter macOS 桌面应用
#   ./start-client.sh -repl       启动终端 REPL
#   ./start-client.sh -chainlit   启动 Chainlit Web UI

set -e
trap 'exit 0' INT TERM

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:--flutter}"

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

# 确保 Homebrew Ruby 和 CocoaPods 在 PATH 中（macOS 构建需要）
ensure_cocoapods_path() {
  if ! command -v pod &>/dev/null; then
    local ruby_bin="/opt/homebrew/opt/ruby/bin"
    local gem_bin="/opt/homebrew/lib/ruby/gems/3.4.0/bin"
    if [ -d "$ruby_bin" ]; then
      export PATH="$ruby_bin:$gem_bin:$PATH"
    fi
  fi
}

case "$MODE" in
  -repl)
    ensure_python_workspace
    echo "==> Starting terminal REPL client..."
    cd "$SCRIPT_DIR"
    uv run python src/client/terminal_client.py
    ;;

  -chainlit)
    ensure_python_workspace
    echo "==> Starting Chainlit web UI..."
    cd "$SCRIPT_DIR"
    uv run chainlit run src/client/chainlit_web.py
    ;;

  -flutter)
    require_command "flutter" "请先安装 Flutter SDK，并确保 flutter 在 PATH 中。"
    echo "==> Starting Flutter web client (Chrome)..."
    cd "$SCRIPT_DIR/src/client/flutter_application_1"
    flutter run -d chrome
    ;;

  -macos)
    require_command "flutter" "请先安装 Flutter SDK，并确保 flutter 在 PATH 中。"
    echo "==> Starting Flutter macOS desktop client..."
    ensure_cocoapods_path
    if ! command -v pod &>/dev/null; then
      echo "缺少命令: pod"
      echo "请先安装 CocoaPods，或确保 Homebrew Ruby / gem bin 已加入 PATH。"
      exit 1
    fi
    cd "$SCRIPT_DIR/src/client/flutter_application_1"
    flutter run -d macos
    ;;

  *)
    echo "Usage: $0 [MODE]"
    echo ""
    echo "  (no flag)  默认启动 Flutter web"
    echo "  -flutter   启动 Flutter web (Chrome)"
    echo "  -macos     启动 Flutter macOS 桌面应用"
    echo "  -repl      启动终端 REPL"
    echo "  -chainlit  启动 Chainlit Web UI"
    exit 1
    ;;
esac
