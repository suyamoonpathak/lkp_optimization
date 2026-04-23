#!/bin/bash
# Candidate 4 characterization: 4000-byte setxattr loop on a C3 kernel.
#
# C3 made inline xattrs fast-commit-eligible. The BLOCK xattr path is still
# marked ineligible whenever touched_block=true. This bench measures that
# remaining overhead — the signal for whether a C3b (xattr-block) extension
# is worth building.
#
# Usage: sudo bash bench_xattr_block.sh
set -euo pipefail

KERNEL="$(uname -r)"
OUT_DIR="$(dirname "$0")/char_results/${KERNEL}"
mkdir -p "$OUT_DIR"

IMG=/tmp/c4_xattr_block.img
MP=/mnt/c4_xattr_block
N=1000
HELPER="$(dirname "$0")/xattr_block_fsync_helper"

[ "$(id -u)" = "0" ] || { echo "Run as root"; exit 1; }
[ -x "$HELPER" ] || { echo "build helpers first: bash build_char_helpers.sh"; exit 1; }

cleanup() {
    umount "$MP" 2>/dev/null || true
    rm -f "$IMG"
}
trap cleanup EXIT

echo "=== xattr block (4 KB value) on ${KERNEL} ==="

umount "$MP" 2>/dev/null || true
rm -f "$IMG"
dd if=/dev/zero of="$IMG" bs=1M count=256 status=none
mkfs.ext4 -F -q -O fast_commit "$IMG"
mkdir -p "$MP"
mount -o loop "$IMG" "$MP"
touch "$MP/f"

LOOPDEV=$(losetup -j "$IMG" | cut -d: -f1 | head -1 | sed 's|/dev/||')
JBD2_INFO="/proc/fs/jbd2/${LOOPDEV}-8/info"

if [ ! -f "$JBD2_INFO" ]; then
    echo "WARN: $JBD2_INFO missing"
    TX_BEFORE=0
else
    TX_BEFORE=$(awk 'NR==1 {print $1; exit}' "$JBD2_INFO")
fi

OUT=$("$HELPER" "$MP/f" "$N")
ELAPSED_NS=$(echo "$OUT" | sed -n 's/^elapsed_ns=//p')
ELAPSED_MS=$(( ELAPSED_NS / 1000000 ))
MS_PER_OP=$(awk "BEGIN{printf \"%.3f\", ${ELAPSED_NS}/1000000/${N}}")

if [ -f "$JBD2_INFO" ]; then
    TX_AFTER=$(awk 'NR==1 {print $1; exit}' "$JBD2_INFO")
else
    TX_AFTER=0
fi
TX_DELTA=$((TX_AFTER - TX_BEFORE))
TX_PER_OP=$(awk "BEGIN{printf \"%.3f\", ${TX_DELTA}/${N}}")

LINE="run=$(date -Iseconds) kernel=$KERNEL N=$N elapsed_ms=$ELAPSED_MS ms_per_op=$MS_PER_OP tx_delta=$TX_DELTA tx_per_op=$TX_PER_OP"
echo "$LINE"
echo "$LINE" >> "$OUT_DIR/xattr_block.txt"

umount "$MP"
rm -f "$IMG"
trap - EXIT

echo ""
echo "=== Done. Result appended to $OUT_DIR/xattr_block.txt ==="
