#!/bin/bash
# Transcript tests: builds a harness from the app source and checks corrections and merge output.
# ./tests/run.sh            fail on any difference
# ./tests/run.sh --update   accept the merge's new output into merge_golden.tsv (review the printed changes first)
set -e
cd "$(dirname "$0")"
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
python3 mkharness.py ../swift-cli "$PWD/../scripts/vocabulary.txt" "$BUILD/harness.swift"
swiftc -O "$BUILD/harness.swift" -o "$BUILD/harness"
python3 check.py "$BUILD/harness" "$@"
python3 test_cases.py
python3 test_learn_edits.py
python3 test_vocabulary.py "$BUILD"
node --test ../mcp/server.test.mjs
