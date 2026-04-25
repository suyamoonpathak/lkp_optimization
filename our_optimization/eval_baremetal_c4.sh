#!/bin/bash
# EXT4 FASTCOMMIT FALLOCATE RANGE — Bare-metal Evaluation Script (Candidate 4)
#
# Patch: our_optimization/fc-fallocate-range.patch
# Results writeup: our_optimization/CANDIDATE4_results.md
# C3 (already done): our_optimization/CANDIDATE3_results.md
#
# Prerequisite: C3 has already been merged into your Linux 6.1.4 tree
# (the INSTRUCTIONS_BAREMETAL_C3.md flow). This script adds the C4 patch
# on top, rebuilds, and measures the fallocate range benchmark.
#
# Run TWICE:
#   Step 1 (STOCK_OR_C3):   sudo bash eval_baremetal_c4.sh   # on kernel without C4
#   Step 2 (PATCHED_C4):    sudo bash eval_baremetal_c4.sh   # on kernel with C4
#
# Auto-detects by scanning the kernel source tree for the "punch_start"
# usage of ext4_fc_track_range, which exists only after our C4 patch.
# (Stock 6.1.4 and C3-only both lack it.)

set -euo pipefail

CONTRIBUTOR="baremetal"

# Workload parameters
N=1000
IMG_SIZE_MB=256
IMG_FILE="/tmp/c4_eval_${CONTRIBUTOR}.img"
MOUNT_POINT="/mnt/c4_eval_${CONTRIBUTOR}"

# Kernel detection — patched vs baseline
KERNEL_VER="$(uname -r)"
SRC_EXTENTS="$(find /home /root -name "extents.c" -path "*/ext4/*" 2>/dev/null | head -1)"

if [ -n "$SRC_EXTENTS" ]; then
    # Our C4 patch replaces mark_ineligible at line 5363 with
    # ext4_fc_track_range(handle, inode, punch_start, ...). That exact
    # pattern does not exist anywhere in stock 6.1.4.
    if grep -q "ext4_fc_track_range(handle, inode, punch_start" "$SRC_EXTENTS"; then
        RUN_LABEL="PATCHED_C4"
    else
        RUN_LABEL="BASELINE"   # stock or C3-only; arch-equivalent for this path
    fi
else
    RUN_LABEL="${LABEL:-UNKNOWN}"
    echo "WARNING: kernel source not found at expected path."
    echo "  Re-run with:  sudo LABEL=BASELINE bash $0"
    echo "           or:  sudo LABEL=PATCHED_C4 bash $0"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULT_DIR="$SCRIPT_DIR/eval_results_c4/$CONTRIBUTOR/${RUN_LABEL}_${KERNEL_VER}"
mkdir -p "$RESULT_DIR"

echo "========================================================"
echo " Contributor : $CONTRIBUTOR"
echo " Kernel      : $RUN_LABEL ($KERNEL_VER)"
echo " Results     : $RESULT_DIR"
echo "========================================================"

[ "$(id -u)" = "0" ] || { echo "ERROR: Run as root:  sudo bash $0"; exit 1; }
command -v fallocate >/dev/null || { echo "ERROR: fallocate not found (util-linux)"; exit 1; }
command -v gcc >/dev/null || { echo "ERROR: gcc not found. sudo apt install build-essential"; exit 1; }

# System info
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
    echo "Workload:    $N fallocate+fsync ops (collapse + insert) on fast_commit ext4 (${IMG_SIZE_MB}MB loop)"
} | tee "$RESULT_DIR/system_info.txt"

# CPU governor -> performance (no-op on VM, matters on bare-metal)
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$f" 2>/dev/null || true
done
[ -e /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ] && echo "CPU governor: performance"

cleanup() { umount "$MOUNT_POINT" 2>/dev/null || true; rm -f "$IMG_FILE"; }
trap cleanup EXIT

##############################################################################
# Build the fallocate_range_helper if not present
##############################################################################
HELPER="$SCRIPT_DIR/fallocate_range_helper"
if [ ! -x "$HELPER" ]; then
    echo "Building fallocate_range_helper..."
    if [ -f "$SCRIPT_DIR/fallocate_range_helper.c" ]; then
        gcc -O2 -Wall -o "$HELPER" "$SCRIPT_DIR/fallocate_range_helper.c" \
            || { echo "gcc build failed"; exit 1; }
    else
        echo "ERROR: fallocate_range_helper.c not found at $SCRIPT_DIR"
        echo "git pull to fetch the latest our_optimization/ files."
        exit 1
    fi
fi

##############################################################################
# Benchmark loop: 3 repeats per mode
##############################################################################
REPEATS=3

run_mode() {
    local MODE="$1"   # collapse | insert
    local LATENCIES="$RESULT_DIR/${MODE}_repeats.txt"
    echo "repeat elapsed_ms tx_delta per_op_us" > "$LATENCIES"

    for r in $(seq 1 $REPEATS); do
        echo "=== $MODE repeat $r/$REPEATS ($N ops) ==="
        umount "$MOUNT_POINT" 2>/dev/null || true
        rm -f "$IMG_FILE"
        dd if=/dev/zero of="$IMG_FILE" bs=1M count=$IMG_SIZE_MB status=none
        mkfs.ext4 -F -q -O fast_commit "$IMG_FILE"
        mkdir -p "$MOUNT_POINT"
        mount -o loop "$IMG_FILE" "$MOUNT_POINT"

        LOOPDEV=$(losetup -j "$IMG_FILE" | cut -d: -f1 | head -1 | sed 's|/dev/||')
        JBD2_INFO="/proc/fs/jbd2/${LOOPDEV}-8/info"
        if [ -f "$JBD2_INFO" ]; then
            TX0=$(awk 'NR==1 {print $1; exit}' "$JBD2_INFO")
        else
            TX0=0
            echo "WARN: $JBD2_INFO not found; tx counting unavailable"
        fi

        T0=$(date +%s%N)
        "$HELPER" "$MOUNT_POINT/f" "$N" "$MODE"
        T1=$(date +%s%N)

        if [ -f "$JBD2_INFO" ]; then
            TX1=$(awk 'NR==1 {print $1; exit}' "$JBD2_INFO")
        else
            TX1=0
        fi

        ELAPSED_MS=$(( (T1 - T0) / 1000000 ))
        PER_OP_US=$(( (T1 - T0) / 1000 / N ))
        TX_DELTA=$((TX1 - TX0))
        echo "$r $ELAPSED_MS $TX_DELTA $PER_OP_US" >> "$LATENCIES"
        echo "  elapsed=${ELAPSED_MS}ms tx_delta=$TX_DELTA per_op=${PER_OP_US}us"

        umount "$MOUNT_POINT"
        rm -f "$IMG_FILE"
    done

    # Summarize this mode
    python3 <<PYEOF | tee "$RESULT_DIR/${MODE}_summary.txt"
import statistics
with open("$LATENCIES") as f:
    lines = f.readlines()[1:]
data = [list(map(int, l.split())) for l in lines]
elapsed = [d[1] for d in data]
tx = [d[2] for d in data]
per_op = [d[3] for d in data]
print(f"kernel={\"$KERNEL_VER\"}")
print(f"label={\"$RUN_LABEL\"}")
print(f"mode={\"$MODE\"}")
print(f"N={'$N'}")
print(f"repeats={len(elapsed)}")
print(f"elapsed_ms_mean={statistics.mean(elapsed):.0f}")
print(f"elapsed_ms_stdev={statistics.stdev(elapsed) if len(elapsed)>1 else 0:.0f}")
print(f"tx_delta_mean={statistics.mean(tx):.0f}")
print(f"per_op_us_mean={statistics.mean(per_op):.0f}")
print(f"commits_per_op={statistics.mean(tx) / $N:.4f}")
PYEOF
}

run_mode collapse
run_mode insert

echo ""
echo "=== Done. Results: $RESULT_DIR ==="
echo ""
echo "Push results:"
echo "  git checkout -b results-c4/$CONTRIBUTOR"
echo "  git add our_optimization/eval_results_c4/$CONTRIBUTOR/"
echo "  git commit -m 'results-c4: $CONTRIBUTOR bare-metal $RUN_LABEL'"
echo "  git push -u origin results-c4/$CONTRIBUTOR"
