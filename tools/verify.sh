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

if want secrets; then
  step "security: secrets / history / vulnerabilities / config + scanner self-test (same as security.yml)"
  "$ROOT/tools/security/scan.sh" all && "$ROOT/tools/security/scan.sh" selftest
  record $? "secrets"
fi

if want tooling; then
  step "dev tooling (guard hook + dev_state)"
  python3 "$ROOT/.claude/hooks/guard_git.py" --self-test && \
    python3 -m unittest discover -s "$ROOT/.claude/skills/dev/scripts" -p 'test_*.py'
  record $? "tooling"
fi

if want backend; then
  step "backend: pytest"
  if command -v uv >/dev/null 2>&1; then
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
    "$GODOT_BIN" --headless --path "$ROOT/game" res://tests/test_runner.tscn 2>&1 | \
      grep -E "^(PASS|FAIL)|passed|SCRIPT ERROR" | grep -v "^PASS"
    record "${PIPESTATUS[0]}" "godot"
  fi
fi

printf '\n== summary\npassed: %s\nfailed: %s\n' "${PASSED[*]:-none}" "${FAILED[*]:-none}"
[[ ${#FAILED[@]} -eq 0 ]]
