#!/usr/bin/env bash
# Apply .github/rulesets/main.json to the repository (repository admin only).
# Creates the ruleset "main protection" or updates it in place (idempotent).
#
#   tools/security/apply_ruleset.sh            # apply
#   tools/security/apply_ruleset.sh --check    # show whether it is applied and matches
#
# Run this yourself: Claude's guard hook deliberately refuses to change rulesets.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FILE="$ROOT/.github/rulesets/main.json"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
NAME="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$FILE")"
ID="$(gh api "repos/$REPO/rulesets" -q ".[] | select(.name == \"$NAME\") | .id" | head -1)"

if [[ "${1:-}" == "--check" ]]; then
  if [[ -z "$ID" ]]; then echo "未適用: ruleset \"$NAME\" がない"; exit 1; fi
  gh api "repos/$REPO/rulesets/$ID" > /tmp/ruleset_current.json
  python3 - "$FILE" /tmp/ruleset_current.json <<'PY'
import json, sys
want, have = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
def checks(r):
    for rule in r["rules"]:
        if rule["type"] == "required_status_checks":
            return sorted(c["context"] for c in rule["parameters"]["required_status_checks"])
    return []
ok = have["enforcement"] == "active" and checks(want) == checks(have) and not have.get("bypass_actors")
print("適用済み: enforcement=%s, 必須チェック %d 件, bypass %d 件 -> %s" % (
    have["enforcement"], len(checks(have)), len(have.get("bypass_actors") or []), "一致" if ok else "定義と不一致"))
sys.exit(0 if ok else 1)
PY
  exit $?
fi

if [[ -n "$ID" ]]; then
  gh api -X PUT "repos/$REPO/rulesets/$ID" --input "$FILE" -q '"updated ruleset " + (.id|tostring) + " (" + .enforcement + ")"'
else
  gh api -X POST "repos/$REPO/rulesets" --input "$FILE" -q '"created ruleset " + (.id|tostring) + " (" + .enforcement + ")"'
fi
