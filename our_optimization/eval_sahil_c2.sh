#!/bin/bash
# JBD2 ASYNC BITMAP PREFETCH — Evaluation Script for SAHIL (Candidate 2)
#
# Patch: our_optimization/mballoc-async-prefetch.patch
# Spec:  docs/superpowers/specs/2026-04-22-ext4-async-bitmap-prefetch-design.md
#
# Run TWICE:
#   Step 1 (STOCK):    sudo bash eval_sahil_c2.sh    # on an unpatched 6.1.4 kernel
#   Step 2 (PATCHED):  sudo bash eval_sahil_c2.sh    # on the cs614-c2-patched kernel
#
# The script auto-detects which kernel you are on by checking the TODO
# comment in the source tree (present on stock, absent on patched).

set -euo pipefail

CONTRIBUTOR="sahil"

FALLOC_SIZE_MB=256
FALLOC_ITERATIONS=32
FALLOC_REPEATS=3
FIO_SIZE="2G"
FIO_BS="1M"
FIO_JOBS=4
FIO_REPEATS=5
IMG_SIZE_MB=16384
IMG_FILE="/tmp/c2_eval_${CONTRIBUTOR}.img"
MOUNT_POINT="/mnt/c2_eval_${CONTRIBUTOR}"

##############################################################################
# Kernel detection — STOCK vs PATCHED
##############################################################################
KERNEL_VER="$(uname -r)"
SRC_MBALLOC="$(find /home /root -name "mballoc.c" -path "*/ext4/*" 2>/dev/null | head -1)"

if [ -n "$SRC_MBALLOC" ]; then
    # Our patch ADDS "ext4_bitmap_init_work" struct. Present => patched.
    if grep -q "struct ext4_bitmap_init_work" "$SRC_MBALLOC"; then
        RUN_LABEL="PATCHED"
    else
        RUN_LABEL="STOCK"
    fi
else
    RUN_LABEL="${LABEL:-UNKNOWN}"
    echo "WARNING: kernel source not found at expected path."
    echo "  Re-run with:  sudo LABEL=STOCK bash $0"
    echo "           or:  sudo LABEL=PATCHED bash $0"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULT_DIR="$SCRIPT_DIR/eval_results_c2/$CONTRIBUTOR/${RUN_LABEL}_${KERNEL_VER}"
mkdir -p "$RESULT_DIR"

echo "========================================================"
echo " Contributor : $CONTRIBUTOR"
echo " Kernel      : $RUN_LABEL ($KERNEL_VER)"
echo " Results     : $RESULT_DIR"
echo "========================================================"

[ "$(id -u)" = "0" ] || { echo "ERROR: Run as root:  sudo bash $0"; exit 1; }
command -v fio >/dev/null || { echo "ERROR: fio not found.  sudo apt install fio"; exit 1; }
HAS_PERF=0
command -v perf >/dev/null && HAS_PERF=1 \
    || echo "NOTE: perf not found - measurement (iii) skipped.  sudo apt install linux-tools-common linux-tools-$(uname -r)"

##############################################################################
# System info
##############################################################################
{
    echo "Contributor: $CONTRIBUTOR"
    echo "Date:        $(date -Iseconds)"
    echo "Kernel:      $(uname -r)"
    echo "Run label:   $RUN_LABEL"
    echo "CPU:         $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
    echo "Cores:       $(nproc)"
    echo "RAM:         $(free -h | awk '/^Mem/{print $2}')"
    echo "Storage:"
    lsblk -d -o NAME,SIZE,ROTA,TRAN 2>/dev/null | grep -v NAME | head -5
    echo "fio:         $(fio --version)"
    echo "Workload:    FALLOC ${FALLOC_SIZE_MB}Mx${FALLOC_ITERATIONS}x${FALLOC_REPEATS}reps | FIO ${FIO_SIZE} bs=${FIO_BS} j${FIO_JOBS} x${FIO_REPEATS}reps"
} | tee "$RESULT_DIR/system_info.txt"

##############################################################################
# CPU governor -> performance (bare-metal: reduces noise; VM: no-op)
##############################################################################
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$f" 2>/dev/null || true
done
[ -e /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ] && echo "CPU governor: performance"

cleanup() {
    umount "$MOUNT_POINT" 2>/dev/null || true
    [ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

##############################################################################
# (i) fallocate microbenchmark — per-allocation latency
##############################################################################
echo ""
echo "--- (i) fallocate latency ---"
LATENCIES="$RESULT_DIR/fallocate_latencies_us.txt"
: > "$LATENCIES"
echo "repeat iter latency_us" > "$LATENCIES"

for r in $(seq 1 $FALLOC_REPEATS); do
    echo "Repeat $r/$FALLOC_REPEATS"
    rm -f "$IMG_FILE"
    dd if=/dev/zero of="$IMG_FILE" bs=1M count=$IMG_SIZE_MB status=none
    LOOP=$(losetup --find --show "$IMG_FILE")
    mkfs.ext4 -F -q -O fast_commit "$LOOP"
    mkdir -p "$MOUNT_POINT"
    mount "$LOOP" "$MOUNT_POINT"
    sync && echo 3 > /proc/sys/vm/drop_caches && sleep 1

    for i in $(seq 1 $FALLOC_ITERATIONS); do
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

python3 <<PYEOF
import statistics
data = [int(l.split()[-1]) for l in open("$LATENCIES") if l[0].isdigit()]
d = sorted(data); n = len(d)
print(f"  n={n}  mean={statistics.mean(d):.0f}us  p50={d[n//2]}us  p95={d[int(n*0.95)]}us  p99={d[int(n*0.99)]}us  stdev={statistics.stdev(d):.0f}us")
PYEOF

##############################################################################
# (ii) fio throughput — 5 repeats, fresh fs each
##############################################################################
echo ""
echo "--- (ii) fio 1M sequential write throughput ---"
FIO_OUT="$RESULT_DIR/fio_repeats.txt"
echo "repeat iops bw_MiB runtime_ms" > "$FIO_OUT"

for r in $(seq 1 $FIO_REPEATS); do
    echo "Repeat $r/$FIO_REPEATS"
    rm -f "$IMG_FILE"
    dd if=/dev/zero of="$IMG_FILE" bs=1M count=$IMG_SIZE_MB status=none
    LOOP=$(losetup --find --show "$IMG_FILE")
    mkfs.ext4 -F -q -O fast_commit "$LOOP"
    mount "$LOOP" "$MOUNT_POINT"
    sync && echo 3 > /proc/sys/vm/drop_caches && sleep 1

    OUT="$RESULT_DIR/fio_repeat${r}.txt"
    fio --name=thrput$r \
        --directory="$MOUNT_POINT" \
        --rw=write --bs=$FIO_BS --size=$FIO_SIZE \
        --ioengine=sync --numjobs=$FIO_JOBS \
        --group_reporting --output="$OUT" 2>&1 | tail -1

    IOPS=$(grep -oE "IOPS=[0-9.]+k?" "$OUT" | head -1 | sed 's/IOPS=//')
    BW=$(grep -oE "BW=[0-9.]+MiB" "$OUT" | head -1 | sed 's/BW=//;s/MiB//')
    RT=$(grep -oE "[0-9]+msec" "$OUT" | head -1 | sed 's/msec//')
    echo "$r $IOPS $BW $RT" >> "$FIO_OUT"
    echo "  iops=$IOPS bw=${BW}MiB/s runtime=${RT}ms"

    umount "$MOUNT_POINT"
    losetup -d "$LOOP"
    unset LOOP
done

python3 <<PYEOF
import statistics
lines = open("$FIO_OUT").readlines()[1:]
bws = [float(l.split()[2]) for l in lines]
print(f"  BW: mean={statistics.mean(bws):.1f} MiB/s, stdev={statistics.stdev(bws):.1f} MiB/s, cv={100*statistics.stdev(bws)/statistics.mean(bws):.1f}%")
PYEOF

##############################################################################
# (iii) perf sched — allocator sleep time (single run, optional)
##############################################################################
if [ "$HAS_PERF" = "1" ]; then
    echo ""
    echo "--- (iii) perf sched ---"
    rm -f "$IMG_FILE"
    dd if=/dev/zero of="$IMG_FILE" bs=1M count=$IMG_SIZE_MB status=none
    LOOP=$(losetup --find --show "$IMG_FILE")
    mkfs.ext4 -F -q -O fast_commit "$LOOP"
    mount "$LOOP" "$MOUNT_POINT"
    sync && echo 3 > /proc/sys/vm/drop_caches && sleep 1

    perf sched record -a -o "$RESULT_DIR/perf.data" -- \
        fio --name=psched --rw=write --bs=1M --size=2G --numjobs=4 \
            --directory="$MOUNT_POINT" --group_reporting \
            --output="$RESULT_DIR/fio_perf.txt" 2>&1 | tail -3

    perf sched latency -i "$RESULT_DIR/perf.data" > "$RESULT_DIR/perf_sched_latency.txt" 2>&1
    grep -E "ext4|kworker.*bitmap" "$RESULT_DIR/perf_sched_latency.txt" | head -5 || true

    umount "$MOUNT_POINT"
    losetup -d "$LOOP"
    unset LOOP
fi

echo ""
echo "=== Done. Results: $RESULT_DIR ==="
echo ""
echo "Push results:"
echo "  git add our_optimization/eval_results_c2/$CONTRIBUTOR/"
echo "  git commit -m 'results-c2: $CONTRIBUTOR bare-metal $RUN_LABEL'"
echo "  git push"
