#!/usr/bin/env bash
# Project checks, used by /dev before every PR and by CI (.github/workflows/ci.yml).
#
#   tools/verify.sh                 # everything
#   tools/verify.sh --only godot    # one part: secrets | tooling | backend | godot
#
# Godot binary: $GODOT, else /Applications/Godot.app, else `godot` on PATH.
# Test counts are the project's baseline (see CLAUDE.md); a drop is a failure to explain.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ONLY=""
if [[ "${1:-}" == "--only" ]]; then
  ONLY="${2:-}"
  case "$ONLY" in secrets|tooling|backend|godot) ;; *) echo "usage: $0 [--only secrets|tooling|backend|godot]" >&2; exit 2 ;; esac
elif [[ $# -gt 0 ]]; then
  echo "usage: $0 [--only secrets|tooling|backend|godot]" >&2; exit 2
fi
FAILED=()
PASSED=()

want() { [[ -z "$ONLY" || "$ONLY" == "$1" ]]; }
step() { printf '\n== %s\n' "$1"; }
record() { if [[ $1 -eq 0 ]]; then PASSED+=("$2"); else FAILED+=("$2"); fi; }

find_godot() {
  if [[ -n "${GODOT:-}" ]]; then echo "$GODOT"; return; fi
  if [[ -x /Applications/Godot.app/Contents/MacOS/Godot ]]; then echo /Applications/Godot.app/Contents/MacOS/Godot; return; fi
  command -v godot 2>/dev/null || true
}

# The test runner quits by itself after the tests (run_tests.gd). A script that does not parse
# never gets there and Godot waits forever (#132), so: a load error stops it at once, a run longer
# than GODOT_TEST_TIMEOUT seconds stops it, and a run without its "N passed, 0 failed" line fails.
GODOT_TEST_TIMEOUT="${GODOT_TEST_TIMEOUT:-600}"
run_godot_tests() {
  local log pid rc why=""
  log="$(mktemp)"
  "$GODOT_BIN" --headless --path "$ROOT/game" res://tests/test_runner.tscn >"$log" 2>&1 &
  pid=$!
  local start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    if grep -qE "Parse Error|Failed to load script" "$log"; then
      why="スクリプトを読み込めない（構文エラー）"; break
    fi
    if (( SECONDS - start > GODOT_TEST_TIMEOUT )); then
      why="${GODOT_TEST_TIMEOUT} 秒で終わらない（GODOT_TEST_TIMEOUT）"; break
    fi
    sleep 1
  done
  if [[ -n "$why" ]]; then
    kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    rc=1
  else
    wait "$pid"; rc=$?
  fi
  grep -E "^(PASS|FAIL)|passed|SCRIPT ERROR|Parse Error|Failed to load script" "$log" | grep -v "^PASS"
  if [[ -n "$why" ]]; then
    echo "Godot のテストを止めた: $why"
  elif [[ $rc -eq 0 ]] && ! grep -qE "^[0-9]+ passed, 0 failed" "$log"; then
    echo "Godot のテストが結果の行（N passed, 0 failed）を出さずに終わった"; rc=1
  fi
  rm -f "$log"
  return "$rc"
}

if want secrets; then
  step "security: secrets / history / vulnerabilities / config + scanner self-test (same as security.yml)"
  "$ROOT/tools/security/scan.sh" all && "$ROOT/tools/security/scan.sh" selftest
  record $? "secrets"
fi

# start.ps1 (Windows) in its dry run; pwsh is on the CI runners. Skipped (not failed) without it.
test_start_ps1() {
  if command -v pwsh >/dev/null 2>&1; then
    pwsh -NoProfile -File "$ROOT/tools/test_start_ps1.ps1"
  else
    echo "pwsh が見つからないので start.ps1 のテストは省略"
  fi
}

if want tooling; then
  step "dev tooling (guard hook + dev_state + start.sh + start.ps1 + setup_devicehub)"
  python3 "$ROOT/.claude/hooks/guard_git.py" --self-test && \
    python3 -m unittest discover -s "$ROOT/.claude/skills/dev/scripts" -p 'test_*.py' && \
    "$ROOT/tools/test_start_sh.sh" && \
    test_start_ps1 && \
    "$ROOT/tools/test_setup_devicehub.sh"
  record $? "tooling"
fi

if want backend; then
  step "backend: pytest"
  if [[ ! -f "$ROOT/external/UFO-DeviceHub/pyproject.toml" ]]; then
    # the backend's dependency ufo-devicehub is that clone (#159): uv cannot resolve without it
    echo "external/UFO-DeviceHub がない: tools/setup_devicehub.sh を実行する（CI は --pinned）"; record 1 "backend"
  elif command -v uv >/dev/null 2>&1; then
    # which UFO-DeviceHub commit the tests ran against (CI: the verified one, tools/devicehub.pin)
    "$ROOT/tools/setup_devicehub.sh" --status
    (cd "$ROOT/backend" && unset VIRTUAL_ENV && uv run pytest -q)
    record $? "backend"
  else
    echo "uv が見つからない (brew install uv)"; record 1 "backend"
  fi
fi

if want godot; then
  step "game: Godot headless tests"
  GODOT_BIN="$(find_godot)"
  if [[ -z "$GODOT_BIN" ]]; then
    echo "Godot が見つからない (GODOT=... で指定)"; record 1 "godot"
  else
    if [[ ! -d "$ROOT/game/.godot/imported" ]]; then
      "$GODOT_BIN" --headless --path "$ROOT/game" --import >/dev/null 2>&1
    fi
    run_godot_tests
    record $? "godot"
  fi
fi

printf '\n== summary\npassed: %s\nfailed: %s\n' "${PASSED[*]:-none}" "${FAILED[*]:-none}"
[[ ${#FAILED[@]} -eq 0 ]]
