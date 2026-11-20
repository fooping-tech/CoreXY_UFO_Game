#!/usr/bin/env bash
# Rebuilds Godot's import cache (game/.godot, not in Git) when it is missing or older than
# a script: Godot does not rescan `class_name` at run time, so after a pull or a branch
# switch that adds one, the game and the tests stop at "Identifier ... not declared".
#   tools/godot_refresh.sh <godot binary> <game dir>
# Quiet and never fatal: a failed import leaves the start to show the real error.
set -uo pipefail
GODOT_BIN="${1:?godot binary}"
GAME="${2:?game dir}"
CACHE="$GAME/.godot/global_script_class_cache.cfg"
if [[ -f "$CACHE" && -d "$GAME/.godot/imported" ]]; then
  newer="$(find "$GAME" -path "$GAME/.godot" -prune -o -name '*.gd' -newer "$CACHE" -print 2>/dev/null | head -n 1)"
  [[ -z "$newer" ]] && exit 0
fi
"$GODOT_BIN" --headless --path "$GAME" --import >/dev/null 2>&1 || true
[[ -f "$CACHE" ]] && touch "$CACHE"
exit 0
