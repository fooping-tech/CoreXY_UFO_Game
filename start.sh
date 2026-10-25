#!/usr/bin/env bash
# CoreXY UFO Game launcher (macOS)
#
#   ./start.sh                     ゲームのみ（Godot 内蔵 MockRobot）
#   ./start.sh mock [backend args] Python バックエンド --mock + ゲーム（WebSocket 経由）
#   ./start.sh real [PORT] [args]  実機バックエンド + ゲーム（PORT 省略時は config / 自動検出。--gesture でハンドジェスチャー ON）
#   ./start.sh gesture [args]      バックエンド --mock --gesture（カメラでピンチ操作）+ ゲーム（ジェスチャー ON）
#   ./start.sh backend [args]      バックエンドのみ（例: ./start.sh backend --list-ports）
#
# 環境変数 GODOT で Godot 実行ファイルを上書きできます。
# 環境変数 START_SH_NO_GAME=1 なら Godot を起動せず、起動コマンドを表示するだけ（確認用）。
#
# バックエンドの WebSocket のアドレスは config/game_config.json の network.websocket_url
# （--ws-host / --ws-port を渡したらそちら）。起動前にそのポートが使われていたら止める:
# 別のバックエンド（例: 起動したままの実機用）にゲームがつながるのを防ぐため。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
GAME_DIR="$ROOT/game"
BACKEND_DIR="$ROOT/backend"
CONFIG_FILE="$ROOT/config/game_config.json"
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

# Same rule as the backend (config.py::load_config, then --ws-host / --ws-port).
# Plain shell on purpose: uv-only installations may have no python3 on PATH.
resolve_ws_endpoint() {
  local url=""
  if [[ -f "$CONFIG_FILE" ]]; then
    url="$(tr -d '\n' < "$CONFIG_FILE" | sed -n 's/.*"websocket_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  fi
  [[ -n "$url" ]] || url="ws://127.0.0.1:8765"
  local hostport="${url#*://}"
  hostport="${hostport%%/*}"
  if [[ "$hostport" == *:* ]]; then
    WS_HOST="${hostport%:*}"
    WS_PORT="${hostport##*:}"
  else
    WS_HOST="$hostport"
    WS_PORT="8765"
  fi
  [[ -n "$WS_HOST" ]] || WS_HOST="127.0.0.1"
  local prev="" a
  for a in "$@"; do
    case "$prev" in --ws-host) WS_HOST="$a" ;; --ws-port) WS_PORT="$a" ;; esac
    case "$a" in --ws-host=*) WS_HOST="${a#*=}" ;; --ws-port=*) WS_PORT="${a#*=}" ;; esac
    prev="$a"
  done
}

port_listener() {  # pid of the process listening on WS_PORT (empty if none)
  lsof -nP -iTCP:"$WS_PORT" -sTCP:LISTEN -t 2>/dev/null | head -1
}

ensure_port_free() {
  if nc -z "$WS_HOST" "$WS_PORT" 2>/dev/null || [[ -n "$(port_listener)" ]]; then
    local pid; pid="$(port_listener)"
    echo "ポート $WS_HOST:$WS_PORT はすでに使われています。別のバックエンドが起動したままかもしれません。" >&2
    if [[ -n "$pid" ]]; then
      echo "  使用中のプロセス: $(ps -o pid=,command= -p "$pid" 2>/dev/null | cut -c1-160)" >&2
      echo "  そのプロセスを終了してから再実行してください（意図したものなら ./start.sh game でゲームだけ起動）。" >&2
    fi
    exit 1
  fi
}

# Is the listener our backend (BACKEND_PID or one of its descendants)?
listener_is_ours() {
  local pid; pid="$(port_listener)"
  [[ -z "$pid" ]] && return 0  # lsof unavailable: the pre-start check already ruled out others
  while [[ -n "$pid" && "$pid" != "1" && "$pid" != "0" ]]; do
    [[ "$pid" == "$BACKEND_PID" ]] && return 0
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
  done
  return 1
}

wait_for_port() {
  local i
  for i in $(seq 1 100); do
    if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
      echo "バックエンドが起動に失敗しました" >&2; exit 1
    fi
    if nc -z "$WS_HOST" "$WS_PORT" 2>/dev/null; then
      # The port being open is not enough: the process we started must still be alive
      # and be the one listening.
      sleep 0.3
      if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
        echo "バックエンドが起動直後に終了しました" >&2; exit 1
      fi
      if ! listener_is_ours; then
        echo "ポート $WS_HOST:$WS_PORT で待ち受けているのは起動したバックエンドではありません" >&2; exit 1
      fi
      return 0
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
  if [[ "${START_SH_NO_GAME:-}" == "1" ]]; then
    local backend=""
    [[ -n "${BACKEND_PID:-}" ]] && backend="（バックエンド ${WS_HOST:-?}:${WS_PORT:-?} は起動済み）"
    echo "[START_SH_NO_GAME] godot --path $GAME_DIR -- $*$backend"
    return 0
  fi
  "$(find_godot)" --path "$GAME_DIR" -- "$@"
}

start_backend() {
  require_uv
  resolve_ws_endpoint "$@"
  ensure_port_free
  # camera / hand tracking need the optional extras; a plain sync would remove them
  local extras=() a
  for a in "$@"; do
    case "$a" in --gesture|--gesture=*|--hands|--camera|--camera=*) extras=(--extra vision --extra hands) ;; esac
  done
  (cd "$BACKEND_DIR" && uv sync --quiet ${extras[@]+"${extras[@]}"})
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
    game_args=(--source websocket)
    for a in "$@"; do
      # --gesture: the game starts with the hand joystick on, the backend sends the
      # landmarks for the HUD / debug view
      if [[ "$a" == --gesture || "$a" == --gesture=* ]]; then game_args+=(--gesture); args+=(--gesture-landmarks); fi
    done
    start_backend ${args[@]+"${args[@]}"} "$@"
    run_game "${game_args[@]}"
    ;;
  gesture)
    # landmarks too: the debug panel draws the hand skeleton over the camera view
    start_backend --mock --gesture --gesture-landmarks "$@"
    run_game --source websocket --gesture
    ;;
  backend)
    require_uv
    cd "$BACKEND_DIR" && exec uv run corexy-ufo-backend "$@"
    ;;
  -h|--help|help)
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "不明なモード: $MODE（./start.sh --help を参照）" >&2
    exit 1
    ;;
esac
