#!/bin/bash
# JBD2 Fast Commit Barrier Deferral — Bare-Metal Evaluation Script
#
# INSTRUCTIONS:
#   Step 1: On STOCK kernel (before applying patch):
#             sudo bash bare_metal_eval.sh
#             → saves results to ./eval_results/STOCK_<kernel>/
#
#   Step 2: Apply the patch, rebuild kernel, reboot.
#             (See patch instructions at bottom of this file)
#
#   Step 3: On PATCHED kernel (after reboot):
#             sudo bash bare_metal_eval.sh
#             → saves results to ./eval_results/PATCHED_<kernel>/
#
#   Step 4: Compare:
#             python3 compare_results.py eval_results/STOCK_* eval_results/PATCHED_*
#
# DEPENDENCIES (install once):
#   sudo apt install fio trace-cmd linux-tools-common linux-tools-$(uname -r)

set -euo pipefail

##############################################################################
# Settings — do not change between stock and patched runs
##############################################################################
FIO_RUNTIME=60            # seconds per fio run (must be identical both runs)
FIO_SIZE="128M"           # per-job data size
FIO_BS="4k"               # block size
FIO_SEED=42               # fixed seed → deterministic I/O pattern
IMG_SIZE_MB=1024          # loop device image size (MB)
IMG_FILE="/tmp/jbd2_bm_eval.img"
MOUNT_POINT="/mnt/jbd2_bm_eval"
RUNS=3                    # number of repeated runs per config (for stddev)

##############################################################################
# Detect if we are on stock or patched kernel
# We detect by checking if the TODO comment is present in the source.
# If the source tree is not available, the user passes PATCHED=1 or PATCHED=0.
##############################################################################
KERNEL_VER="$(uname -r)"
SRC_TREE="$(find /home -name "commit.c" -path "*/jbd2/*" 2>/dev/null | head -1)"

if [ -n "$SRC_TREE" ]; then
    if grep -q "TODO: by blocking fast commits here" "$SRC_TREE"; then
        RUN_LABEL="STOCK"
    else
        RUN_LABEL="PATCHED"
    fi
else
    RUN_LABEL="${PATCHED:-UNKNOWN}"
    echo "WARNING: kernel source not found. Set PATCHED=STOCK or PATCHED=PATCHED:"
    echo "  sudo PATCHED=STOCK bash $0    # for stock kernel"
    echo "  sudo PATCHED=PATCHED bash $0  # for patched kernel"
fi

RESULT_DIR="$(dirname "$0")/eval_results/${RUN_LABEL}_${KERNEL_VER}"
mkdir -p "$RESULT_DIR"

echo "========================================================"
echo " JBD2 Evaluation: $RUN_LABEL kernel ($KERNEL_VER)"
echo " Results → $RESULT_DIR"
echo "========================================================"

##############################################################################
# Prerequisite checks
##############################################################################
[ "$(id -u)" = "0" ] || { echo "ERROR: Run as root: sudo bash $0"; exit 1; }
command -v fio >/dev/null || { echo "ERROR: fio not found. Run: sudo apt install fio"; exit 1; }

HAS_TRACE=0
command -v trace-cmd >/dev/null && HAS_TRACE=1 || echo "NOTE: trace-cmd not found — skipping JBD2 phase breakdown (apt install trace-cmd)"

##############################################################################
# Save system info — critical for reproducibility
##############################################################################
{
    echo "Date:      $(date -Iseconds)"
    echo "Kernel:    $(uname -r)"
    echo "Run label: $RUN_LABEL"
    echo "CPU:       $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
    echo "CPU cores: $(nproc)"
    echo "RAM:       $(free -h | awk '/^Mem/{print $2}')"
    echo "Storage:   $(lsblk -d -o NAME,SIZE,ROTA,TRAN 2>/dev/null | grep -v NAME | head -5)"
    echo "fio:       $(fio --version)"
    echo "FIO_RUNTIME=$FIO_RUNTIME FIO_SIZE=$FIO_SIZE FIO_SEED=$FIO_SEED RUNS=$RUNS"
    echo ""
    echo "--- /proc/cpuinfo freq ---"
    grep "cpu MHz" /proc/cpuinfo | head -4
    echo ""
    echo "--- Disk scheduler ---"
    for q in /sys/block/*/queue/scheduler; do echo "$q: $(cat $q)"; done 2>/dev/null || true
} | tee "$RESULT_DIR/system_info.txt"

##############################################################################
# CPU governor — pin to performance to reduce noise
##############################################################################
ORIG_GOVERNORS=()
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
    for i in $(seq 0 $(($(nproc)-1))); do
        f="/sys/devices/system/cpu/cpu${i}/cpufreq/scaling_governor"
        ORIG_GOVERNORS+=("$(cat $f)")
        echo performance > "$f" 2>/dev/null || true
    done
    echo "CPU governor set to: performance"
fi

restore_governors() {
    local i=0
    for g in "${ORIG_GOVERNORS[@]}"; do
        echo "$g" > "/sys/devices/system/cpu/cpu${i}/cpufreq/scaling_governor" 2>/dev/null || true
        ((i++)) || true
    done
    umount "$MOUNT_POINT" 2>/dev/null || true
    losetup -d "$BLOCK_DEV" 2>/dev/null || true
}
trap restore_governors EXIT

##############################################################################
# Create loop device
##############################################################################
echo ""
echo "Creating ${IMG_SIZE_MB}MB test image..."
dd if=/dev/zero of="$IMG_FILE" bs=1M count="$IMG_SIZE_MB" status=progress 2>&1
BLOCK_DEV=$(losetup --find --show "$IMG_FILE")
echo "Loop device: $BLOCK_DEV"
mkdir -p "$MOUNT_POINT"

##############################################################################
# Core benchmark function
# Args: label  ext4_opts  numjobs  rw_pattern  run_number
##############################################################################
run_benchmark() {
    local label="$1" ext4_opts="$2" numjobs="$3" rw="$4" run_num="$5"
    local tag="${label}_j${numjobs}_run${run_num}"
    local out="$RESULT_DIR/$tag"

    echo ""
    echo "  → $tag"

    # Fresh filesystem — eliminates fragmentation effects between runs
    mkfs.ext4 -F -q "$BLOCK_DEV"
    mount -o "$ext4_opts" "$BLOCK_DEV" "$MOUNT_POINT"

    # Drop page cache — ensures cold cache each run
    sync && echo 3 > /proc/sys/vm/drop_caches && sleep 1

    # Enable JBD2 run_stats tracepoint if trace-cmd is available
    if [ "$HAS_TRACE" = "1" ]; then
        trace-cmd start -e jbd2:jbd2_run_stats 2>/dev/null || true
    fi

    # Run fio — randseed makes pattern identical across stock/patched runs
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

    # Capture JBD2 commit pipeline breakdown
    if [ "$HAS_TRACE" = "1" ]; then
        trace-cmd stop 2>/dev/null || true
        trace-cmd report 2>/dev/null | grep jbd2_run_stats > "${out}_jbd2_phases.txt" || true
        trace-cmd reset 2>/dev/null || true
    fi

    umount "$MOUNT_POINT"
    sync && echo 3 > /proc/sys/vm/drop_caches
    sleep 2   # let I/O settle between runs
}

##############################################################################
# Benchmark matrix
##############################################################################
echo ""
echo "=== Starting benchmark matrix ==="
echo "    Each run: ${FIO_RUNTIME}s, bs=${FIO_BS}, size=${FIO_SIZE}, seed=${FIO_SEED}"
echo ""

# PRIMARY: 4-job concurrent fsync (main optimization target)
for r in $(seq 1 $RUNS); do
    run_benchmark "ordered_syncwrite" "loop,data=ordered" 4 randwrite "$r"
done

# CONCURRENCY SWEEP: shows benefit scales with contention
for jobs in 1 2 8; do
    run_benchmark "ordered_syncwrite" "loop,data=ordered" "$jobs" randwrite 1
done

# CONTROL: sequential write, 1 job — fast commit not involved, should be unchanged
run_benchmark "ordered_seqwrite" "loop,data=ordered" 1 write 1

# OTHER MODES
run_benchmark "journal_syncwrite"   "loop,data=journal"   4 randwrite 1
run_benchmark "writeback_syncwrite" "loop,data=writeback" 4 randwrite 1

echo ""
echo "=== All runs complete ==="

##############################################################################
# Print summary table
##############################################################################
echo ""
echo "=== Summary: $RUN_LABEL kernel ($KERNEL_VER) ==="
printf "%-40s  %8s  %12s  %10s  %10s\n" "Run" "IOPS" "BW" "lat_avg_us" "lat_p99_us"
printf "%-40s  %8s  %12s  %10s  %10s\n" "---" "----" "--" "----------" "----------"

for fio_file in "$RESULT_DIR"/*_fio.txt; do
    tag=$(basename "$fio_file" _fio.txt)
    iops=$(grep -oP 'IOPS=\K[0-9.k]+' "$fio_file" | head -1)
    bw=$(grep -oP 'BW=\K[^,)]+' "$fio_file" | head -1)
    lat_avg=$(grep 'clat\|lat (' "$fio_file" | grep 'avg=' | head -1 | grep -oP 'avg=\K[0-9.]+')
    lat_p99=$(grep '99.00th' "$fio_file" | grep -oP '\[\K[0-9]+' | head -1)
    printf "%-40s  %8s  %12s  %10s  %10s\n" "$tag" "$iops" "$bw" "${lat_avg:-N/A}" "${lat_p99:-N/A}"
done

echo ""
echo "Full results saved to: $RESULT_DIR"
echo ""
echo "NEXT STEP:"
if [ "$RUN_LABEL" = "STOCK" ]; then
    echo "  Apply the patch and rebuild the kernel, then run this script again."
    echo "  Patch: patch -p1 < our_optimization/jbd2-fc-barrier-defer.patch"
else
    echo "  Run: python3 compare_results.py eval_results/STOCK_* eval_results/PATCHED_*"
fi

##############################################################################
# Patch instructions (for reference)
##############################################################################
# To apply the patch on bare-metal:
#
#   cd /path/to/linux-6.1.4
#   patch -p1 < /path/to/our_optimization/jbd2-fc-barrier-defer.patch
#   cp /boot/config-$(uname -r) .config
#   make olddefconfig
#   make -j$(nproc) bzImage modules
#   sudo make modules_install
#   sudo make install
#   sudo reboot
#   # Select 6.1.4-cs614-hacker from GRUB, then re-run this script
