#!/bin/bash
# install.sh - install ask-away and (optionally) its agent skill.
#
# Usage:
#   install.sh [--build-from-source] [--prefix DIR] [--skill-dir DIR]
#
# Default mode downloads the release tarball from GitHub releases and
# verifies the binary runs before installing. --build-from-source compiles
# locally with build.sh instead. There is no Homebrew formula on purpose.
#
#   --prefix DIR        Directory for the binary. Default /usr/local/bin.
#   --skill-dir DIR     Directory to copy skill/ into (e.g. an agent skill
#                       directory). Skipped when omitted.
#   ASKAWAY_VERSION     Pin a release tag, e.g. ASKAWAY_VERSION=v1.2.3.
#                       Default: the latest release.

set -euo pipefail

REPO="dungle-scrubs/ask-away"
PREFIX="/usr/local/bin"
SKILL_DIR=""
MODE="download"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-from-source) MODE="source"; shift ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --skill-dir) SKILL_DIR="$2"; shift 2 ;;
    *) echo "install.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done

here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [[ "$MODE" == "source" ]]; then
  echo "building from source..."
  "$here/build.sh"
  cp "$here/bin/ask-away" "$tmp/ask-away"
else
  version="${ASKAWAY_VERSION:-latest}"
  url="https://github.com/$REPO/releases/$version/download/ask-away.tar.gz"
  echo "downloading $url"
  curl -fsSL "$url" -o "$tmp/ask-away.tar.gz"
  tar -xzf "$tmp/ask-away.tar.gz" -C "$tmp"
  # The tarball unpacks to an ask-away/ directory: binary at its root, skill/
  # beside it. curl does not set the quarantine attribute, so the ad-hoc
  # signature is enough; verify the binary actually runs before installing.
  bin="$tmp/ask-away/ask-away"
  "$bin" --help >/dev/null
fi

mkdir -p "$PREFIX"
install -m 755 "${bin:-$tmp/ask-away}" "$PREFIX/ask-away"
echo "installed $PREFIX/ask-away"
"$PREFIX/ask-away" --help >/dev/null && echo "verified: $PREFIX/ask-away --help exits 0"

if [[ -n "$SKILL_DIR" ]]; then
  mkdir -p "$SKILL_DIR"
  cp -R "$here/skill/." "$SKILL_DIR/"
  chmod +x "$SKILL_DIR/scripts/ask.sh" 2>/dev/null || true
  echo "installed skill into $SKILL_DIR"
else
  echo "skill not installed: pass --skill-dir DIR to copy skill/ somewhere"
fi
