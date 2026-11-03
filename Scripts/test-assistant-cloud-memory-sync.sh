#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=$(mktemp -d -t caobao-cloud-memory-sync-tests)
trap 'rm -r "$BUILD_DIR"' EXIT HUP INT TERM
xcrun swiftc -lsqlite3 -swift-version 5 -target x86_64-apple-macosx13.0 -parse-as-library \
  "$ROOT/Caobao/Services/AssistantLocalization.swift" \
  "$ROOT/Caobao/Services/AssistantMedia.swift" \
  "$ROOT/Caobao/Services/AssistantProtocol.swift" \
  "$ROOT/Caobao/Services/AssistantQuietHours.swift" \
  "$ROOT/Caobao/Services/AssistantTaskTools.swift" \
  "$ROOT/Caobao/Services/AssistantTaskToolReceipt.swift" \
  "$ROOT/Caobao/Services/AssistantTaskToolExecution.swift" \
  "$ROOT/Caobao/Services/AssistantTaskToolCapabilityProbe.swift" \
  "$ROOT/Caobao/Services/AssistantLocalRepository.swift" \
  "$ROOT/Caobao/Services/AssistantCloudMemorySync.swift" \
  "$ROOT/Tests/AssistantCloudMemorySyncTests.swift" \
  -o "$BUILD_DIR/cloud-memory-sync-tests"
"$BUILD_DIR/cloud-memory-sync-tests"
