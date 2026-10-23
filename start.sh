#!/usr/bin/env bash
# CoreXY UFO Game launcher (macOS)
#
#   ./start.sh                     ゲームのみ（Godot 内蔵 MockRobot）
#   ./start.sh mock [backend args] Python バックエンド --mock + ゲーム（WebSocket 経由）
#   ./start.sh real [PORT] [args]  実機バックエンド + ゲーム（PORT 省略時は config / 自動検出）
#   ./start.sh backend [args]      バックエンドのみ（例: ./start.sh backend --list-ports）
#
# 環境変数 GODOT で Godot 実行ファイルを上書きできます。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
GAME_DIR="$ROOT/game"
BACKEND_DIR="$ROOT/backend"
WS_HOST="127.0.0.1"
WS_PORT="8765"
# 他プロジェクトの venv が有効でも backend/.venv を使わせる
unset VIRTUAL_ENV

find_godot() {
  if [[ -n "${GODOT:-}" ]]; then echo "$GODOT"; return; fi
  if [[ -x /Applications/Godot.app/Contents/MacOS/Godot ]]; then
    echo /Applications/Godot.app/Contents/MacOS/Godot; return
  fi
  if command -v godot >/dev/null 2>&1; then command -v godot; return; fi
  echo "Godot が見つかりません: brew install --cask godot" >&2
  exit 1
}

require_uv() {
  command -v uv >/dev/null 2>&1 || { echo "uv が見つかりません: brew install uv" >&2; exit 1; }
}

wait_for_port() {
  local i
  for i in $(seq 1 100); do
    if nc -z "$WS_HOST" "$WS_PORT" 2>/dev/null; then return 0; fi
    if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
      echo "バックエンドが起動に失敗しました" >&2; exit 1
    fi
    sleep 0.1
  done
  echo "バックエンドの WebSocket ($WS_HOST:$WS_PORT) が開きませんでした" >&2
  exit 1
}

BACKEND_PID=""
cleanup() {
  if [[ -n "$BACKEND_PID" ]] && kill -0 "$BACKEND_PID" 2>/dev/null; then
    kill "$BACKEND_PID" 2>/dev/null || true
    wait "$BACKEND_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

run_game() {
  "$(find_godot)" --path "$GAME_DIR" -- "$@"
}

start_backend() {
  require_uv
  (cd "$BACKEND_DIR" && uv sync --quiet)
  (cd "$BACKEND_DIR" && exec uv run corexy-ufo-backend "$@") &
  BACKEND_PID=$!
  wait_for_port
}

MODE="${1:-game}"
[[ $# -gt 0 ]] && shift

case "$MODE" in
  game)
    run_game "$@"
    ;;
  mock)
    start_backend --mock "$@"
    run_game --source websocket
    ;;
  real)
    args=()
    if [[ $# -gt 0 && "$1" != -* ]]; then args=(--port "$1"); shift; fi
    start_backend ${args[@]+"${args[@]}"} "$@"
    run_game --source websocket
    ;;
  backend)
    require_uv
    cd "$BACKEND_DIR" && exec uv run corexy-ufo-backend "$@"
    ;;
  -h|--help|help)
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "不明なモード: $MODE（./start.sh --help を参照）" >&2
    exit 1
    ;;
esac
