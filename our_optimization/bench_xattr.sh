#!/bin/bash
# Candidate 3 benchmark: 5000x setfattr loop on a fast-commit fs.
#
# Measures:
#   - wall time of the loop
#   - JBD2 transaction count delta (via /proc/fs/jbd2/<dev>-8/info)
#
# Saves results tagged by kernel name. Run on both stock and patched
# kernels and compare.
#
# Usage: sudo bash bench_xattr.sh

set -euo pipefail

KERNEL="$(uname -r)"
OUT_DIR="$(dirname "$0")/eval_results_c3/${KERNEL}"
mkdir -p "$OUT_DIR"

IMG=/tmp/c3_xattr_bench.img
MP=/mnt/c3_xattr_bench
N=5000

[ "$(id -u)" = "0" ] || { echo "Run as root"; exit 1; }
command -v setfattr >/dev/null || { echo "apt install attr"; exit 1; }

echo "=== Candidate 3 xattr benchmark on $KERNEL ==="
echo "Results -> $OUT_DIR"

cleanup() {
    umount "$MP" 2>/dev/null || true
}
trap cleanup EXIT

# System info
{
    echo "Date: $(date -Iseconds)"
    echo "Kernel: $KERNEL"
    echo "CPU: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
    echo "Cores: $(nproc)"
    echo "RAM: $(free -h | awk '/^Mem/{print $2}')"
} | tee "$OUT_DIR/system_info.txt"

# Fresh filesystem
rm -f "$IMG"
dd if=/dev/zero of="$IMG" bs=1M count=256 status=none
mkfs.ext4 -F -q -O fast_commit "$IMG"
mkdir -p "$MP"
mount -o loop "$IMG" "$MP"
touch "$MP/f"

# Warmup: first xattr is always a full commit (sets the xattr feature
# bit on the superblock). Do one before the measured loop so only the
# measured portion is on the fast path.
setfattr -n user.warmup -v x "$MP/f"
sync && sync

# Find the JBD2 info file for our loop device. Loop device naming
# varies; use losetup to find it.
LOOPDEV=$(losetup -j "$IMG" | cut -d: -f1 | head -1 | sed 's|/dev/||')
JBD2_INFO="/proc/fs/jbd2/${LOOPDEV}-8/info"
if [ ! -f "$JBD2_INFO" ]; then
    echo "WARN: $JBD2_INFO not found; transaction count unavailable"
    TX_BEFORE=0
else
    TX_BEFORE=$(awk 'NR==1 {print $1; exit}' "$JBD2_INFO")
fi

# Measured loop: overwrite a single xattr N times, fsync after each.
# The fsync is what forces a per-operation JBD2 commit — without it,
# all ops accumulate into one transaction and we measure nothing.
# Using a single key avoids exhausting xattr space; using a dedicated
# C helper keeps syscall overhead minimal.
#
# If the helper is not built, fall back to setfattr+sync (much slower
# due to sync traversing the whole page cache; still measures the
# right ratio).
HELPER="$(dirname "$0")/xattr_fsync_helper"
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

echo "Running $N setxattr+fsync operations..."
T0=$(date +%s%N)
"$HELPER" "$MP/f" "$N"
T1=$(date +%s%N)
ELAPSED_MS=$(( (T1 - T0) / 1000000 ))
PER_OP_US=$(( (T1 - T0) / 1000 / N ))

if [ -f "$JBD2_INFO" ]; then
    TX_AFTER=$(awk 'NR==1 {print $1; exit}' "$JBD2_INFO")
else
    TX_AFTER=0
fi
TX_DELTA=$((TX_AFTER - TX_BEFORE))

{
    echo "kernel=$KERNEL"
    echo "N=$N"
    echo "elapsed_ms=$ELAPSED_MS"
    echo "per_op_us=$PER_OP_US"
    echo "tx_before=$TX_BEFORE"
    echo "tx_after=$TX_AFTER"
    echo "tx_delta=$TX_DELTA"
    echo "commits_per_op=$(awk "BEGIN{printf \"%.2f\", $TX_DELTA/$N}")"
} | tee "$OUT_DIR/xattr_loop.txt"

umount "$MP"

echo ""
echo "=== Done ==="
echo ""
echo "To compare: pull result from $OUT_DIR/xattr_loop.txt"
echo "Stock kernel expected: elapsed_ms ~20000-40000, tx_delta ~5000"
echo "Patched kernel expected: elapsed_ms ~1000-3000, tx_delta <500"
