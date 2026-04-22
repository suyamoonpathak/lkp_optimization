#!/bin/bash
# JBD2 Fast Commit Barrier Deferral — Reproducible Evaluation Script
#
# Run this on any machine with Linux 6.1.4-cs614-hacker installed.
# Run TWICE: once on stock kernel (before applying patch), once on patched kernel.
# Results go to ./eval_results/<kernel-version>/
#
# Usage:
#   sudo bash run_evaluation.sh [/dev/sdXN]
#
#   No argument  → uses a loop device on /tmp (works on any machine, VM or bare-metal)
#   /dev/sdXN    → uses a real partition (WARNING: destroys all data on it)

set -euo pipefail

##############################################################################
# Configuration — edit these if needed
##############################################################################
RESULT_DIR="$(pwd)/eval_results/$(uname -r)"
MOUNT_POINT="/mnt/jbd2_eval"
IMG_FILE="/tmp/jbd2_eval.img"
IMG_SIZE_MB=1024          # filesystem image size
FIO_RUNTIME=60            # seconds per fio run
FIO_SIZE="128M"           # per-job working set
FIO_BS="4k"
FIO_SEED=12345            # fixed seed — makes I/O pattern deterministic
PROBE_MODULE="$(dirname "$0")/../Project/jbd2_probe_module/jbd2_probe.ko"
# Fallback probe path
[ -f "$PROBE_MODULE" ] || PROBE_MODULE="$(find /home -name jbd2_probe.ko 2>/dev/null | head -1)"

##############################################################################
# Helpers
##############################################################################
die() { echo "ERROR: $*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1 (install with: apt install $2)"
}

drop_caches() {
    sync
    echo 3 > /proc/sys/vm/drop_caches
    sleep 1
}

fix_cpu_governor() {
    # Pin CPUs to performance governor to reduce measurement noise
    if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
        for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo performance > "$f" 2>/dev/null || true
        done
        echo "CPU governor: performance"
    else
        echo "WARNING: cpufreq not available (VM or no governor support) — noise may be higher"
    fi
}

restore_cpu_governor() {
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo powersave > "$f" 2>/dev/null || true
    done
}

##############################################################################
# Setup
##############################################################################
[ "$(id -u)" = "0" ] || die "Must run as root (sudo bash $0)"

require_cmd fio fio
require_cmd mkfs.ext4 e2fsprogs

echo "=== JBD2 Evaluation: $(uname -r) ==="
echo "Results → $RESULT_DIR"
mkdir -p "$RESULT_DIR"

# Save system info for reproducibility
{
    echo "=== System Info ==="
    echo "Date: $(date -Iseconds)"
    echo "Kernel: $(uname -r)"
    echo "Machine: $(uname -m)"
    echo "CPU: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
    echo "CPU cores: $(nproc)"
    echo "RAM: $(free -h | awk '/^Mem/{print $2}')"
    echo "fio: $(fio --version)"
    if [ -n "${1:-}" ]; then
        echo "Block device: $1"
        lsblk -o NAME,SIZE,ROTA,SCHED "$1" 2>/dev/null || true
    else
        echo "Block device: loop (${IMG_FILE})"
    fi
} | tee "$RESULT_DIR/system_info.txt"

# Probe module check
if [ -f "$PROBE_MODULE" ]; then
    echo "Probe module: $PROBE_MODULE"
else
    echo "WARNING: jbd2_probe.ko not found — skipping per-function latency measurement"
    echo "  Build it with: cd jbd2_probe_module && make"
    PROBE_MODULE=""
fi

fix_cpu_governor
trap restore_cpu_governor EXIT

##############################################################################
# Filesystem setup
##############################################################################
setup_loop() {
    dd if=/dev/zero of="$IMG_FILE" bs=1M count="$IMG_SIZE_MB" status=progress 2>&1
    BLOCK_DEV=$(losetup --find --show "$IMG_FILE")
    echo "Loop device: $BLOCK_DEV"
}

teardown_loop() {
    umount "$MOUNT_POINT" 2>/dev/null || true
    losetup -d "$BLOCK_DEV" 2>/dev/null || true
}

if [ -n "${1:-}" ]; then
    BLOCK_DEV="$1"
    umount "$BLOCK_DEV" 2>/dev/null || true
    trap 'umount "$MOUNT_POINT" 2>/dev/null || true' EXIT
else
    setup_loop
    trap teardown_loop EXIT
fi

mkdir -p "$MOUNT_POINT"

##############################################################################
# Single benchmark run
# Args: $1=label $2=ext4_mount_options $3=numjobs $4=rw_pattern
##############################################################################
run_one() {
    local label="$1" mount_opts="$2" numjobs="$3" rw="$4"
    local out="$RESULT_DIR/${label}"

    echo ""
    echo "--- Run: $label (mode=$mount_opts jobs=$numjobs rw=$rw) ---"

    # Fresh filesystem every run
    mkfs.ext4 -F -q "$BLOCK_DEV"
    mount -o "$mount_opts" "$BLOCK_DEV" "$MOUNT_POINT"
    drop_caches

    # Load probe module
    rmmod jbd2_probe 2>/dev/null || true
    if [ -n "$PROBE_MODULE" ]; then
        insmod "$PROBE_MODULE"
        echo 0 > /proc/jbd2_probe_stats   # reset counters
    fi

    # Run fio
    fio \
        --name="$label" \
        --directory="$MOUNT_POINT" \
        --rw="$rw" \
        --bs="$FIO_BS" \
        --size="$FIO_SIZE" \
        --ioengine=sync \
        --fsync=1 \
        --numjobs="$numjobs" \
        --group_reporting \
        --runtime="$FIO_RUNTIME" \
        --time_based \
        --randseed="$FIO_SEED" \
        --output="${out}_fio.txt" \
        --output-format=normal

    # Capture probe stats
    if [ -n "$PROBE_MODULE" ]; then
        cp /proc/jbd2_probe_stats "${out}_probe.txt"
    fi

    # Capture JBD2 run_stats from dmesg (if tracepoint available)
    dmesg | grep jbd2_run_stats > "${out}_runstats.txt" 2>/dev/null || true

    umount "$MOUNT_POINT"
    drop_caches

    # Print summary
    echo "  fio IOPS:  $(grep 'IOPS=' "${out}_fio.txt" | head -1 | grep -o 'IOPS=[^,]*')"
    echo "  fio BW:    $(grep 'BW=' "${out}_fio.txt" | head -1 | grep -o 'BW=[^,)]*')"
    echo "  fio lat:   $(grep 'avg=' "${out}_fio.txt" | grep 'clat\|lat (' | head -1)"
    if [ -f "${out}_probe.txt" ]; then
        echo "  commit latency: $(grep jbd2_journal_commit "${out}_probe.txt")"
    fi
}

##############################################################################
# Benchmark matrix
# These cover the claims made in the paper:
#   1. Concurrent fsync workload (where the optimization helps most)
#   2. Scaling across numjobs (shows benefit grows with concurrency)
#   3. Sequential writes (control: optimization should not hurt this)
#   4. Different ext4 modes
##############################################################################

echo ""
echo "=== Starting benchmark matrix ($(date)) ==="

# Primary result: concurrent fsync, data=ordered
# Run 3 times for statistical confidence
for run in 1 2 3; do
    run_one "ordered_sync4_run${run}"  "loop,data=ordered"  4  randwrite
done

# Concurrency sweep: numjobs 1, 2, 4, 8
for jobs in 1 2 8; do
    run_one "ordered_sync${jobs}_run1"  "loop,data=ordered"  $jobs  randwrite
done

# Control: sequential writes (fast commit not involved — should be unchanged)
run_one "ordered_seq_run1"   "loop,data=ordered"  1  write

# Different modes
run_one "journal_sync4_run1"   "loop,data=journal"    4  randwrite
run_one "writeback_sync4_run1" "loop,data=writeback"  4  randwrite

# Metadata-heavy workload (creates many small files — triggers fast commits)
run_one "ordered_meta_run1"  "loop,data=ordered"  4  randwrite

echo ""
echo "=== All runs complete: $(date) ==="
echo "Results in: $RESULT_DIR"

##############################################################################
# Summary table
##############################################################################
echo ""
echo "=== Summary ==="
printf "%-35s  %-12s  %-12s  %-18s\n" "Run" "IOPS" "BW" "Commit avg (us)"
printf "%-35s  %-12s  %-12s  %-18s\n" "---" "----" "--" "---------------"
for fio_file in "$RESULT_DIR"/*_fio.txt; do
    run_name=$(basename "$fio_file" _fio.txt)
    iops=$(grep 'IOPS=' "$fio_file" | head -1 | grep -o 'IOPS=[0-9.k]*' | head -1)
    bw=$(grep 'BW=' "$fio_file" | head -1 | grep -oP 'BW=\S+' | head -1)
    probe_file="${fio_file/_fio.txt/_probe.txt}"
    if [ -f "$probe_file" ]; then
        commit_avg=$(grep jbd2_journal_commit "$probe_file" | awk '{print $5}')
    else
        commit_avg="N/A"
    fi
    printf "%-35s  %-12s  %-12s  %-18s\n" "$run_name" "$iops" "$bw" "$commit_avg"
done

echo ""
echo "To compare two kernel runs:"
echo "  diff eval_results/<stock-kernel>/system_info.txt eval_results/<patched-kernel>/system_info.txt"
echo "  # then compare *_probe.txt files for commit latency"
