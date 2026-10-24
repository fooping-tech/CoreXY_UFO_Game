#!/usr/bin/env bash
# Security checks: local hooks (pre-commit / pre-push), /dev, tools/verify.sh and CI.
#
#   tools/security/scan.sh staged        # pre-commit: staged changes (gitleaks) + forbidden file names
#   tools/security/scan.sh push          # pre-push: commits not yet on origin (gitleaks)
#   tools/security/scan.sh history       # whole git history, all refs (gitleaks)
#   tools/security/scan.sh forbidden     # tracked files: forbidden names (.env, keys, ...) + secret patterns
#   tools/security/scan.sh trivy-secret  # Trivy secret scan (any severity fails)
#   tools/security/scan.sh trivy-vuln    # Trivy dependency vulnerabilities (HIGH/CRITICAL fail)
#   tools/security/scan.sh trivy-config  # Trivy misconfiguration (HIGH/CRITICAL fail)
#   tools/security/scan.sh exceptions    # .trivyignore.yaml entries have a reason and an expiry
#   tools/security/scan.sh selftest      # scanners must FAIL on dummy secrets / vulnerable deps / bad config
#   tools/security/scan.sh all           # forbidden + exceptions + history + trivy-*
#
# Secret values are never printed: reports go to a temp file and only file / rule /
# line / commit are shown (tools/security/report.py).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SEC="$ROOT/tools/security"
BIN="$ROOT/tools/.bin"
GUARD="$ROOT/.claude/hooks/guard_git.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$ROOT"

need_tools() {
  if [[ ! -x "$BIN/gitleaks" || ! -x "$BIN/trivy" ]]; then
    "$SEC/install_tools.sh" >/dev/null || { echo "scanner のインストールに失敗した（tools/security/install_tools.sh）"; exit 1; }
  fi
}

GL=( "$BIN/gitleaks" git --no-banner --redact --log-level error --config "$ROOT/.gitleaks.toml"
     --report-format json )
TRIVY_SKIP=( --skip-dirs tools/.bin --skip-dirs game/.godot --skip-dirs backend/.venv --skip-dirs .git )

gitleaks_run() {  # extra args...
  local report="$TMP/gl.json"
  "${GL[@]}" --report-path "$report" --exit-code 0 "$@" "$ROOT" >/dev/null 2>"$TMP/gl.err"
  local rc=$?
  if [[ $rc -ne 0 ]]; then echo "gitleaks の実行に失敗した:"; sed -e 's/^/  /' "$TMP/gl.err" | head -5; return 1; fi
  python3 "$SEC/report.py" gitleaks "$report"
}

trivy_run() {  # target scanners severity extra...
  local target=$1 scanners=$2 severity=$3; shift 3
  local report="$TMP/trivy.json"
  "$BIN/trivy" fs --quiet --scanners "$scanners" --severity "$severity" --format json --output "$report" \
    --secret-config "$SEC/trivy-secret.yaml" "$@" "$target" 2>"$TMP/trivy.err" \
    || { echo "trivy の実行に失敗した:"; sed -e 's/^/  /' "$TMP/trivy.err" | tail -5; return 1; }
  python3 "$SEC/report.py" trivy "$report"
}

ALL_SEV="UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL"

mode_staged() {
  need_tools
  git diff --cached --name-only --diff-filter=AMR | python3 "$GUARD" --check-names || return 1
  gitleaks_run --pre-commit --staged
}
mode_push() {
  need_tools
  # Everything that can be sent and the remote does not have yet: the ref being pushed
  # (pre-commit sets PRE_COMMIT_TO_REF / PRE_COMMIT_REMOTE_NAME for each pushed ref),
  # plus every local branch and tag, so pushing another branch or a tag cannot slip past.
  local remote="${PRE_COMMIT_REMOTE_NAME:-origin}" to="${PRE_COMMIT_TO_REF:-}"
  git remote | grep -qx "$remote" || remote=origin
  gitleaks_run --log-opts="${to:+$to }HEAD --branches --tags --not --remotes=$remote"
}
mode_history() { need_tools; gitleaks_run --log-opts="--all"; }
mode_forbidden() { python3 "$GUARD" --scan-tracked; }
mode_trivy_secret() { need_tools; trivy_run . secret "$ALL_SEV" "${TRIVY_SKIP[@]}"; }
mode_trivy_vuln() { need_tools; trivy_run . vuln HIGH,CRITICAL --ignorefile .trivyignore.yaml "${TRIVY_SKIP[@]}"; }
mode_trivy_config() { need_tools; trivy_run . misconfig HIGH,CRITICAL --ignorefile .trivyignore.yaml "${TRIVY_SKIP[@]}"; }
mode_exceptions() { python3 "$SEC/report.py" check-exceptions .trivyignore.yaml; }

expect_fail() {  # name, command... — the scanner must report a finding (non-zero)
  local name=$1; shift
  local out; out="$("$@" 2>&1)"; local rc=$?
  printf '%s\n' "$out" > "$TMP/out_$name.txt"
  if [[ $rc -ne 0 ]] && grep -qE "^(SECRET|VULN|CONFIG|forbidden|FORBIDDEN)" "$TMP/out_$name.txt"; then
    echo "  ok    $name: 検出して失敗した"; return 0
  fi
  echo "  FAIL  $name: 検出しなかった (rc=$rc)"; sed -e 's/^/        /' "$TMP/out_$name.txt" | tail -5; return 1
}

mode_selftest() {
  need_tools
  local fails=0 d="$TMP/fixture"
  mkdir -p "$d" && git -C "$d" init -q
  # Dummy values generated now, never written into this repository.
  local gh_tok cx_tok
  gh_tok="ghp_$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)"
  cx_tok="cxufo_test_$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
  printf 'GITHUB_TOKEN = "%s"\nSERVICE_KEY = "%s"\n' "$gh_tok" "$cx_tok" > "$d/settings.py"
  printf 'requests==2.19.1\n' > "$d/requirements.txt"
  printf 'FROM ubuntu:latest\nRUN apt-get update\n' > "$d/Dockerfile"
  git -C "$d" add settings.py && git -C "$d" -c user.name=t -c user.email=t@example.invalid commit -qm fixture

  echo "selftest: 検出用のダミー（実在しないキー、既知の脆弱な依存、不適切な Dockerfile）で各検査が失敗することを確認"
  "${GL[@]}" --report-path "$TMP/st_gl.json" --exit-code 0 "$d" >/dev/null 2>&1
  if python3 "$SEC/report.py" gitleaks "$TMP/st_gl.json" > "$TMP/st_gl.txt"; then
    echo "  FAIL  gitleaks-history: 検出しなかった"; fails=$((fails + 1))
  else
    for rule in github-pat cxufo-api-key; do
      grep -q "rule=$rule" "$TMP/st_gl.txt" && echo "  ok    gitleaks: $rule を検出" || { echo "  FAIL  gitleaks: $rule を検出しない"; fails=$((fails + 1)); }
    done
  fi
  expect_fail trivy-secret trivy_run "$d" secret "$ALL_SEV" || fails=$((fails + 1))
  grep -q "rule=cxufo-api-key" "$TMP/out_trivy-secret.txt" && echo "  ok    trivy: cxufo-api-key（独自ルール）を検出" \
    || { echo "  FAIL  trivy: 独自ルールで検出しない"; fails=$((fails + 1)); }
  expect_fail trivy-vuln trivy_run "$d" vuln HIGH,CRITICAL || fails=$((fails + 1))
  expect_fail trivy-config trivy_run "$d" misconfig HIGH,CRITICAL || fails=$((fails + 1))
  expect_fail forbidden-names sh -c "printf '.env\nkeys/id_ed25519\n' | python3 '$GUARD' --check-names" || fails=$((fails + 1))

  # the reports must never contain the values themselves
  if grep -rqF -e "$gh_tok" -e "$cx_tok" "$TMP"/out_*.txt "$TMP/st_gl.txt" "$TMP/st_gl.json" 2>/dev/null; then
    echo "  FAIL  出力にダミーの値そのものが含まれている"; fails=$((fails + 1))
  else
    echo "  ok    出力にキーの値が含まれない（ファイル・ルール・行のみ）"
  fi
  # the custom rule must be the same in all three places
  python3 - "$ROOT" <<'EOF' || fails=$((fails + 1))
import re, sys
root = sys.argv[1]
gl = re.search(r"regex = '''(.+?)'''", open(root + "/.gitleaks.toml").read()).group(1)
tv = re.search(r"regex:\s*(\S+)", open(root + "/tools/security/trivy-secret.yaml").read()).group(1)
gd = re.search(r'\("CoreXY UFO API key", re\.compile\(r"(.+?)"\)\)', open(root + "/.claude/hooks/guard_git.py").read()).group(1)
if gl == tv == gd:
    print("  ok    独自ルールの正規表現が 3 か所で一致")
else:
    print("  FAIL  独自ルールの正規表現が一致しない: gitleaks=%s trivy=%s guard=%s" % (gl, tv, gd)); sys.exit(1)
EOF
  # push scan covers refs other than HEAD (a secret on another branch / a tag)
  local p="$TMP/pushrepo"
  git init -q --bare "$TMP/remote.git" && git clone -q "$TMP/remote.git" "$p" 2>/dev/null
  git -C "$p" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  git -C "$p" push -q origin HEAD:main 2>/dev/null
  git -C "$p" switch -q -c other && printf 'K = "%s"\n' "$cx_tok" > "$p/k.py" && git -C "$p" add k.py \
    && git -C "$p" -c user.name=t -c user.email=t@example.invalid commit -q -m secret && git -C "$p" tag -a v0 -m v0 \
    && git -C "$p" switch -q main && git -C "$p" branch -q -D other
  if (cd "$p" && "${GL[@]}" --report-path "$TMP/st_push.json" --exit-code 0 --log-opts="HEAD --branches --tags --not --remotes=origin" "$p" >/dev/null 2>&1) \
      && ! python3 "$SEC/report.py" gitleaks "$TMP/st_push.json" >/dev/null; then
    echo "  ok    push 前の検査: HEAD 以外（タグだけにあるコミット）の秘密情報も検出"
  else
    echo "  FAIL  push 前の検査: HEAD 以外の参照を検査していない"; fails=$((fails + 1))
  fi
  python3 "$SEC/report.py" selftest-exceptions | sed -e 's/^/  /' || fails=$((fails + 1))
  python3 "$GUARD" --self-test | sed -e 's/^/  /' || fails=$((fails + 1))
  [[ $fails -eq 0 ]] && echo "selftest: OK" || echo "selftest: $fails 件失敗"
  [[ $fails -eq 0 ]]
}

mode_all() {
  local rc=0
  for m in forbidden exceptions history trivy_secret trivy_vuln trivy_config; do
    echo "== $m"; "mode_$m" || rc=1
  done
  return $rc
}

case "${1:-}" in
  staged|push|history|forbidden|exceptions|selftest|all) "mode_$1" ;;
  trivy-secret|trivy-vuln|trivy-config) "mode_${1//-/_}" ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
