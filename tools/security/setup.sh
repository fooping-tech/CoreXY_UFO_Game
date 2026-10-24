#!/usr/bin/env bash
# One-time local setup: pinned scanners + pre-commit hooks (pre-commit and pre-push).
#   tools/security/setup.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
PRE_COMMIT_VERSION="4.7.0"

tools/security/install_tools.sh

if ! command -v pre-commit >/dev/null 2>&1 || ! pre-commit --version | grep -q "$PRE_COMMIT_VERSION"; then
  if command -v uv >/dev/null 2>&1; then
    uv tool install --force "pre-commit==$PRE_COMMIT_VERSION"
  else
    echo "pre-commit が必要: brew install uv の後に再実行するか、pip install pre-commit==$PRE_COMMIT_VERSION" >&2
    exit 1
  fi
fi
PRE_COMMIT="$(command -v pre-commit || echo "$HOME/.local/bin/pre-commit")"
"$PRE_COMMIT" install --install-hooks --hook-type pre-commit --hook-type pre-push
echo "OK: commit 前と push 前に秘密情報の検査が動きます（tools/security/scan.sh staged / push）"
