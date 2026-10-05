#!/usr/bin/env bash
# microSD benchmark for the Kria KV260. Runs on the board as the normal user (needs sudo).
# Usage: bench.sh <label> [runs]      e.g. bench.sh samsung-pro-plus 3
# Writes results to ~/sdbench-results/<label>/
set -euo pipefail

LABEL=${1:?label}; RUNS=${2:-3}
OUT=$HOME/sdbench-results/$LABEL
WORK=$HOME/sdbench-work                 # on the card (root filesystem)
RAM=/dev/shm/sdbench                    # tmpfs, so the "other side" of a copy is never the card
HERE=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$OUT" "$WORK" "$RAM"
trap 'rm -rf "$WORK" "$RAM"' EXIT

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$OUT/bench.log"; }
drop() { sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null; sleep 2; }
now() { date +%s.%N; }

# --- sanity ---------------------------------------------------------------
"$HERE/card-info.sh" > "$OUT/card.json"
MODE=$(python3 -c "import json;print(json.load(open('$OUT/card.json'))['mode']['timing'])")
log "card: $(python3 -c "import json;c=json.load(open('$OUT/card.json'));print(c['manufacturer'],c['name'],c['size_gib'],'GiB',c['date'])")"
log "mode: $MODE"
[[ "$MODE" == *SDR104* ]] || { log "ERROR: not in SDR104 (see Part 1). Aborting."; exit 1; }
[[ "$(findmnt -no SOURCE /)" == /dev/mmcblk1p2 ]] || { log "ERROR: / is not on mmcblk1p2"; exit 1; }
command -v fio >/dev/null || { log "ERROR: fio missing"; exit 1; }

log "fstrim before start"; sudo fstrim -v / | tee -a "$OUT/bench.log"
drop

# --- fio ------------------------------------------------------------------
# direct=1, psync, iodepth=1 everywhere: one request at a time, no cache, like a real OS.
fio_common=(--ioengine=psync --iodepth=1 --numjobs=1 --direct=1 --group_reporting
            --output-format=json --directory="$WORK")

declare -A JOBS=(
  [seq-read]="--rw=read      --bs=1M --size=2G"
  [seq-write]="--rw=write    --bs=1M --size=2G"
  [rand-read-4k]="--rw=randread  --bs=4k --size=256M --runtime=30 --time_based"
  [rand-write-4k]="--rw=randwrite --bs=4k --size=256M --runtime=30 --time_based"
  [rand-write-4k-fsync]="--rw=randwrite --bs=4k --size=128M --runtime=30 --time_based --fsync=1"
  [mixed-4k-70-30]="--rw=randrw --rwmixread=70 --bs=4k --size=256M --runtime=45 --time_based"
)
ORDER=(seq-write seq-read rand-read-4k rand-write-4k rand-write-4k-fsync mixed-4k-70-30)

for run in $(seq 1 "$RUNS"); do
  for job in "${ORDER[@]}"; do
    drop
    log "fio $job run $run/$RUNS"
    # shellcheck disable=SC2086
    fio --name="$job" "${fio_common[@]}" ${JOBS[$job]} > "$OUT/fio-$job-run$run.json"
    rm -f "$WORK/$job".*
  done
done

# --- real task: one large file -------------------------------------------
log "preparing 1 GiB random file in RAM"
head -c 1G /dev/urandom > "$RAM/big.bin"
for run in $(seq 1 "$RUNS"); do
  drop
  t0=$(now); dd if="$RAM/big.bin" of="$WORK/big.bin" bs=1M conv=fdatasync status=none; t1=$(now)
  drop
  t2=$(now); cat "$WORK/big.bin" > /dev/null; t3=$(now)
  rm -f "$WORK/big.bin"; sync
  python3 -c "import json;print(json.dumps({'write_s':$t1-$t0,'read_s':$t3-$t2,'bytes':2**30}))" \
    > "$OUT/task-largefile-run$run.json"
  log "largefile run $run: write $(python3 -c "print(round(2**30/($t1-$t0)/1e6,1))") MB/s, read $(python3 -c "print(round(2**30/($t3-$t2)/1e6,1))") MB/s"
done
rm -f "$RAM/big.bin"

# --- real task: many small files -----------------------------------------
# Real files, already on every card: the Python standard library and packages.
SRC=(/usr/lib/python3 /usr/lib/python3.10)
log "preparing small-files tarball in RAM from ${SRC[*]}"
tar -cf "$RAM/small.tar" -C / "${SRC[@]#/}"
NFILES=$(tar -tf "$RAM/small.tar" | grep -vc '/$')
NBYTES=$(stat -c %s "$RAM/small.tar")
log "small.tar: $NFILES files, $((NBYTES/2**20)) MiB"
for run in $(seq 1 "$RUNS"); do
  drop
  t0=$(now); tar -xf "$RAM/small.tar" -C "$WORK"; sync; t1=$(now)
  drop
  t2=$(now); rm -rf "$WORK/usr"; sync; t3=$(now)
  python3 -c "import json;print(json.dumps({'extract_s':$t1-$t0,'delete_s':$t3-$t2,'files':$NFILES,'bytes':$NBYTES}))" \
    > "$OUT/task-smallfiles-run$run.json"
  log "smallfiles run $run: extract $(printf %.1f "$(echo "$t1-$t0" | bc)") s, delete $(printf %.1f "$(echo "$t3-$t2" | bc)") s"
done
rm -f "$RAM/small.tar"

log "done. results in $OUT"
