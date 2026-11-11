#!/usr/bin/env bash
# Self-test for start.sh's default mode (CXUFO_START_MODE / CXUFO_START_ARGS, env or .env).
# Only the `game` mode and errors are exercised, with START_SH_NO_GAME=1: no Godot,
# no backend, no ports.
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
  OUT="$(cd "$TMP" && env -u CXUFO_START_MODE -u CXUFO_START_ARGS START_SH_NO_GAME=1 \
        START_SH_ENV_FILE="$TMP/.env" ${envs[@]+"${envs[@]}"} bash "$ROOT/start.sh" "$@" 2>&1)"
  CODE=$?
}
check() {  # name, condition result
  if [[ $2 -eq 0 ]]; then echo "PASS  $1"; else echo "FAIL  $1"; echo "$OUT" | sed 's/^/      /'; fails=$((fails + 1)); fi
}
has() { [[ "$OUT" == *"$1"* ]]; }

rm -f "$TMP/.env"
run -- ; has "[START_SH_NO_GAME] godot --path $ROOT/game -- " && ! has "既定のモード"; check "nothing set: the game alone, as before" $?

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
run -- ; [[ $CODE -eq 0 ]] && ! has "既定のモード"; check "empty value: the game alone" $?

run -- bogus2 ; [[ $CODE -ne 0 ]] && has "不明なモード: bogus2（"; check "an unknown mode argument stops with the message" $?

if [[ $fails -eq 0 ]]; then echo "start.sh: all passed"; else echo "start.sh: $fails failed"; fi
exit $(( fails > 0 ))
