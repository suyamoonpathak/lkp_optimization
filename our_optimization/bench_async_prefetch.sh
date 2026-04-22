#!/bin/bash
# Candidate 2 benchmark: async bitmap prefetch completion.
#
# Measures:
#   (i)  per-fallocate allocation latency (fresh-mount, cold cache)
#   (iii) allocator sleep time via perf sched
#   (iv) fio throughput during the perf-sched capture (macrobench, spec §4.4)
#
# Run on whichever kernel is booted; saves results tagged by kernel name.
#
# Usage: sudo bash bench_async_prefetch.sh

set -euo pipefail

KERNEL="$(uname -r)"
OUT_DIR="$(dirname "$0")/eval_results_c2/${KERNEL}"
mkdir -p "$OUT_DIR"

IMG_FILE="/tmp/c2_bench.img"
MOUNT_POINT="/mnt/c2_bench"
IMG_SIZE_MB=16384          # 16 GB
FALLOC_SIZE_MB=256
ITERATIONS=32
REPEATS=3

echo "=== Candidate 2 benchmark on $KERNEL ==="
echo "Results -> $OUT_DIR"

[ "$(id -u)" = "0" ] || { echo "Run as root"; exit 1; }
command -v fio >/dev/null || { echo "apt install fio"; exit 1; }
HAS_PERF=0
command -v perf >/dev/null && HAS_PERF=1 \
    || echo "NOTE: perf not found, skipping measurement (iii). apt install linux-tools-common linux-tools-$(uname -r)"

# CPU governor -> performance
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$f" 2>/dev/null || true
done

{
    echo "Date: $(date -Iseconds)"
    echo "Kernel: $KERNEL"
    echo "CPU: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
    echo "Cores: $(nproc)"
    echo "RAM: $(free -h | awk '/^Mem/{print $2}')"
} | tee "$OUT_DIR/system_info.txt"

cleanup() {
    umount "$MOUNT_POINT" 2>/dev/null || true
    [ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

##############################################################################
# (i) per-allocation latency: fresh mount -> fallocate loop
##############################################################################
echo ""
echo "--- Measurement (i): fallocate latency ---"

LATENCIES="$OUT_DIR/fallocate_latencies_us.txt"
: > "$LATENCIES"

for r in $(seq 1 $REPEATS); do
    echo "Repeat $r/$REPEATS..."
    rm -f "$IMG_FILE"
    dd if=/dev/zero of="$IMG_FILE" bs=1M count=$IMG_SIZE_MB status=none
    LOOP=$(losetup --find --show "$IMG_FILE")
    mkfs.ext4 -F -q -O fast_commit "$LOOP"
    mkdir -p "$MOUNT_POINT"
    mount "$LOOP" "$MOUNT_POINT"
    sync && echo 3 > /proc/sys/vm/drop_caches && sleep 1

    for i in $(seq 1 $ITERATIONS); do
        rm -f "$MOUNT_POINT/f"
        T0=$(date +%s%N)
        fallocate -l ${FALLOC_SIZE_MB}M "$MOUNT_POINT/f"
        T1=$(date +%s%N)
        echo "$r $i $(( (T1 - T0) / 1000 ))" >> "$LATENCIES"
        sync
    done

    umount "$MOUNT_POINT"
    losetup -d "$LOOP"
    unset LOOP
done

echo "Latency data: $LATENCIES"
awk '{ s+=$3; n++ } END { if(n) printf "  mean = %.0f us (%d samples)\n", s/n, n }' "$LATENCIES"

##############################################################################
# (iii)+(iv) perf sched + fio throughput
##############################################################################
if [ "$HAS_PERF" = "1" ]; then
    echo ""
    echo "--- Measurement (iii)+(iv): perf sched + fio ---"

    rm -f "$IMG_FILE"
    dd if=/dev/zero of="$IMG_FILE" bs=1M count=$IMG_SIZE_MB status=none
    LOOP=$(losetup --find --show "$IMG_FILE")
    mkfs.ext4 -F -q -O fast_commit "$LOOP"
    mount "$LOOP" "$MOUNT_POINT"
    sync && echo 3 > /proc/sys/vm/drop_caches && sleep 1

    perf sched record -a -o "$OUT_DIR/perf.data" -- \
        fio --name=allocstall \
            --rw=write --bs=1M --size=2G --numjobs=4 \
            --directory="$MOUNT_POINT" --group_reporting \
            --output="$OUT_DIR/fio_perf.txt" 2>&1 | tail -5

    perf sched latency -i "$OUT_DIR/perf.data" > "$OUT_DIR/perf_sched_latency.txt" 2>&1

    echo "  fio results:"
    grep -E "IOPS=|BW=" "$OUT_DIR/fio_perf.txt" | head -2
    echo "  allocator in perf_sched_latency.txt (top hits):"
    grep -E "ext4|kworker.*bitmap" "$OUT_DIR/perf_sched_latency.txt" | head -5 || true

    umount "$MOUNT_POINT"
    losetup -d "$LOOP"
    unset LOOP
fi

echo ""
echo "=== Done. Kernel: $KERNEL. Results: $OUT_DIR ==="
