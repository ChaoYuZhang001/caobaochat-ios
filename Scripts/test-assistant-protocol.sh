#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=$(mktemp -d -t caobao-protocol-tests)
trap 'rm -r "$BUILD_DIR"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -target x86_64-apple-macosx13.0 -parse-as-library \
  "$ROOT/Caobao/Services/AssistantLocalization.swift" \
  "$ROOT/Caobao/Services/AssistantMedia.swift" \
  "$ROOT/Caobao/Services/AssistantProtocol.swift" \
  "$ROOT/Caobao/Services/AssistantTaskTools.swift" \
  "$ROOT/Tests/AssistantProtocolTests.swift" \
  -o "$BUILD_DIR/protocol-tests"
"$BUILD_DIR/protocol-tests"
