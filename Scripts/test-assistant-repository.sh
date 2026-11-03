#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=$(mktemp -d -t caobao-repository-build)
trap 'rm -r "$BUILD_DIR"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -parse-as-library \
  "$ROOT/Caobao/Services/AssistantLocalization.swift" \
    "$ROOT/Caobao/Services/AssistantQuietHours.swift" \
    "$ROOT/Caobao/Services/AssistantLocalRepository.swift" \
  "$ROOT/Caobao/Services/AssistantTaskToolReceipt.swift" \
    "$ROOT/Tests/AssistantLocalRepositoryTests.swift" \
    -o "$BUILD_DIR/assistant-repository-tests"
"$BUILD_DIR/assistant-repository-tests"
