#!/bin/bash
# Candidate 4 characterization: concurrent fsync workload at T=1,4,8,16.
#
# Each thread does 100 x (pwrite 4 KB + fsync) on its own file.
# Measures whether JBD2 already shares flushes across concurrent committers.
# If tx_delta grows linearly with T, CJFS compound flush has headroom.
# If sub-linear, the work is already merged.
#
# Usage: sudo bash bench_concurrent_fsync.sh
set -euo pipefail

KERNEL="$(uname -r)"
OUT_DIR="$(dirname "$0")/char_results/${KERNEL}"
mkdir -p "$OUT_DIR"

IMG=/tmp/c4_concurrent.img
MP=/mnt/c4_concurrent
OPS_PER_THREAD=100
HELPER="$(dirname "$0")/concurrent_fsync_helper"

[ "$(id -u)" = "0" ] || { echo "Run as root"; exit 1; }
[ -x "$HELPER" ] || { echo "build helpers first: bash build_char_helpers.sh"; exit 1; }

cleanup() {
    umount "$MP" 2>/dev/null || true
    rm -f "$IMG"
}
trap cleanup EXIT

for T in 1 4 8 16; do
    echo "=== concurrent fsync T=$T on ${KERNEL} ==="

    umount "$MP" 2>/dev/null || true
    rm -f "$IMG"
    dd if=/dev/zero of="$IMG" bs=1M count=256 status=none
    mkfs.ext4 -F -q -O fast_commit "$IMG"
    mkdir -p "$MP"
    mount -o loop "$IMG" "$MP"

    LOOPDEV=$(losetup -j "$IMG" | cut -d: -f1 | head -1 | sed 's|/dev/||')
    JBD2_INFO="/proc/fs/jbd2/${LOOPDEV}-8/info"

    if [ ! -f "$JBD2_INFO" ]; then
        echo "WARN: $JBD2_INFO missing"
        TX_BEFORE=0
    else
        TX_BEFORE=$(awk 'NR==1 {print $1; exit}' "$JBD2_INFO")
    fi

    OUT=$("$HELPER" "$MP" "$T" "$OPS_PER_THREAD")
    ELAPSED_NS=$(echo "$OUT" | sed -n 's/.*elapsed_ns=\([0-9]*\).*/\1/p')
    TOTAL_OPS=$((T * OPS_PER_THREAD))
    ELAPSED_MS=$(( ELAPSED_NS / 1000000 ))
    MS_PER_OP=$(awk "BEGIN{printf \"%.3f\", ${ELAPSED_NS}/1000000/${TOTAL_OPS}}")

    if [ -f "$JBD2_INFO" ]; then
        TX_AFTER=$(awk 'NR==1 {print $1; exit}' "$JBD2_INFO")
    else
        TX_AFTER=0
    fi
    TX_DELTA=$((TX_AFTER - TX_BEFORE))
    TX_PER_OP=$(awk "BEGIN{printf \"%.3f\", ${TX_DELTA}/${TOTAL_OPS}}")

    LINE="run=$(date -Iseconds) kernel=$KERNEL threads=$T ops_each=$OPS_PER_THREAD total_ops=$TOTAL_OPS elapsed_ms=$ELAPSED_MS ms_per_op=$MS_PER_OP tx_delta=$TX_DELTA tx_per_op=$TX_PER_OP"
    echo "$LINE"
    echo "$LINE" >> "$OUT_DIR/concurrent_T${T}.txt"

    umount "$MP"
    rm -f "$IMG"
done

trap - EXIT
echo ""
echo "=== Done. Results in $OUT_DIR/concurrent_T{1,4,8,16}.txt ==="
