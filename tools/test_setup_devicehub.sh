#!/usr/bin/env bash
# Self-test for tools/setup_devicehub.sh (and .ps1 when pwsh is there): a stand-in for
# UFO-DeviceHub is made in a temporary directory, so no network and nothing of external/
# is touched (#159). uv sync is not run here (--no-sync).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
G=(git -c user.name=test -c user.email=test@example.invalid -c init.defaultBranch=main -c commit.gpgsign=false)

# the stand-in: an old commit without the package, the verified one, a newer one on main
UP="$TMP/upstream"
"${G[@]}" init --quiet "$UP"
echo old > "$UP/README.md"; "${G[@]}" -C "$UP" add -A; "${G[@]}" -C "$UP" commit --quiet -m old
OLD="$(git -C "$UP" rev-parse HEAD)"
echo '[project]' > "$UP/pyproject.toml"; "${G[@]}" -C "$UP" add -A; "${G[@]}" -C "$UP" commit --quiet -m package
GOOD="$(git -C "$UP" rev-parse HEAD)"
echo newer > "$UP/README.md"; "${G[@]}" -C "$UP" add -A; "${G[@]}" -C "$UP" commit --quiet -m newer
NEW="$(git -C "$UP" rev-parse HEAD)"
printf '# test\nrepo=%s\ncommit=%s\n' "$UP" "$GOOD" > "$TMP/pin"
printf 'repo=%s\ncommit=%s\n' "$UP" "$OLD" > "$TMP/pin_old"
printf 'repo=%s\ncommit=nonsense\n' "$UP" > "$TMP/pin_bad"

check() { if [[ $2 -eq 0 ]]; then echo "PASS  $KIND: $1"; else echo "FAIL  $KIND: $1"; echo "$OUT" | sed 's/^/      /'; fails=$((fails + 1)); fi; }
has() { [[ "$OUT" == *"$1"* ]]; }
head_of() { git -C "$DIR" rev-parse HEAD; }

cases() {  # KIND, and run() defined: run PIN_FILE flags...
  DIR="$TMP/$KIND/external/UFO-DeviceHub"
  run "$TMP/pin" status; [[ $CODE -eq 1 ]] && has "まだ clone していない"; check "status: no clone yet" $?
  run "$TMP/pin_bad"; [[ $CODE -eq 1 ]] && has "devicehub.pin を読めない" && [[ ! -e "$DIR" ]]; check "a pin that is not a commit: nothing is cloned" $?
  run "$TMP/pin"; [[ $CODE -eq 0 && "$(head_of)" == "$GOOD" ]] && has "確認済みのコミット ${GOOD:0:7} です"; check "no clone: cloned at the verified commit" $?
  git -C "$DIR" checkout --quiet --detach "$NEW"
  run "$TMP/pin"; [[ $CODE -eq 0 && "$(head_of)" == "$NEW" ]] && has "確認済みのコミットは ${GOOD:0:7}"; check "a clone that is there is left where it is, and said" $?
  echo mine >> "$DIR/README.md"
  run "$TMP/pin" pinned; [[ $CODE -eq 1 && "$(head_of)" == "$NEW" ]] && has "未コミットの変更" && grep -q mine "$DIR/README.md"; check "pinned: uncommitted work is never thrown away" $?
  git -C "$DIR" checkout --quiet -- README.md
  run "$TMP/pin" pinned; [[ $CODE -eq 0 && "$(head_of)" == "$GOOD" ]]; check "pinned: moved to the verified commit" $?
  run "$TMP/pin" status; [[ $CODE -eq 0 ]] && has "確認済みのコミット ${GOOD:0:7} です"; check "status: at the verified commit" $?
  run "$TMP/pin_old" pinned; [[ $CODE -eq 1 ]] && has "pyproject.toml がない"; check "a commit without the package is refused" $?
  rm -rf "$DIR"; mkdir -p "$DIR"; echo x > "$DIR/file"
  run "$TMP/pin"; [[ $CODE -eq 1 ]] && has "clone ではない" && [[ -f "$DIR/file" ]]; check "a directory that is not a clone is not replaced" $?
}

KIND=sh
run() {
  local pin="$1" a flags=(--no-sync); shift
  for a in "$@"; do flags+=("--$a"); done
  OUT="$(SETUP_DEVICEHUB_DIR="$DIR" SETUP_DEVICEHUB_PIN="$pin" bash "$ROOT/tools/setup_devicehub.sh" "${flags[@]}" 2>&1)"; CODE=$?
}
cases

if command -v pwsh >/dev/null 2>&1; then
  KIND=ps1
  run() {
    local pin="$1" a flags=(-NoSync); shift
    for a in "$@"; do case "$a" in status) flags+=(-Status) ;; pinned) flags+=(-Pinned) ;; esac; done
    OUT="$(SETUP_DEVICEHUB_DIR="$DIR" SETUP_DEVICEHUB_PIN="$pin" pwsh -NoProfile -File "$ROOT/tools/setup_devicehub.ps1" "${flags[@]}" 2>&1)"; CODE=$?
  }
  cases
else
  echo "pwsh が見つからないので setup_devicehub.ps1 のテストは省略"
fi

if [[ $fails -eq 0 ]]; then echo "setup_devicehub: all passed"; else echo "setup_devicehub: $fails failed"; fi
exit $(( fails > 0 ))
