#!/bin/bash
# JBD2 Fast Commit Barrier Deferral — Evaluation Script for SAHIL
#
# INSTRUCTIONS FOR SAHIL:
# ─────────────────────────────────────────────────────────────────
#
#   STEP 1 — Install dependencies (once):
#     sudo apt install fio trace-cmd
#
#   STEP 2 — Run on STOCK kernel (before applying any patch):
#     sudo bash eval_sahil.sh
#     → saves to: our_optimization/eval_results/sahil/STOCK_<kernel>/
#
#   STEP 3 — Apply the patch and rebuild the kernel:
#     cd /path/to/linux-6.1.4
#     patch -p1 < our_optimization/jbd2-fc-barrier-defer.patch
#     cp /boot/config-$(uname -r) .config
#     make olddefconfig
#     make -j$(nproc) bzImage modules
#     sudo make modules_install
#     sudo make install
#     sudo reboot          ← select 6.1.4-cs614-hacker from GRUB
#
#   STEP 4 — Run on PATCHED kernel (after reboot):
#     sudo bash eval_sahil.sh
#     → saves to: our_optimization/eval_results/sahil/PATCHED_<kernel>/
#
#   STEP 5 — Commit and push results:
#     git add our_optimization/eval_results/sahil/
#     git commit -m "results: sahil bare-metal evaluation"
#     git push

set -euo pipefail

CONTRIBUTOR="sahil"

##############################################################################
# Settings — DO NOT change between stock and patched runs
##############################################################################
FIO_RUNTIME=60
FIO_SIZE="128M"
FIO_BS="4k"
FIO_SEED=42
IMG_SIZE_MB=1024
IMG_FILE="/tmp/jbd2_eval_${CONTRIBUTOR}.img"
MOUNT_POINT="/mnt/jbd2_eval_${CONTRIBUTOR}"
RUNS=3

##############################################################################
# Auto-detect stock vs patched
##############################################################################
KERNEL_VER="$(uname -r)"
SRC_COMMIT="$(find /home /root -name "commit.c" -path "*/jbd2/*" 2>/dev/null | head -1)"

if [ -n "$SRC_COMMIT" ]; then
    if grep -q "TODO: by blocking fast commits here" "$SRC_COMMIT"; then
        RUN_LABEL="STOCK"
    else
        RUN_LABEL="PATCHED"
    fi
else
    RUN_LABEL="${LABEL:-UNKNOWN}"
    echo "WARNING: kernel source not found at expected path."
    echo "  Re-run with:  sudo LABEL=STOCK bash $0"
    echo "           or:  sudo LABEL=PATCHED bash $0"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULT_DIR="$SCRIPT_DIR/eval_results/$CONTRIBUTOR/${RUN_LABEL}_${KERNEL_VER}"
mkdir -p "$RESULT_DIR"

echo "========================================================"
echo " Contributor : $CONTRIBUTOR"
echo " Kernel      : $RUN_LABEL ($KERNEL_VER)"
echo " Results     : $RESULT_DIR"
echo "========================================================"

##############################################################################
# Checks
##############################################################################
[ "$(id -u)" = "0" ] || { echo "ERROR: Run as root:  sudo bash $0"; exit 1; }
command -v fio >/dev/null || { echo "ERROR: fio not found.  sudo apt install fio"; exit 1; }
HAS_TRACE=0
command -v trace-cmd >/dev/null && HAS_TRACE=1 \
    || echo "NOTE: trace-cmd not found — JBD2 phase breakdown skipped.  sudo apt install trace-cmd"

##############################################################################
# System info
##############################################################################
{
    echo "Contributor: $CONTRIBUTOR"
    echo "Date:        $(date -Iseconds)"
    echo "Kernel:      $(uname -r)"
    echo "Run label:   $RUN_LABEL"
    echo "CPU:         $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
    echo "CPU cores:   $(nproc)"
    echo "RAM:         $(free -h | awk '/^Mem/{print $2}')"
    echo "Storage:"
    lsblk -d -o NAME,SIZE,ROTA,TRAN 2>/dev/null | grep -v NAME | head -5
    echo "fio:         $(fio --version)"
    echo "Settings:    FIO_RUNTIME=$FIO_RUNTIME FIO_SIZE=$FIO_SIZE FIO_SEED=$FIO_SEED RUNS=$RUNS"
    echo ""
    echo "--- CPU MHz ---"
    grep "cpu MHz" /proc/cpuinfo | head -4
    echo ""
    echo "--- Disk scheduler ---"
    for q in /sys/block/*/queue/scheduler; do echo "  $q: $(cat $q)"; done 2>/dev/null || true
} | tee "$RESULT_DIR/system_info.txt"

##############################################################################
# CPU governor → performance
##############################################################################
ORIG_GOV=()
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
    for i in $(seq 0 $(($(nproc)-1))); do
        f="/sys/devices/system/cpu/cpu${i}/cpufreq/scaling_governor"
        ORIG_GOV+=("$(cat "$f")")
        echo performance > "$f" 2>/dev/null || true
    done
    echo "CPU governor: performance"
fi

cleanup() {
    local i=0
    for g in "${ORIG_GOV[@]:-}"; do
        echo "$g" > "/sys/devices/system/cpu/cpu${i}/cpufreq/scaling_governor" 2>/dev/null || true
        ((i++)) || true
    done
    umount "$MOUNT_POINT" 2>/dev/null || true
    [ -n "${BLOCK_DEV:-}" ] && losetup -d "$BLOCK_DEV" 2>/dev/null || true
}
trap cleanup EXIT

##############################################################################
# Loop device setup
##############################################################################
echo ""
echo "Creating ${IMG_SIZE_MB}MB test image..."
dd if=/dev/zero of="$IMG_FILE" bs=1M count="$IMG_SIZE_MB" status=progress 2>&1
BLOCK_DEV=$(losetup --find --show "$IMG_FILE")
echo "Loop device: $BLOCK_DEV"
mkdir -p "$MOUNT_POINT"

##############################################################################
# Single benchmark run
##############################################################################
run_one() {
    local label="$1" mount_opts="$2" numjobs="$3" rw="$4" run_num="$5"
    local tag="${label}_j${numjobs}_run${run_num}"
    local out="$RESULT_DIR/$tag"

    echo "  → $tag"

    mkfs.ext4 -F -q -O fast_commit "$BLOCK_DEV"
    mount -o "$mount_opts" "$BLOCK_DEV" "$MOUNT_POINT"
    sync && echo 3 > /proc/sys/vm/drop_caches && sleep 1

    [ "$HAS_TRACE" = "1" ] && trace-cmd start -e jbd2:jbd2_run_stats 2>/dev/null || true

    fio \
        --name="$tag" \
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

    if [ "$HAS_TRACE" = "1" ]; then
        trace-cmd stop 2>/dev/null || true
        trace-cmd report 2>/dev/null | grep jbd2_run_stats > "${out}_jbd2_phases.txt" || true
        trace-cmd reset 2>/dev/null || true
    fi

    umount "$MOUNT_POINT"
    sync && echo 3 > /proc/sys/vm/drop_caches && sleep 2
}

##############################################################################
# Benchmark matrix
##############################################################################
echo ""
echo "=== Benchmark matrix: ${FIO_RUNTIME}s runs, bs=${FIO_BS}, seed=${FIO_SEED} ==="

for r in $(seq 1 $RUNS); do
    run_one "ordered_syncwrite"   "loop,data=ordered"   4 randwrite "$r"
done
for jobs in 1 2 8; do
    run_one "ordered_syncwrite"   "loop,data=ordered"   "$jobs" randwrite 1
done
run_one "ordered_seqwrite"        "loop,data=ordered"   1 write 1
run_one "journal_syncwrite"       "loop,data=journal"   4 randwrite 1
run_one "writeback_syncwrite"     "loop,data=writeback" 4 randwrite 1

echo ""
echo "=== Done. Results: $RESULT_DIR ==="

##############################################################################
# Summary
##############################################################################
echo ""
printf "%-40s  %8s  %12s  %10s\n" "Run" "IOPS" "BW" "lat_avg_us"
printf "%-40s  %8s  %12s  %10s\n" "---" "----" "--" "----------"
for f in "$RESULT_DIR"/*_fio.txt; do
    tag=$(basename "$f" _fio.txt)
    iops=$(grep -oP 'IOPS=\K[0-9.k]+' "$f" | head -1)
    bw=$(grep -oP 'BW=\K[^,)]+' "$f" | head -1)
    lat=$(grep 'clat\|lat (' "$f" | grep 'avg=' | head -1 | grep -oP 'avg=\K[0-9.]+')
    printf "%-40s  %8s  %12s  %10s\n" "$tag" "${iops:-?}" "${bw:-?}" "${lat:-N/A}"
done

echo ""
echo "Push results:"
echo "  git add our_optimization/eval_results/sahil/"
echo "  git commit -m 'results: sahil bare-metal ${RUN_LABEL}'"
echo "  git push"
