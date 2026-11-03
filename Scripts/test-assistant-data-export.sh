#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=$(mktemp -d -t caobao-data-export-tests)
trap 'rm -r "$BUILD_DIR"' EXIT HUP INT TERM
xcrun swiftc -lsqlite3 -swift-version 5 -target x86_64-apple-macosx13.0 -parse-as-library \
  "$ROOT/Caobao/Services/AssistantLocalization.swift" \
  "$ROOT/Caobao/Services/AssistantMedia.swift" \
  "$ROOT/Caobao/Services/AssistantProtocol.swift" \
  "$ROOT/Caobao/Services/AssistantTaskTools.swift" \
  "$ROOT/Caobao/Services/AssistantChatArchive.swift" \
  "$ROOT/Caobao/Services/AssistantChatDatabase.swift" \
  "$ROOT/Caobao/Services/AssistantQuietHours.swift" \
  "$ROOT/Caobao/Services/AssistantLocalRepository.swift" \
  "$ROOT/Caobao/Services/AssistantTaskToolReceipt.swift" \
  "$ROOT/Caobao/Services/AssistantDataExport.swift" \
  "$ROOT/Tests/AssistantDataExportTests.swift" \
  -o "$BUILD_DIR/data-export-tests"
"$BUILD_DIR/data-export-tests"
