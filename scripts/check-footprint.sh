#!/usr/bin/env bash
# Physical footprint and idle CPU / wakeups of a running hop.
# Usage: scripts/check-footprint.sh [seconds]
set -euo pipefail

secs="${1:-30}"
pid=$(pgrep -x hop) || { echo "hop is not running"; exit 1; }

footprint "$pid" 2>/dev/null | grep -E 'Footprint|phys_footprint' | head -3
echo "sampling ${secs}s of idle CPU and wakeups…"
top -l 2 -s "$secs" -pid "$pid" -stats pid,cpu,idlew,mem | tail -1
