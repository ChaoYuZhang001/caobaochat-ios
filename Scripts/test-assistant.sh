#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
for suite in quiet-hours repository cloud-memory-sync cloud-conversation-sync device-registration preferences markdown markdown-inline chat-viewport protocol task-tool-protocol database archive media reminders reminder-coordinator identity entitlements conversation localization models connection task-tool-capability task-tool-execution task-tool-export data-export backup-file-reader data-import archive-restore repository-restore data-import-viewmodel deletion deep-link chat-viewmodel; do
  printf '\nRunning assistant %s checks\n' "$suite"
  sh "$ROOT/Scripts/test-assistant-$suite.sh"
done
