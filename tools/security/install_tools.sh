#!/usr/bin/env bash
# Install the pinned security scanners into tools/.bin (git-ignored).
#
#   tools/security/install_tools.sh          # gitleaks + trivy
#
# Versions are pinned and every download is checked against the SHA-256 below
# (copied from the upstream release checksums when the version was chosen), so a
# tampered release asset or a moved tag cannot slip in. To upgrade: pick a release
# that has been out for at least two weeks, update VERSION and the hashes together.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/tools/.bin"
mkdir -p "$BIN"

GITLEAKS_VERSION="8.30.1"
TRIVY_VERSION="0.75.0"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)
    GITLEAKS_ASSET="gitleaks_${GITLEAKS_VERSION}_darwin_arm64.tar.gz"
    GITLEAKS_SHA="b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5"
    TRIVY_ASSET="trivy_${TRIVY_VERSION}_macOS-ARM64.tar.gz"
    TRIVY_SHA="4a77108cccf8e55c8d6823e1e759939a622277e66cd0daa3c1fc621ed69e4568" ;;
  Darwin-x86_64)
    GITLEAKS_ASSET="gitleaks_${GITLEAKS_VERSION}_darwin_x64.tar.gz"
    GITLEAKS_SHA="dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709"
    TRIVY_ASSET="trivy_${TRIVY_VERSION}_macOS-64bit.tar.gz"
    TRIVY_SHA="291edaa9778acbe4693d067b5ad60ee11570e5ac68296e85595417528ca641e4" ;;
  Linux-x86_64)
    GITLEAKS_ASSET="gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
    GITLEAKS_SHA="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"
    TRIVY_ASSET="trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz"
    TRIVY_SHA="c6e65abddb348e25f10549df887045629cf28cc72453cd1c63acb717316b3f3f" ;;
  *) echo "unsupported platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

install_one() {  # name version url sha binary-in-archive
  local name=$1 version=$2 url=$3 want=$4 member=$5
  if [[ -x "$BIN/$name" ]] && "$BIN/$name" --version 2>/dev/null | grep -q "$version"; then
    echo "$name $version: already installed"; return
  fi
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/archive.tar.gz" "$url"
  local got; got="$(sha256 "$tmp/archive.tar.gz")"
  if [[ "$got" != "$want" ]]; then
    echo "$name: SHA-256 mismatch (expected $want, got $got). Not installing." >&2
    rm -rf "$tmp"; exit 1
  fi
  tar -xzf "$tmp/archive.tar.gz" -C "$tmp" "$member"
  install -m 0755 "$tmp/$member" "$BIN/$name"
  rm -rf "$tmp"
  echo "$name $version: installed to tools/.bin/$name (sha256 verified)"
}

install_one gitleaks "$GITLEAKS_VERSION" \
  "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/${GITLEAKS_ASSET}" "$GITLEAKS_SHA" gitleaks
install_one trivy "$TRIVY_VERSION" \
  "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/${TRIVY_ASSET}" "$TRIVY_SHA" trivy
