#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=$(mktemp -d -t caobao-connection-tests)
trap 'rm -r "$BUILD_DIR"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -target x86_64-apple-macosx13.0 -parse-as-library \
  "$ROOT/Caobao/Services/AssistantLocalization.swift" \
  "$ROOT/Caobao/Services/AssistantMedia.swift" \
  "$ROOT/Caobao/Services/AssistantProtocol.swift" \
  "$ROOT/Caobao/Services/AssistantTaskTools.swift" \
  "$ROOT/Caobao/Services/AssistantConnectionProbe.swift" \
  "$ROOT/Tests/AssistantConnectionProbeTests.swift" \
  -o "$BUILD_DIR/connection-tests"
"$BUILD_DIR/connection-tests"
