#!/bin/zsh
# Records an Instruments "Animation Hitches" trace while a Debug build of Bosk folds the
# sidebar and switches tabs by itself (PerfHarness), then prints hitches that happen
# during Bosk's own animations. Usage: scripts/measure-hitches.sh [path/to/Bosk.app]
set -euo pipefail
app=$(cd "${1:-build/Build/Products/Debug/Bosk.app}" && pwd)  # xctrace needs an absolute path
out=$(mktemp -d)/hitches.trace
pkill -x Bosk || true
while pgrep -x Bosk >/dev/null; do :; done
xcrun xctrace record --template 'Animation Hitches' --instrument 'Points of Interest' \
  --time-limit 16s --output "$out" --launch -- "$app/Contents/MacOS/Bosk" -BoskPerfTest YES || true
# xctrace exits with 54 when the time limit stops the launched app; check the trace instead.
[[ -d "$out" ]] || { echo "No trace was recorded." >&2; exit 1; }
python3 "$(dirname "$0")/summarize-hitches.py" "$out"
