#!/usr/bin/env bash
# UFO-DeviceHub (the peripherals' hub: its PC client is a Python dependency of the backend, #159)
# as an ordinary git clone in external/UFO-DeviceHub/. Not a submodule, never committed here.
#
#   tools/setup_devicehub.sh            # no clone yet: clone it at the verified commit. Then uv sync
#   tools/setup_devicehub.sh --pinned   # put the clone at the verified commit (CI, the exhibit's PC)
#   tools/setup_devicehub.sh --status   # where the clone is, against the verified commit
#   tools/setup_devicehub.sh --no-sync  # (with the above) do not run uv sync
#
# The verified commit is tools/devicehub.pin. A clone that is already there is left as it is
# unless --pinned is given, and --pinned refuses a clone with uncommitted changes: your work
# in it is never thrown away. Editing its Python needs no uv sync, only a restart of the backend.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# SETUP_DEVICEHUB_DIR / SETUP_DEVICEHUB_PIN: tests only (tools/test_setup_devicehub.sh)
DIR="${SETUP_DEVICEHUB_DIR:-$ROOT/external/UFO-DeviceHub}"
PIN_FILE="${SETUP_DEVICEHUB_PIN:-$ROOT/tools/devicehub.pin}"
PINNED=0; STATUS=0; SYNC=1
for a in "$@"; do
  case "$a" in
    --pinned) PINNED=1 ;;
    --status) STATUS=1 ;;
    --no-sync) SYNC=0 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "usage: $0 [--pinned] [--status] [--no-sync]" >&2; exit 2 ;;
  esac
done

pin() { sed -n "s/^$1=//p" "$PIN_FILE" | head -1; }
# CXUFO_DEVICEHUB_URL: another place to clone from (a local clone, for a PC without the network)
REPO="${CXUFO_DEVICEHUB_URL:-$(pin repo)}"
COMMIT="$(pin commit)"
[[ -n "$REPO" && "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "tools/devicehub.pin を読めない（repo= と 40 桁の commit= が必要）" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git が見つかりません" >&2; exit 1; }

head_of() { git -C "$DIR" rev-parse HEAD 2>/dev/null; }
is_clone() { [[ -e "$DIR/.git" ]]; }
dirty() { [[ -n "$(git -C "$DIR" status --porcelain 2>/dev/null)" ]]; }

report() {
  if ! is_clone; then echo "UFO-DeviceHub: まだ clone していない（${DIR}）"; return 1; fi
  local head; head="$(head_of)"
  if [[ "$head" == "$COMMIT" ]]; then
    echo "UFO-DeviceHub: 確認済みのコミット ${COMMIT:0:7} です$(dirty && echo '（未コミットの変更あり）')"
  else
    echo "UFO-DeviceHub: ${head:0:7}（$(git -C "$DIR" rev-parse --abbrev-ref HEAD)）。確認済みのコミットは ${COMMIT:0:7}$(dirty && echo '。未コミットの変更あり')"
    echo "  確認済みのコミットに合わせる: tools/setup_devicehub.sh --pinned"
  fi
}

if [[ "$STATUS" == 1 ]]; then report; exit $?; fi

if ! is_clone; then
  if [[ -e "$DIR" ]] && [[ -n "$(ls -A "$DIR" 2>/dev/null)" ]]; then
    echo "$DIR があるが git の clone ではない。中身を確かめて、どかしてからやり直してください" >&2; exit 1
  fi
  mkdir -p "$(dirname "$DIR")"
  echo "UFO-DeviceHub を clone します: $REPO -> external/UFO-DeviceHub"
  git clone --quiet "$REPO" "$DIR" || { echo "clone に失敗しました（ネットワークと URL を確かめる）" >&2; exit 1; }
  PINNED=1  # a new clone starts at the commit this game is verified with
fi

if [[ "$PINNED" == 1 && "$(head_of)" != "$COMMIT" ]]; then
  if dirty; then
    echo "external/UFO-DeviceHub に未コミットの変更があるので、コミットを切り替えません。" >&2
    echo "  変更をコミットするか退避してから、もう一度 --pinned を実行してください" >&2
    exit 1
  fi
  git -C "$DIR" cat-file -e "$COMMIT^{commit}" 2>/dev/null || git -C "$DIR" fetch --quiet origin \
    || { echo "fetch に失敗しました（ネットワークを確かめる）" >&2; exit 1; }
  git -C "$DIR" cat-file -e "$COMMIT^{commit}" 2>/dev/null \
    || git -C "$DIR" fetch --quiet origin "$COMMIT" 2>/dev/null
  git -C "$DIR" checkout --quiet --detach "$COMMIT" \
    || { echo "コミット $COMMIT が見つかりません（tools/devicehub.pin を確かめる）" >&2; exit 1; }
  echo "  開発を続けるときは: git -C external/UFO-DeviceHub switch main（または作業ブランチ）"
fi
report

[[ -f "$DIR/pyproject.toml" ]] || {
  echo "external/UFO-DeviceHub に pyproject.toml がない（古いコミット）。tools/setup_devicehub.sh --pinned で確認済みのコミットにする" >&2
  exit 1
}

if [[ "$SYNC" == 1 ]]; then
  command -v uv >/dev/null 2>&1 || { echo "uv が見つかりません: brew install uv" >&2; exit 1; }
  # --inexact: the extras start.sh installed (camera, hand tracking) stay
  (cd "$ROOT/backend" && unset VIRTUAL_ENV && uv sync --quiet --inexact) || { echo "uv sync に失敗しました" >&2; exit 1; }
  echo "backend: uv sync 済み（UFO-DeviceHub は editable。Python の編集はバックエンドの再起動で反映）"
fi
