#!/bin/bash
# EXT4 FASTCOMMIT INLINE XATTR — Evaluation Script for MILAN (Candidate 3)
#
# Patch: our_optimization/fc-inline-xattr.patch
# Spec:  docs/superpowers/specs/2026-04-23-ext4-fastcommit-inline-xattr-design.md
# Results writeup: our_optimization/CANDIDATE3_results.md
#
# Run TWICE:
#   Step 1 (STOCK):    sudo bash eval_milan_c3.sh    # on unpatched 6.1.4
#   Step 2 (PATCHED):  sudo bash eval_milan_c3.sh    # on cs614-c3-patched
#
# Auto-detects STOCK vs PATCHED by scanning the kernel source tree for
# the "touched_block" identifier (present only after our patch).

set -euo pipefail

CONTRIBUTOR="milan"

# Workload parameters
N=5000
IMG_SIZE_MB=256
IMG_FILE="/tmp/c3_eval_${CONTRIBUTOR}.img"
MOUNT_POINT="/mnt/c3_eval_${CONTRIBUTOR}"

# Kernel detection — STOCK vs PATCHED
KERNEL_VER="$(uname -r)"
SRC_XATTR="$(find /home /root -name "xattr.c" -path "*/ext4/*" 2>/dev/null | head -1)"

if [ -n "$SRC_XATTR" ]; then
    # Our patch adds a `touched_block` local. Present => patched.
    if grep -q "bool touched_block" "$SRC_XATTR"; then
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
RESULT_DIR="$SCRIPT_DIR/eval_results_c3/$CONTRIBUTOR/${RUN_LABEL}_${KERNEL_VER}"
mkdir -p "$RESULT_DIR"

echo "========================================================"
echo " Contributor : $CONTRIBUTOR"
echo " Kernel      : $RUN_LABEL ($KERNEL_VER)"
echo " Results     : $RESULT_DIR"
echo "========================================================"

[ "$(id -u)" = "0" ] || { echo "ERROR: Run as root:  sudo bash $0"; exit 1; }
command -v setfattr >/dev/null || { echo "ERROR: setfattr not found. sudo apt install attr"; exit 1; }
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
    echo "Workload:    $N setxattr+fsync ops on fast_commit ext4 (256MB loop)"
} | tee "$RESULT_DIR/system_info.txt"

# CPU governor -> performance (no-op on VM, matters on bare-metal)
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$f" 2>/dev/null || true
done
[ -e /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ] && echo "CPU governor: performance"

cleanup() { umount "$MOUNT_POINT" 2>/dev/null || true; }
trap cleanup EXIT

##############################################################################
# Build the xattr_fsync_helper if not present
##############################################################################
HELPER="$SCRIPT_DIR/xattr_fsync_helper"
if [ ! -x "$HELPER" ]; then
    echo "Building xattr_fsync_helper..."
    cat > "${HELPER}.c" <<'HEOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/xattr.h>

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: %s <file> <N>\n", argv[0]); return 2; }
    const char *path = argv[1];
    long N = atol(argv[2]);
    int fd = open(path, O_RDWR);
    if (fd < 0) { perror("open"); return 1; }
    char val[32];
    for (long i = 0; i < N; i++) {
        int n = snprintf(val, sizeof(val), "v%ld", i);
        if (fsetxattr(fd, "user.test", val, n, 0) < 0) { perror("fsetxattr"); return 1; }
        if (fsync(fd) < 0) { perror("fsync"); return 1; }
    }
    close(fd);
    return 0;
}
HEOF
    gcc -O2 -o "$HELPER" "${HELPER}.c" || { echo "gcc build failed"; exit 1; }
fi

##############################################################################
# Setup filesystem
##############################################################################
rm -f "$IMG_FILE"
dd if=/dev/zero of="$IMG_FILE" bs=1M count=$IMG_SIZE_MB status=none
mkfs.ext4 -F -q -O fast_commit "$IMG_FILE"
mkdir -p "$MOUNT_POINT"
mount -o loop "$IMG_FILE" "$MOUNT_POINT"
touch "$MOUNT_POINT/f"

# Warmup: first xattr is a full commit (sets the xattr feature bit on sb).
setfattr -n user.warmup -v x "$MOUNT_POINT/f"
sync && sync

##############################################################################
# Transaction counting
##############################################################################
LOOPDEV=$(losetup -j "$IMG_FILE" | cut -d: -f1 | head -1 | sed 's|/dev/||')
JBD2_INFO="/proc/fs/jbd2/${LOOPDEV}-8/info"
if [ -f "$JBD2_INFO" ]; then
    TX_BEFORE=$(awk 'NR==1 {print $1; exit}' "$JBD2_INFO")
else
    TX_BEFORE=0
    echo "WARN: $JBD2_INFO not found; transaction counting unavailable"
fi

##############################################################################
# Run the benchmark (3 repeats for confidence)
##############################################################################
LATENCIES="$RESULT_DIR/repeats.txt"
echo "repeat elapsed_ms tx_delta per_op_us" > "$LATENCIES"

REPEATS=3
for r in $(seq 1 $REPEATS); do
    echo "Repeat $r/$REPEATS ($N setxattr+fsync)..."
    TX0=$(awk 'NR==1 {print $1; exit}' "$JBD2_INFO" 2>/dev/null || echo 0)
    T0=$(date +%s%N)
    "$HELPER" "$MOUNT_POINT/f" "$N"
    T1=$(date +%s%N)
    TX1=$(awk 'NR==1 {print $1; exit}' "$JBD2_INFO" 2>/dev/null || echo 0)

    ELAPSED_MS=$(( (T1 - T0) / 1000000 ))
    PER_OP_US=$(( (T1 - T0) / 1000 / N ))
    TX_DELTA=$((TX1 - TX0))
    echo "$r $ELAPSED_MS $TX_DELTA $PER_OP_US" >> "$LATENCIES"
    echo "  elapsed=${ELAPSED_MS}ms tx_delta=$TX_DELTA per_op=${PER_OP_US}us"
done

umount "$MOUNT_POINT"

##############################################################################
# Summarize
##############################################################################
python3 <<PYEOF | tee -a "$RESULT_DIR/xattr_loop.txt"
import statistics
with open("$LATENCIES") as f:
    lines = f.readlines()[1:]
data = [list(map(int, l.split())) for l in lines]
elapsed = [d[1] for d in data]
tx = [d[2] for d in data]
per_op = [d[3] for d in data]
print(f"kernel={\"$KERNEL_VER\"}")
print(f"label={\"$RUN_LABEL\"}")
print(f"N={'$N'}")
print(f"repeats={len(elapsed)}")
print(f"elapsed_ms_mean={statistics.mean(elapsed):.0f}")
print(f"elapsed_ms_stdev={statistics.stdev(elapsed) if len(elapsed)>1 else 0:.0f}")
print(f"tx_delta_mean={statistics.mean(tx):.0f}")
print(f"per_op_us_mean={statistics.mean(per_op):.0f}")
print(f"commits_per_op={statistics.mean(tx) / $N:.4f}")
PYEOF

echo ""
echo "=== Done. Results: $RESULT_DIR ==="
echo ""
echo "Push results:"
echo "  git add our_optimization/eval_results_c3/$CONTRIBUTOR/"
echo "  git commit -m 'results-c3: $CONTRIBUTOR bare-metal $RUN_LABEL'"
echo "  git push"
