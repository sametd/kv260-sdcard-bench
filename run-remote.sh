#!/usr/bin/env bash
# Drive a full benchmark of the card currently in the KV260, from the PC.
# Usage: run-remote.sh <label> [host] [runs]
#   1. copies the scripts to the board
#   2. runs bench.sh
#   3. measures boot time over <runs> reboots
#   4. fetches everything into results/<label>/
set -euo pipefail

LABEL=${1:?label}; HOST=${2:-ubuntu@kria}; RUNS=${3:-3}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/results/$LABEL
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST")

wait_for_ssh() {
  local i
  for i in $(seq 1 90); do "${SSH[@]}" true 2>/dev/null && return 0; sleep 2; done
  echo "board did not come back" >&2; return 1
}

mkdir -p "$OUT"
wait_for_ssh
"${SSH[@]}" 'rm -rf ~/sdbench && mkdir -p ~/sdbench'
scp -q "$HERE/card-info.sh" "$HERE/bench.sh" "$HOST:sdbench/"
"${SSH[@]}" "chmod +x sdbench/*.sh && sdbench/bench.sh '$LABEL' '$RUNS'"

# boot time: reboot <runs> times, read systemd-analyze each time
for run in $(seq 1 "$RUNS"); do
  echo "reboot $run/$RUNS for boot timing"
  "${SSH[@]}" 'sudo systemctl reboot' || true
  sleep 20; wait_for_ssh
  # wait until the boot is fully finished, then record it
  "${SSH[@]}" 'until systemd-analyze time >/dev/null 2>&1; do sleep 2; done; sleep 5
    systemd-analyze time; systemd-analyze blame | head -15' > "$OUT/boot-run$run.txt"
  cat "$OUT/boot-run$run.txt" | head -1
done

scp -q -r "$HOST:sdbench-results/$LABEL/." "$OUT/"
echo "results in $OUT"
