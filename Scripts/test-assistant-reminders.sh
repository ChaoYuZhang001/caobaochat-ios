#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=$(mktemp -d -t caobao-reminders-build)
trap 'rm -r "$BUILD_DIR"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -D ASSISTANT_REMINDER_POLICY_ONLY -parse-as-library \
  "$ROOT/Caobao/Services/AssistantLocalization.swift" \
  "$ROOT/Caobao/Services/AssistantOwnerIdentity.swift" \
    "$ROOT/Caobao/Services/AssistantQuietHours.swift" \
    "$ROOT/Caobao/Services/AssistantLocalRepository.swift" \
  "$ROOT/Caobao/Services/AssistantTaskToolReceipt.swift" \
    "$ROOT/Caobao/Services/AssistantReminderCoordinator.swift" \
    "$ROOT/Tests/AssistantReminderPolicyTests.swift" \
    -o "$BUILD_DIR/assistant-reminder-tests"
"$BUILD_DIR/assistant-reminder-tests"
