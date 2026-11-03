#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=$(mktemp -d -t caobao-chat-viewport-tests)
trap 'rm -r "$BUILD_DIR"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -parse-as-library \
  "$ROOT/Caobao/Services/AssistantChatViewport.swift" \
  "$ROOT/Tests/AssistantChatViewportTests.swift" \
  -o "$BUILD_DIR/viewport-tests"
"$BUILD_DIR/viewport-tests"
