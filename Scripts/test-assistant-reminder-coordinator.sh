#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=$(mktemp -d -t caobao-reminder-coordinator-build)
trap 'rm -r "$BUILD_DIR"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -parse-as-library \
  "$ROOT/Caobao/Services/AssistantLocalization.swift" \
  "$ROOT/Caobao/Services/AssistantOwnerIdentity.swift" \
    "$ROOT/Caobao/Services/AssistantQuietHours.swift" \
    "$ROOT/Caobao/Services/AssistantLocalRepository.swift" \
  "$ROOT/Caobao/Services/AssistantTaskToolReceipt.swift" \
    "$ROOT/Caobao/Services/AssistantReminderCoordinator.swift" \
    "$ROOT/Tests/AssistantReminderCoordinatorTests.swift" \
    -o "$BUILD_DIR/assistant-reminder-coordinator-tests"
"$BUILD_DIR/assistant-reminder-coordinator-tests"
