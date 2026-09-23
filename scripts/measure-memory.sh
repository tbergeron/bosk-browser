#!/bin/zsh
# Prints the total memory footprint of a running Debug build of Bosk and its WebKit
# helper processes (web content, GPU, networking), without double-counting shared memory.
# The Debug build writes the process IDs to ~/Library/Caches/Bosk/processes.json.
set -euo pipefail
report=~/Library/Caches/Bosk/processes.json
[[ -f $report ]] || { echo "No process report. Run a Debug build of Bosk first." >&2; exit 1; }
pids=($(python3 -c "
import json; r = json.load(open('$report'))
print(' '.join(str(p) for p in [r['app']] + r['web'] + r['gpu'] + r['network']))"))
python3 -c "
import json; r = json.load(open('$report'))
print(f\"tabs: {r['tabs']}, awake: {r['awakeTabs']}, web content processes: {len(r['web'])}, launch: {r.get('launchMilliseconds', -1)} ms\")"
args=()
for pid in $pids; do args+=(-p $pid); done
footprint $args 2>/dev/null | grep -E "Footprint:" | sed "s/ *(16384 bytes per page)//" | sort -u
