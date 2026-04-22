#!/bin/bash
# Focused fio throughput benchmark — 5 repeats, no perf overhead.
# Designed to confirm or refute the ~10% throughput delta spotted in the
# primary benchmark.
#
# Usage: sudo bash bench_fio_throughput.sh

set -euo pipefail

KERNEL="$(uname -r)"
OUT_DIR="$(dirname "$0")/eval_results_c2/${KERNEL}"
mkdir -p "$OUT_DIR"

IMG_FILE="/tmp/c2_fio.img"
MOUNT_POINT="/mnt/c2_fio"
IMG_SIZE_MB=16384
FIO_SIZE="2G"
FIO_BS="1M"
FIO_JOBS=4
REPEATS=5

[ "$(id -u)" = "0" ] || { echo "Run as root"; exit 1; }

echo "=== fio throughput: $KERNEL ($REPEATS repeats) ==="

cleanup() {
    umount "$MOUNT_POINT" 2>/dev/null || true
    [ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

RESULTS="$OUT_DIR/fio_throughput_repeats.txt"
: > "$RESULTS"
echo "repeat iops bw_MiB runtime_ms" > "$RESULTS"

for r in $(seq 1 $REPEATS); do
    echo "-- Repeat $r/$REPEATS --"
    rm -f "$IMG_FILE"
    dd if=/dev/zero of="$IMG_FILE" bs=1M count=$IMG_SIZE_MB status=none
    LOOP=$(losetup --find --show "$IMG_FILE")
    mkfs.ext4 -F -q -O fast_commit "$LOOP"
    mkdir -p "$MOUNT_POINT"
    mount "$LOOP" "$MOUNT_POINT"
    sync && echo 3 > /proc/sys/vm/drop_caches && sleep 1

    OUT="$OUT_DIR/fio_repeat${r}.txt"
    fio --name=thrput$r \
        --directory="$MOUNT_POINT" \
        --rw=write --bs=$FIO_BS --size=$FIO_SIZE \
        --ioengine=sync --numjobs=$FIO_JOBS \
        --group_reporting \
        --output="$OUT" \
        --output-format=normal 2>&1 | tail -1

    IOPS=$(grep -oE "IOPS=[0-9.]+k?" "$OUT" | head -1 | sed 's/IOPS=//')
    BW=$(grep -oE "BW=[0-9.]+MiB" "$OUT" | head -1 | sed 's/BW=//;s/MiB//')
    RT=$(grep -oE "[0-9]+msec" "$OUT" | head -1 | sed 's/msec//')
    echo "$r $IOPS $BW $RT" >> "$RESULTS"
    echo "  iops=$IOPS bw=${BW}MiB/s runtime=${RT}ms"

    umount "$MOUNT_POINT"
    losetup -d "$LOOP"
    unset LOOP
done

echo ""
echo "=== Summary for $KERNEL ==="
python3 <<PYEOF
import statistics
lines = open("$RESULTS").readlines()[1:]
bws = [float(l.split()[2]) for l in lines]
iopss = [l.split()[1] for l in lines]
rts = [int(l.split()[3]) for l in lines]
# iops may have 'k' suffix
def toNum(s): return float(s.rstrip('k'))*1000 if s.endswith('k') else float(s)
iops_n = [toNum(i) for i in iopss]
print(f"BW      mean={statistics.mean(bws):.1f} MiB/s, stdev={statistics.stdev(bws):.1f}")
print(f"IOPS    mean={statistics.mean(iops_n):.0f}, stdev={statistics.stdev(iops_n):.0f}")
print(f"runtime mean={statistics.mean(rts):.0f} ms, stdev={statistics.stdev(rts):.0f}")
print(f"all bws: {bws}")
PYEOF
