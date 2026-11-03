#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=$(mktemp -d -t caobao-markdown-inline-build)
trap 'rm -r "$BUILD_DIR"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -parse-as-library \
  "$ROOT/Caobao/Services/AssistantMarkdownInline.swift" \
  "$ROOT/Tests/AssistantMarkdownInlineTests.swift" \
  -o "$BUILD_DIR/assistant-markdown-inline-tests"
"$BUILD_DIR/assistant-markdown-inline-tests"
