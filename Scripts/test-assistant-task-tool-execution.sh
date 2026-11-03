#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=$(mktemp -d -t caobao-task-tool-execution-tests)
trap 'rm -r "$BUILD_DIR"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -parse-as-library \
  "$ROOT/Caobao/Services/AssistantLocalization.swift" \
  "$ROOT/Caobao/Services/AssistantMedia.swift" \
  "$ROOT/Caobao/Services/AssistantProtocol.swift" \
  "$ROOT/Caobao/Services/AssistantTaskTools.swift" \
  "$ROOT/Caobao/Services/AssistantTaskToolReceipt.swift" \
  "$ROOT/Caobao/Services/AssistantQuietHours.swift" \
  "$ROOT/Caobao/Services/AssistantLocalRepository.swift" \
  "$ROOT/Caobao/Services/AssistantTaskToolExecution.swift" \
  "$ROOT/Tests/AssistantTaskToolExecutionTests.swift" \
  -o "$BUILD_DIR/tests"
"$BUILD_DIR/tests"
