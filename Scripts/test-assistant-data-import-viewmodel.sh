#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=$(mktemp -d -t caobao-import-viewmodel-tests)
trap 'rm -r "$BUILD_DIR"' EXIT HUP INT TERM
xcrun swiftc -lsqlite3 -swift-version 5 -target x86_64-apple-macosx13.0 -parse-as-library \
  "$ROOT/Caobao/Services/AssistantLocalization.swift" \
  "$ROOT/Caobao/Services/AssistantModelPreferences.swift" \
  "$ROOT/Caobao/Services/AssistantMedia.swift" \
  "$ROOT/Caobao/Services/AssistantProtocol.swift" \
  "$ROOT/Caobao/Services/AssistantTaskTools.swift" \
  "$ROOT/Caobao/Services/AssistantQuietHours.swift" \
  "$ROOT/Caobao/Services/AssistantLocalRepository.swift" \
  "$ROOT/Caobao/Services/AssistantTaskToolReceipt.swift" \
  "$ROOT/Caobao/Services/AssistantTaskToolExecution.swift" \
  "$ROOT/Caobao/Services/AssistantTaskToolCapabilityProbe.swift" \
  "$ROOT/Caobao/Services/AssistantChatArchive.swift" \
  "$ROOT/Caobao/Services/AssistantChatDatabase.swift" \
  "$ROOT/Caobao/Services/AssistantArchiveOperationGate.swift" \
  "$ROOT/Caobao/Services/AssistantConversationClient.swift" \
  "$ROOT/Caobao/Services/AssistantDataExport.swift" \
  "$ROOT/Caobao/Services/AssistantDataImport.swift" \
  "$ROOT/Caobao/Services/AssistantCloudMemorySync.swift" \
  "$ROOT/Caobao/Services/AssistantCloudConversationSync.swift" \
  "$ROOT/Tests/ChatViewModelTestSupport.swift" \
  "$ROOT/Caobao/ViewModels/ChatViewModel.swift" \
  "$ROOT/Tests/AssistantDataImportViewModelTests.swift" \
  -o "$BUILD_DIR/data-import-viewmodel-tests"
"$BUILD_DIR/data-import-viewmodel-tests"
