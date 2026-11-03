#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=$(mktemp -d -t caobao-identity-tests)
trap 'rm -r "$BUILD_DIR"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -target x86_64-apple-macosx13.0 -parse-as-library \
  "$ROOT/Caobao/Services/AssistantLocalization.swift" \
  "$ROOT/Caobao/Services/AssistantOwnerIdentity.swift" \
  "$ROOT/Caobao/Services/AssistantDeletionNotice.swift" \
  "$ROOT/Caobao/Services/AssistantIdentityClient.swift" \
  "$ROOT/Tests/AssistantIdentityClientTests.swift" \
  -o "$BUILD_DIR/identity-tests"
"$BUILD_DIR/identity-tests"
