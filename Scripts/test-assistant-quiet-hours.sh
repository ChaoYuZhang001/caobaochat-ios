#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=$(mktemp -d -t caobao-quiet-hours-tests)
trap 'rm -r "$BUILD_DIR"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -target x86_64-apple-macosx13.0 -parse-as-library \
  "$ROOT/Caobao/Services/AssistantLocalization.swift" \
  "$ROOT/Caobao/Services/AssistantQuietHours.swift" \
  "$ROOT/Tests/AssistantQuietHoursTests.swift" \
  -o "$BUILD_DIR/quiet-hours-tests"
"$BUILD_DIR/quiet-hours-tests"
