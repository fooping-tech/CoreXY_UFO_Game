#!/usr/bin/env bash
# CoreXY UFO Game launcher (macOS)。使い方は ./start.sh --help（下の usage と同じ）。
#
#   ./start.sh                    実機 + ハンドジェスチャー + ゲーム（いつもの起動）
#   ./start.sh --mock             仮想クレーン（バックエンド --mock）+ ジェスチャー + ゲーム
#   ./start.sh --no-gesture       ジェスチャーなし（--mock とも組み合わせられる）
#   ./start.sh --game-only        ゲームだけ（ゲーム内の MockRobot。バックエンドなし）
#   ./start.sh --backend-only     バックエンドだけ（--mock と組み合わせられる）
#   ./start.sh --mock --no-gesture --study-mode   UFOくん 勉強モードで開始（F5 で終了/再開）
#   ./start.sh ... -- <引数>      -- の後ろはバックエンドへ（--game-only ではゲームへ）そのまま渡す
#
# 今までの書き方（game / mock / real [PORT] / gesture / study / backend）もそのまま使える。
#
# 引数なしで起動したときの引数は、環境変数かリポジトリ直下の .env の CXUFO_START_ARGS で決められる
# （例: CXUFO_START_ARGS=--mock --no-gesture）。今までの CXUFO_START_MODE（モード名）も使える。
# 環境変数が .env より優先。引数を 1 つでも渡したら引数が優先で、CXUFO_START_* は使わない。
#
# 環境変数 GODOT で Godot 実行ファイルを上書きできます。
# 環境変数 START_SH_WAIT_S でバックエンドの起動を待つ秒数を変えられます（既定 60。--gesture は約 12 秒かかる）。
# 環境変数 START_SH_NO_GAME=1 なら Godot を起動せず、起動コマンドを表示するだけ（確認用）。
# 環境変数 START_SH_DRY_RUN=1 ならバックエンドもゲームも起動せず、起動コマンドを表示するだけ（確認用）。
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

# How long to wait for the backend's WebSocket. With --gesture, MediaPipe takes
# ~11 s to load (GPU delegate) before the port opens.
WAIT_S="${START_SH_WAIT_S:-60}"

wait_for_port() {
  local i
  for i in $(seq 1 $((WAIT_S * 10))); do
    if (( i % 50 == 0 )); then echo "バックエンドの起動を待っています（$((i / 10)) 秒）..." >&2; fi
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
  echo "バックエンドの WebSocket ($WS_HOST:$WS_PORT) が ${WAIT_S} 秒以内に開きませんでした（START_SH_WAIT_S で延ばせます）" >&2
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

DRY_RUN="${START_SH_DRY_RUN:-}"

run_game() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[START_SH_DRY_RUN] game: godot --path $GAME_DIR -- $*"
    return 0
  fi
  if [[ "${START_SH_NO_GAME:-}" == "1" ]]; then
    local backend=""
    [[ -n "${BACKEND_PID:-}" ]] && backend="（バックエンド ${WS_HOST:-?}:${WS_PORT:-?} は起動済み）"
    echo "[START_SH_NO_GAME] godot --path $GAME_DIR -- $*$backend"
    return 0
  fi
  "$(find_godot)" --path "$GAME_DIR" -- "$@"
}

start_backend() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[START_SH_DRY_RUN] backend: corexy-ufo-backend $*"
    return 0
  fi
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

run_backend_only() {  # in the foreground (no game)
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[START_SH_DRY_RUN] backend: corexy-ufo-backend $*"
    return 0
  fi
  require_uv
  cd "$BACKEND_DIR" && exec uv run corexy-ufo-backend "$@"
}


# One KEY=VALUE from .env, without running it as shell code (the file also holds
# tokens, which stay out of this shell). Sets DOTENV_VALUE; the last line wins.
ENV_FILE="${START_SH_ENV_FILE:-$ROOT/.env}"
read_dotenv() {
  DOTENV_VALUE=""
  [[ -f "$ENV_FILE" ]] || return 0
  local line val
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    [[ "$line" == "export "* ]] && line="${line#export }"
    [[ "$line" == "$1="* ]] || continue
    val="${line#*=}"
    val="${val#"${val%%[![:space:]]*}"}"
    local q="${val:0:1}"
    if [[ ( "$q" == '"' || "$q" == "'" ) && "${val:1}" == *"$q"* ]]; then
      val="${val:1}"; val="${val%%"$q"*}"     # quoted: up to the closing quote
    else
      val="${val%%[[:space:]]#*}"             # unquoted: drop an inline " # comment"
      val="${val%"${val##*[![:space:]]}"}"
    fi
    DOTENV_VALUE="$val"
  done < "$ENV_FILE"
}

# The environment wins over .env (same rule as the homework watch's CF_* keys).
start_setting() {  # $1 = key; sets SETTING_VALUE and SETTING_FROM
  local env_val="${!1:-}"
  if [[ -n "$env_val" ]]; then SETTING_VALUE="$env_val"; SETTING_FROM="環境変数 $1"; return; fi
  read_dotenv "$1"
  SETTING_VALUE="$DOTENV_VALUE"; SETTING_FROM=".env の $1"
}

usage() {
  cat <<'EOF'
使い方: ./start.sh [オプション] [-- バックエンド（--game-only ではゲーム）への引数]

ロボット（省くと --real）
  --real            実機（USB シリアル）
  --mock            仮想クレーン（バックエンドの --mock）。実機には何も送らない

起動するもの（省くとバックエンド + ゲーム）
  --game-only       ゲームだけ（ゲーム内の MockRobot。バックエンドなし）
  --backend-only    バックエンドだけ（ゲームなし。例: -- --list-ports）

オプション
  --no-gesture      ハンドジェスチャーを使わない（--real / --mock では既定で ON）
  --gesture         ハンドジェスチャーを使う（--game-only / --backend-only でも ON にする）
  --gesture-camera CAM   ジェスチャーに使うカメラ（番号か名前の一部。省くと config の gesture.camera）
  --port PORT       実機のシリアルポート（省くと config か自動検出）
  --study           Study タブ（カメラ学習アシスタント。config の study.enabled も必要）
  --study-mode      UFOくん 勉強モードで開始する（ゲーム中はいつでも F5 で開始・終了）
  -h, --help        この説明

例
  ./start.sh                              実機 + ジェスチャー + ゲーム
  ./start.sh --port /dev/cu.usbserial-XXXX
  ./start.sh --mock                       実機なしで（仮想クレーン + ジェスチャー）
  ./start.sh --mock --no-gesture          実機もカメラもなしで
  ./start.sh --mock --no-gesture --study-mode   勉強モードのデモ（実機なし）
  ./start.sh --game-only -- --scenario sudden_stop
  ./start.sh --backend-only -- --list-ports

今までの書き方も使えます: game / mock / real [PORT] / gesture / study / backend [引数]
引数なしのときの既定は .env か環境変数の CXUFO_START_ARGS（例: CXUFO_START_ARGS=--mock）。
実機のモーターは、どの起動でも最初は無効（デバッグパネルの「実機」タブで有効にするまで動かない）。
EOF
}

die_usage() { echo "$1（./start.sh --help を参照）" >&2; exit 1; }

# The option form: sets TARGET (real / mock / game / backend), the backend's and the game's arguments.
parse_options() {
  local robot="" parts="" gesture="" camera="" port="" study=0 study_mode=0
  EXTRA=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --real|--mock)
        [[ -z "$robot" || "$robot" == "${1#--}" ]] || die_usage "--real と --mock は一緒に使えない"
        robot="${1#--}" ;;
      --game-only|--backend-only)
        [[ -z "$parts" || "$parts" == "$1" ]] || die_usage "--game-only と --backend-only は一緒に使えない"
        parts="$1" ;;
      --gesture) gesture=1 ;;
      --no-gesture) gesture=0 ;;
      --gesture-camera) [[ $# -ge 2 ]] || die_usage "--gesture-camera にはカメラが要ります"
                        camera="$2"; gesture=1; shift ;;
      --gesture-camera=*) camera="${1#*=}"; gesture=1 ;;
      --port) [[ $# -ge 2 ]] || die_usage "--port にはシリアルポートが要ります"
              port="$2"; shift ;;
      --port=*) port="${1#*=}" ;;
      --study) study=1 ;;
      --study-mode) study_mode=1 ;;
      -h|--help) usage; exit 0 ;;
      --) shift; EXTRA=("$@"); break ;;
      *) die_usage "不明なオプション: $1（バックエンド・ゲームへの引数は -- の後ろに書く）" ;;
    esac
    shift
  done
  case "$parts" in
    --game-only)
      [[ -z "$robot" ]] || die_usage "--game-only はゲーム内の MockRobot を使う（--real / --mock は要らない）"
      [[ -z "$port" ]] || die_usage "--port はバックエンドを起動するときだけ（--game-only では使えない）"
      [[ "$study" == 0 ]] || die_usage "--study はバックエンドを起動するときだけ（--game-only では使えない）"
      TARGET=game ;;
    --backend-only) TARGET=backend ;;
    *) TARGET="${robot:-real}" ;;
  esac
  [[ -z "$port" || "$robot" != mock ]] || die_usage "--port は実機のときだけ（--mock では使えない）"
  # gestures: on by default when the backend and the game both start
  if [[ -z "$gesture" ]]; then
    case "$TARGET" in real|mock) gesture=1 ;; *) gesture=0 ;; esac
  fi
  GESTURE="$gesture"; PORT="$port"; BACKEND_MOCK=0
  [[ "$robot" == mock ]] && BACKEND_MOCK=1

  BACKEND_ARGS=()
  [[ "$BACKEND_MOCK" == 1 ]] && BACKEND_ARGS+=(--mock)
  [[ -n "$port" ]] && BACKEND_ARGS+=(--port "$port")
  if [[ "$gesture" == 1 && "$TARGET" != game ]]; then
    if [[ -n "$camera" ]]; then BACKEND_ARGS+=(--gesture "$camera"); else BACKEND_ARGS+=(--gesture); fi
    # the landmarks too: the debug panel draws the hand skeleton over the camera view
    BACKEND_ARGS+=(--gesture-landmarks)
  fi
  [[ "$study" == 1 ]] && BACKEND_ARGS+=(--study)
  GAME_ARGS=()
  [[ "$TARGET" != game ]] && GAME_ARGS+=(--source websocket)
  [[ "$gesture" == 1 && "$TARGET" != backend ]] && GAME_ARGS+=(--gesture)
  if [[ "$study_mode" == 1 ]]; then
    [[ "$TARGET" != backend ]] || die_usage "--study-mode はゲームを起動するときだけ（--backend-only では使えない）"
    GAME_ARGS+=(--study-mode)
  fi
  return 0
}

describe() {  # one line: what starts (above all, whether it is the real robot)
  local what gesture=""
  case "$TARGET" in
    real) what="実機（ポート: ${PORT:-config / 自動検出}）+ ゲーム" ;;
    mock) what="仮想クレーン（実機には送らない）+ ゲーム" ;;
    game) what="ゲームだけ（ゲーム内の MockRobot）" ;;
    backend) if [[ "$BACKEND_MOCK" == 1 ]]; then what="バックエンドだけ（仮想クレーン）"
             else what="バックエンドだけ（実機用）"; fi ;;
  esac
  [[ "$GESTURE" == 1 ]] && gesture=" / ジェスチャー ON" || gesture=" / ジェスチャー OFF"
  echo "起動: ${what}${gesture}" >&2
  [[ "$TARGET" == real ]] && echo "  実機のモーターは無効で起動します（「実機」タブで有効にするまで動きません）" >&2
  return 0
}

run_options() {
  parse_options "$@"
  describe
  case "$TARGET" in
    real|mock)
      start_backend ${BACKEND_ARGS[@]+"${BACKEND_ARGS[@]}"} ${EXTRA[@]+"${EXTRA[@]}"}
      run_game ${GAME_ARGS[@]+"${GAME_ARGS[@]}"}
      ;;
    game)
      run_game ${GAME_ARGS[@]+"${GAME_ARGS[@]}"} ${EXTRA[@]+"${EXTRA[@]}"}
      ;;
    backend)
      run_backend_only ${BACKEND_ARGS[@]+"${BACKEND_ARGS[@]}"} ${EXTRA[@]+"${EXTRA[@]}"}
      ;;
  esac
}

# The earlier form: a mode name first (kept as it was, so .env files and notes still work).
run_mode() {
  local MODE="$1"; shift
  [[ "$MODE" == help ]] || echo "起動（今までの書き方）: ${MODE}${*:+ $*}" >&2
  case "$MODE" in
    game)
      run_game "$@"
      ;;
    mock)
      start_backend --mock "$@"
      run_game --source websocket
      ;;
    real)
      local args=() game_args=(--source websocket) a
      if [[ $# -gt 0 && "$1" != -* ]]; then args=(--port "$1"); shift; fi
      for a in "$@"; do
        # --gesture: the game starts with the hand joystick on, the backend sends the
        # landmarks for the HUD / debug view
        if [[ "$a" == --gesture || "$a" == --gesture=* ]]; then game_args+=(--gesture); args+=(--gesture-landmarks); fi
      done
      start_backend ${args[@]+"${args[@]}"} "$@"
      run_game "${game_args[@]}"
      ;;
    study)
      # the study mode (#86) on the mock robot: the demo mode comes from study_mode.demo.mode
      start_backend --mock "$@"
      run_game --source websocket --study-mode
      ;;
    gesture)
      start_backend --mock --gesture --gesture-landmarks "$@"
      run_game --source websocket --gesture
      ;;
    backend)
      run_backend_only "$@"
      ;;
    help)
      usage
      ;;
    *)
      echo "不明なモード: ${MODE}（./start.sh --help を参照）" >&2
      exit 1
      ;;
  esac
}

is_mode() { case "$1" in game|mock|real|gesture|study|backend|help) return 0 ;; *) return 1 ;; esac; }

if [[ $# -eq 0 ]]; then
  # No arguments: the configured default (CXUFO_START_MODE / CXUFO_START_ARGS), else the
  # real robot with gestures.
  start_setting CXUFO_START_MODE
  mode_value="$SETTING_VALUE"; mode_from="$SETTING_FROM"
  start_setting CXUFO_START_ARGS
  args_value="$SETTING_VALUE"; args_from="$SETTING_FROM"
  default_args=()
  # word splitting only: `read -a` does no glob or command expansion
  [[ -n "$args_value" ]] && read -r -a default_args <<< "$args_value"
  if [[ -n "$mode_value" ]]; then
    echo "既定のモードで起動します（${mode_from}）: ${mode_value}${default_args[@]+ ${default_args[*]}}" >&2
    set -- "$mode_value" ${default_args[@]+"${default_args[@]}"}
  elif [[ "${#default_args[@]}" -gt 0 ]]; then
    echo "既定の引数で起動します（${args_from}）: ${default_args[*]}" >&2
    set -- "${default_args[@]}"
  fi
fi

if [[ $# -gt 0 ]] && is_mode "$1"; then
  run_mode "$@"
elif [[ $# -gt 0 && "$1" != -* ]]; then
  echo "不明なモード: $1（./start.sh --help を参照）" >&2
  exit 1
else
  run_options "$@"
fi
