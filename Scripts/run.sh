#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/build.sh debug
# A running copy would keep the notch: quit it so the fresh build is the one that starts.
if pgrep -x Notcher >/dev/null; then
    osascript -e 'tell application id "fr.notcher.app" to quit' >/dev/null 2>&1 || pkill -x Notcher || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Notcher >/dev/null || break; sleep 0.2; done
fi
open dist/Notcher.app
