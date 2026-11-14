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
CONFIG_FILE="${START_SH_CONFIG:-$ROOT/config/game_config.json}"  # START_SH_CONFIG: tests only
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

# study.enabled: "true" / "false" / "" (not found). Plain shell, like above; "enabled" is
# the study section's first key (the settings screen writes local_settings.json with sorted
# keys). config/local_settings.json (the settings screen, #93) wins over game_config.json.
json_study_enabled() {
  [[ -f "$1" ]] || return 0
  tr -d '\n' < "$1" \
    | sed -E -n 's/.*"study"[[:space:]]*:[[:space:]]*\{[[:space:]]*"enabled"[[:space:]]*:[[:space:]]*(true|false).*/\1/p'
}
config_study_enabled() {
  local v
  v="$(json_study_enabled "$(dirname "$CONFIG_FILE")/local_settings.json")"
  [[ -n "$v" ]] || v="$(json_study_enabled "$CONFIG_FILE")"
  echo "$v"
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

# ---- VOICEVOX ENGINE in Docker (#112) --------------------------------------------
# The voice (homework.speech) runs as its own container, started here and stopped when
# start.sh ends. Prepared in the background (the first pull and the model load take a
# while); meanwhile the backend speaks with `say` (it tries VOICEVOX first every time).
VV_STATE=""  # markers of what this start.sh started: container / colima
VV_JOB=""

# "on image container port" from homework.speech (+ config/local_settings.json, #93)
voicevox_config() {
  python3 -I - "$CONFIG_FILE" "$(dirname "$CONFIG_FILE")/local_settings.json" <<'PY'
import json, sys, urllib.parse
def load(p):
    try:
        with open(p, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}
g, l = load(sys.argv[1]), load(sys.argv[2])
sp = (g.get("homework") or {}).get("speech") or {}
lsp = (l.get("homework") or {}).get("speech") or {}
d = dict(sp.get("docker") or {})
d.update(lsp.get("docker") or {})
enabled = lsp.get("enabled", sp.get("enabled", False))
u = urllib.parse.urlparse(str(sp.get("voicevox_url", "http://127.0.0.1:50021")))
on = (enabled is True and "voicevox" in (sp.get("engines") or []) and d.get("enabled") is True
      and u.hostname in ("127.0.0.1", "localhost") and bool(d.get("image")))
print(1 if on else 0, d.get("image") or "-", d.get("container") or "cxufo-voicevox", u.port or 50021)
PY
}

voicevox_up() {  # image container port (in the background; markers in $VV_STATE)
  local image="$1" name="$2" port="$3"
  if ! docker info >/dev/null 2>&1; then
    if command -v colima >/dev/null 2>&1; then
      echo "VOICEVOX: Docker が止まっているので colima を起動します（終わるときに止める）…" >&2
      touch "$VV_STATE/colima"  # from here on: stopped at the end even if start.sh ends half-way
      if ! colima start >"$VV_STATE/colima.log" 2>&1; then
        echo "VOICEVOX: colima を起動できません（$VV_STATE/colima.log）。声は say で話します" >&2
        return 0
      fi
    else
      echo "VOICEVOX: Docker が動いていません（Docker Desktop か colima を起動する）。声は say で話します" >&2
      return 0
    fi
  fi
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
    echo "VOICEVOX: 動いているコンテナ $name を使います（start.sh が起動したものではないので、終わっても止めない）" >&2
    return 0
  fi
  docker rm -f "$name" >/dev/null 2>&1 || true  # a stopped leftover of an earlier run
  docker image inspect "$image" >/dev/null 2>&1 \
    || echo "VOICEVOX: イメージを取得します（初回だけ、数分かかる）: $image" >&2
  touch "$VV_STATE/starting"
  if docker run -d --rm --name "$name" -p "127.0.0.1:$port:50021" "$image" >"$VV_STATE/run.log" 2>&1; then
    touch "$VV_STATE/container"
    echo "VOICEVOX: コンテナ $name を起動しました（http://127.0.0.1:${port}。声の準備に少しかかる）" >&2
  else
    echo "VOICEVOX: コンテナを起動できません（$VV_STATE/run.log）。声は say で話します" >&2
  fi
}

start_voicevox() {
  local cfg on image name port
  cfg="$(voicevox_config 2>/dev/null)" || return 0
  read -r on image name port <<< "$cfg"
  [[ "$on" == 1 ]] || return 0
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[START_SH_DRY_RUN] voicevox: docker run -d --rm --name $name -p 127.0.0.1:$port:50021 $image"
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    echo "VOICEVOX: docker コマンドがありません。声は say で話します（homework.speech.docker.enabled を false にすると、この案内は出ない）" >&2
    return 0
  fi
  VV_STATE="$(mktemp -d "${TMPDIR:-/tmp}/cxufo-voicevox.XXXXXX")"
  echo "$name" > "$VV_STATE/name"
  voicevox_up "$image" "$name" "$port" &
  VV_JOB=$!
}

stop_voicevox() {
  [[ -n "$VV_STATE" && -d "$VV_STATE" ]] || return 0
  if [[ -n "$VV_JOB" ]] && kill -0 "$VV_JOB" 2>/dev/null; then
    # still preparing: its colima start / docker run too, or they go on after start.sh ends
    pkill -TERM -P "$VV_JOB" 2>/dev/null || true
    kill "$VV_JOB" 2>/dev/null || true
    wait "$VV_JOB" 2>/dev/null || true
  fi
  if [[ -e "$VV_STATE/starting" || -e "$VV_STATE/container" ]]; then
    echo "VOICEVOX: コンテナ $(cat "$VV_STATE/name") を止めます" >&2
    docker rm -f "$(cat "$VV_STATE/name")" >/dev/null 2>&1 || true
  fi
  if [[ -e "$VV_STATE/colima" ]]; then
    echo "VOICEVOX: start.sh が起動した colima を止めます…" >&2
    colima stop >/dev/null 2>&1 || true
  fi
  rm -rf "$VV_STATE"
  VV_STATE=""
}

BACKEND_PID=""
cleanup() {
  if [[ -n "$BACKEND_PID" ]] && kill -0 "$BACKEND_PID" 2>/dev/null; then
    kill "$BACKEND_PID" 2>/dev/null || true
    wait "$BACKEND_PID" 2>/dev/null || true
  fi
  stop_voicevox
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
  start_voicevox  # the voice in its own container (#112), stopped when start.sh ends
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
  # the voice for a game started on its own (review on #113), not for a one-shot listing
  local a oneshot=0
  for a in "$@"; do
    case "$a" in --list-ports|--list-cameras|--auto-catch-dry-run|-h|--help) oneshot=1 ;; esac
  done
  [[ "$oneshot" == 1 ]] || start_voicevox
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[START_SH_DRY_RUN] backend: corexy-ufo-backend $*"
    return 0
  fi
  require_uv
  if [[ -z "$VV_STATE" ]]; then
    cd "$BACKEND_DIR" && exec uv run corexy-ufo-backend "$@"
  fi
  # not exec: start.sh stays to stop the VOICEVOX container when the backend ends
  local code=0
  (cd "$BACKEND_DIR" && exec uv run corexy-ufo-backend "$@") || code=$?
  exit "$code"
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
  if [[ "$study" == 1 ]]; then
    # the Study tab sends camera images to the assistant: it needs both switches, this
    # option and study.enabled in the config. Say so now, not as a backend log line.
    if [[ "$(config_study_enabled)" == false ]]; then
      echo "--study には study.enabled: true も要ります（タイトル画面の歯車の設定画面か config/game_config.json で。Study タブはカメラの画像を AI に送るので、2 か所で有効にする）" >&2
      exit 1
    fi
    BACKEND_ARGS+=(--study)
  fi
  GAME_ARGS=()
  [[ "$TARGET" != game ]] && GAME_ARGS+=(--source websocket)
  # always say it: the config's gesture.enabled is only the default of a game started
  # without start.sh
  if [[ "$TARGET" != backend ]]; then
    if [[ "$gesture" == 1 ]]; then GAME_ARGS+=(--gesture); else GAME_ARGS+=(--no-gesture); fi
  fi
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
      # the study mode (#86) on the mock robot: simulated / camera comes from study_mode.demo.source
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
