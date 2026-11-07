#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=$(mktemp -d -t caobao-deep-link-build)
trap 'rm -r "$BUILD_DIR"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -parse-as-library \
  "$ROOT/Caobao/Services/AssistantOwnerIdentity.swift" \
  "$ROOT/Tests/AssistantDeepLinkTests.swift" \
  -o "$BUILD_DIR/assistant-deep-link-tests"
"$BUILD_DIR/assistant-deep-link-tests"
