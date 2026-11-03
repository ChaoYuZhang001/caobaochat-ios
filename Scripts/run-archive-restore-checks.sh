#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=$(mktemp -d -t caobao-archive-restore)
trap 'rm -r "$BUILD_DIR"' EXIT HUP INT TERM
xcrun swiftc -lsqlite3 -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -parse-as-library \
  "$ROOT/Caobao/Services/AssistantLocalization.swift" \
  "$ROOT/Caobao/Services/AssistantOwnerIdentity.swift" \
  "$ROOT/Caobao/Services/AssistantMedia.swift" \
  "$ROOT/Caobao/Services/AssistantProtocol.swift" \
  "$ROOT/Caobao/Services/AssistantTaskTools.swift" \
  "$ROOT/Caobao/Services/AssistantTaskToolReceipt.swift" \
  "$ROOT/Caobao/Services/AssistantChatArchive.swift" \
  "$ROOT/Caobao/Services/AssistantChatDatabase.swift" \
  "$ROOT/Tests/AssistantArchiveRestoreTests.swift" \
  -o "$BUILD_DIR/archive-restore-tests"
"$BUILD_DIR/archive-restore-tests"
