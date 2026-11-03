#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=$(mktemp -d -t caobao-preferences-tests)
trap 'rm -r "$BUILD_DIR"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -parse-as-library \
  "$ROOT/Caobao/Services/AssistantLocalization.swift" \
  "$ROOT/Caobao/Services/AssistantPreferences.swift" \
  "$ROOT/Tests/AssistantPreferencesTests.swift" \
  -o "$BUILD_DIR/preferences-tests"
"$BUILD_DIR/preferences-tests"
