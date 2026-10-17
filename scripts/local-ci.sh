#!/bin/bash
# Local CI for ask-away - run on mini (a real Mac with a WindowServer).
# Replaces the GitHub Actions macOS job (10x billing); same checks, same order.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== toolchain"
swiftc --version

echo "== build universal binary"
./build.sh

echo "== verify both architectures"
lipo -info bin/ask-away
lipo -info bin/ask-away | grep -q "x86_64 arm64"

echo "== smoke test --help"
bin/ask-away --help > /dev/null

echo "== smoke test usage errors"
if bin/ask-away --bogus 2>/dev/null; then
  echo "expected exit 1 for unknown flag" >&2
  exit 1
fi

echo "== smoke test give-up contract (real panel, real WindowServer)"
# `|| code=$?` keeps bash -e from aborting on the assignment:
# the substitution's exit status (3, the contract) would kill the
# step before the assertion runs.
code=0
out="$(bin/ask-away --title "ci: smoke" --text "unattended runner" \
  --buttons A B --give-up-after 2 --no-beep)" || code=$?
test "$out" = "GAVE-UP" -a "$code" = "3"

echo "== smoke test batch usage errors"
# No panel is built for these paths: malformed JSON and flag
# conflicts exit 1 with nothing on stdout, before any rendering.
if bin/ask-away --questions-file tests/fixtures/malformed.json 2>/dev/null; then
  echo "expected exit 1 for malformed questions file" >&2; exit 1
fi
if bin/ask-away --questions-file tests/fixtures/answers.json --title t 2>/dev/null; then
  echo "expected exit 1 for batch + single-question flag conflict" >&2; exit 1
fi

echo "== smoke test a full 3-question batch (scripted driver)"
# The sim driver injects clicks through the in-app event pipeline
# (NSApp.postEvent), which needs no Accessibility grant.
swiftc -O -swift-version 6 -target arm64-apple-macos13.0 \
  -o /tmp/askaway-sim $(ls src/*.swift | grep -v main.swift) tests/simdriver.swift
code=0
out="$(ASKAWAY_SIM=answer,answer,answer /tmp/askaway-sim --questions-file tests/fixtures/answers.json)" || code=$?
expected='{"results":[{"index":0,"status":"answered","answer":"Production"},{"index":1,"status":"answered","answer":"Yes"},{"index":2,"status":"answered","answer":"Add note"}],"stopped_at":3}'
test "$out" = "$expected" -a "$code" = "0"

echo "local-ci OK"
