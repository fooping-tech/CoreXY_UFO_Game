#!/usr/bin/env bash
# Self-test for start.sh: the option form (#88), the earlier mode names and the default
# (CXUFO_START_MODE / CXUFO_START_ARGS, env or .env). START_SH_DRY_RUN=1 prints the commands:
# no Godot, no backend, no ports, no serial.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0

# run [env assignments...] -- [start.sh args...]: output in $OUT, exit code in $CODE
run() {
  local envs=() a
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  OUT="$(cd "$TMP" && env -u CXUFO_START_MODE -u CXUFO_START_ARGS START_SH_DRY_RUN=1 \
        START_SH_ENV_FILE="$TMP/.env" ${envs[@]+"${envs[@]}"} bash "$ROOT/start.sh" "$@" 2>&1)"
  CODE=$?
}
check() {  # name, condition result
  if [[ $2 -eq 0 ]]; then echo "PASS  $1"; else echo "FAIL  $1"; echo "$OUT" | sed 's/^/      /'; fails=$((fails + 1)); fi
}
has() { [[ "$OUT" == *"$1"* ]]; }
line() { printf '%s\n' "$OUT" | grep -qFx -- "$1"; }  # a whole output line

rm -f "$TMP/.env"
run -- ; has "[START_SH_DRY_RUN] backend: corexy-ufo-backend --gesture --gesture-landmarks" && has "[START_SH_DRY_RUN] game: godot --path $ROOT/game -- --source websocket --gesture" && has "起動: 実機" \
  && has "モーターは無効" && ! has "既定の"; check "nothing set: the real robot + gestures + the game" $?

run CXUFO_START_MODE=game "CXUFO_START_ARGS=--scenario reconnect" -- 
has "既定のモードで起動します（環境変数 CXUFO_START_MODE）: game --scenario reconnect" && has "-- --scenario reconnect"
check "environment: mode and args" $?

run CXUFO_START_MODE=game CXUFO_START_ARGS=--from-env -- game --from-cli
has "-- --from-cli" && ! has "--from-env" && ! has "既定のモード"; check "any argument wins over the default" $?

cat > "$TMP/.env" <<'DOT'
# comment
CF_API_TOKEN=should-not-matter
export CXUFO_START_MODE="game"
CXUFO_START_ARGS='--from-dotenv  --two'
DOT
run -- ; has "（.env の CXUFO_START_MODE）: game --from-dotenv --two" && has "-- --from-dotenv --two"
check ".env: quotes, export, extra spaces" $?

cat > "$TMP/.env" <<'DOT'
CXUFO_START_MODE=game        # game / mock / real / gesture / backend
CXUFO_START_ARGS="--a #b" # comment after quotes
DOT
run -- ; has "（.env の CXUFO_START_MODE）: game --a #b" && has "-- --a #b"
check ".env: inline comments as in the README example" $?

printf 'CXUFO_START_MODE=game\nCXUFO_START_ARGS=--tag#1\n' > "$TMP/.env"
run -- ; has "-- --tag#1"; check ".env: # inside a value is kept" $?

cat > "$TMP/.env" <<'DOT'
export CXUFO_START_MODE="game"
CXUFO_START_ARGS='--from-dotenv  --two'
DOT
run CXUFO_START_ARGS=--from-env -- ; has "-- --from-env" && ! has "--from-dotenv"
check "environment wins over .env per key" $?

printf 'CXUFO_START_MODE=game\nCXUFO_START_ARGS=$(touch %s/ran) `touch %s/ran2` *\n' "$TMP" "$TMP" > "$TMP/.env"
: > "$TMP/somefile"
run -- ; [[ ! -e "$TMP/ran" && ! -e "$TMP/ran2" ]] && has '$(touch' && ! has "somefile"
check ".env is not run as shell code, no glob expansion" $?

printf 'CXUFO_START_MODE=bogus\n' > "$TMP/.env"
run -- ; [[ $CODE -ne 0 ]] && has "不明なモード: bogus"; check "an unknown default mode stops" $?

printf 'CXUFO_START_MODE=\n' > "$TMP/.env"
run -- ; [[ $CODE -eq 0 ]] && ! has "既定の" && has "起動: 実機"; check "empty value: the usual default" $?

run -- bogus2 ; [[ $CODE -ne 0 ]] && has "不明なモード: bogus2（"; check "an unknown mode argument stops with the message" $?

# ---- the option form (#88)
rm -f "$TMP/.env"
run -- --mock ; has "[START_SH_DRY_RUN] backend: corexy-ufo-backend --mock --gesture --gesture-landmarks" && has "[START_SH_DRY_RUN] game: godot --path $ROOT/game -- --source websocket --gesture" && has "仮想クレーン"
check "--mock: the virtual crane with gestures" $?

run -- --mock --no-gesture ; line "[START_SH_DRY_RUN] backend: corexy-ufo-backend --mock" && line "[START_SH_DRY_RUN] game: godot --path $ROOT/game -- --source websocket" && has "ジェスチャー OFF"
check "--no-gesture: neither side gets gestures" $?

run -- --port /dev/cu.TEST --gesture-camera C270 ; has "[START_SH_DRY_RUN] backend: corexy-ufo-backend --port /dev/cu.TEST --gesture C270 --gesture-landmarks" && has "ポート: /dev/cu.TEST"
check "--port and --gesture-camera" $?

run -- --game-only -- --scenario sudden_stop ; has "[START_SH_DRY_RUN] game: godot --path $ROOT/game -- --scenario sudden_stop" && ! has "backend:"
check "--game-only: the game alone, -- args go to the game" $?

run -- --backend-only -- --list-ports ; has "[START_SH_DRY_RUN] backend: corexy-ufo-backend --list-ports" && ! has "game:"
check "--backend-only: -- args go to the backend" $?

run -- --mock --study -- -v ; has "[START_SH_DRY_RUN] backend: corexy-ufo-backend --mock --gesture --gesture-landmarks --study -v"
check "--study and -- args go to the backend" $?

run -- --help ; [[ $CODE -eq 0 ]] && has "使い方: ./start.sh" && ! has "backend:"; check "--help" $?

run -- --bogus ; [[ $CODE -ne 0 ]] && has "不明なオプション: --bogus" && ! has "backend:"; check "an unknown option stops" $?
run -- --mock --game-only ; [[ $CODE -ne 0 ]] && has "--game-only はゲーム内の MockRobot"; check "--game-only with a robot stops" $?
run -- --real --mock ; [[ $CODE -ne 0 ]] && has "一緒に使えない"; check "--real and --mock stop" $?
run -- --game-only --backend-only ; [[ $CODE -ne 0 ]] && has "一緒に使えない"; check "--game-only and --backend-only stop" $?
run -- --backend-only --mock --gesture ; line "[START_SH_DRY_RUN] backend: corexy-ufo-backend --mock --gesture --gesture-landmarks" && has "バックエンドだけ（仮想クレーン）" && ! has "game:"
check "--backend-only --mock --gesture: the mock backend alone" $?
run -- --mock --port /dev/x ; [[ $CODE -ne 0 ]] && has "--port は"; check "--port without the real robot stops" $?
run -- --game-only --study ; [[ $CODE -ne 0 ]] && has "--study は"; check "--study without a backend stops" $?
run -- --port ; [[ $CODE -ne 0 ]] && has "シリアルポートが要ります"; check "--port without a value stops" $?

# ---- the earlier mode names still work as they did
run -- mock ; line "[START_SH_DRY_RUN] backend: corexy-ufo-backend --mock" && line "[START_SH_DRY_RUN] game: godot --path $ROOT/game -- --source websocket" && has "今までの書き方"; check "mode mock as before" $?
run -- real /dev/cu.OLD --gesture ; has "[START_SH_DRY_RUN] backend: corexy-ufo-backend --port /dev/cu.OLD --gesture-landmarks --gesture" && has "[START_SH_DRY_RUN] game: godot --path $ROOT/game -- --source websocket --gesture"
check "mode real PORT --gesture as before" $?
run -- gesture ; has "[START_SH_DRY_RUN] backend: corexy-ufo-backend --mock --gesture --gesture-landmarks"; check "mode gesture as before" $?
run -- backend --list-ports ; has "[START_SH_DRY_RUN] backend: corexy-ufo-backend --list-ports" && ! has "game:"; check "mode backend as before" $?

# ---- the default from CXUFO_START_ARGS alone (option form)
printf 'CXUFO_START_ARGS=--mock --no-gesture\n' > "$TMP/.env"
run -- ; has "既定の引数で起動します（.env の CXUFO_START_ARGS）: --mock --no-gesture" && line "[START_SH_DRY_RUN] backend: corexy-ufo-backend --mock"
check ".env CXUFO_START_ARGS alone: the option form" $?
run -- --game-only ; line "[START_SH_DRY_RUN] game: godot --path $ROOT/game -- " && ! has "既定の"; check "arguments win over CXUFO_START_ARGS" $?

if [[ $fails -eq 0 ]]; then echo "start.sh: all passed"; else echo "start.sh: $fails failed"; fi
exit $(( fails > 0 ))
