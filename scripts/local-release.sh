#!/bin/bash
# Local release for ask-away - run on mini. Replaces the Release workflow
# (GitHub-hosted macOS runner, 10x billing). Same packaging: universal
# binary, ad-hoc sign, tarball, GitHub release with the artifact.
# Usage: scripts/local-release.sh vX.Y.Z   (tag must already exist)
set -euo pipefail
cd "$(dirname "$0")/.."

tag="${1:?usage: scripts/local-release.sh <tag>}"
git rev-parse -q --verify "refs/tags/$tag" > /dev/null || { echo "tag $tag not found" >&2; exit 1; }

echo "== build universal binary"
./build.sh
lipo -info bin/ask-away | grep -q "x86_64 arm64"

echo "== ad-hoc sign"
codesign --force --sign - --timestamp=none bin/ask-away

echo "== package"
staging="$(mktemp -d)/ask-away"
mkdir -p "$staging"
cp bin/ask-away "$staging/"
cp -R skill "$staging/skill"
cp README.md LICENSE "$staging/"
tar -czf "ask-away-${tag}.tar.gz" -C "$(dirname "$staging")" ask-away
# Stable-named copy: install.sh's default URL pins
# releases/latest/download/ask-away.tar.gz, which must exist on
# every release regardless of tag.
cp "ask-away-${tag}.tar.gz" ask-away.tar.gz

echo "== smoke test the packaged binary"
bin/ask-away --help > /dev/null

echo "== create GitHub release"
gh release create "$tag" "ask-away-${tag}.tar.gz" "ask-away.tar.gz" --title "$tag" --generate-notes
