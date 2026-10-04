#!/bin/bash
# build.sh - compile bin/ask-away as a universal (arm64 + x86_64) binary.
#
# Two -target builds plus lipo, because a single --arch pair bakes the host
# SDK's minimum macOS version into the binary; explicit targets pin the
# deployment floor to macOS 13 (the design's floor).

set -euo pipefail
cd "$(dirname "$0")"

out="bin/ask-away"
mkdir -p bin

echo "building arm64..."
swiftc -O -swift-version 6 -warnings-as-errors \
  -target arm64-apple-macos13.0 \
  -o bin/.ask-away-arm64 \
  src/*.swift

echo "building x86_64..."
swiftc -O -swift-version 6 -warnings-as-errors \
  -target x86_64-apple-macos13.0 \
  -o bin/.ask-away-x86_64 \
  src/*.swift

lipo -create \
  -output "$out" \
  bin/.ask-away-arm64 \
  bin/.ask-away-x86_64

rm -f bin/.ask-away-arm64 bin/.ask-away-x86_64

# Ad-hoc signature: runs locally with no identity required; the release
# pipeline signs the same way.
codesign --force --sign - "$out"

echo "built $out:"
lipo -info "$out"
