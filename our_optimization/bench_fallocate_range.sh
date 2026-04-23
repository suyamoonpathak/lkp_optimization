#!/bin/bash
# Candidate 4 characterization: fallocate COLLAPSE_RANGE / INSERT_RANGE loop.
#
# Both modes call ext4_fc_mark_ineligible(EXT4_FC_REASON_FALLOC_RANGE) —
# every op on a fast-commit-enabled fs is a full JBD2 commit today.
# This bench measures that overhead.
#
# Usage: sudo bash bench_fallocate_range.sh
set -euo pipefail

KERNEL="$(uname -r)"
OUT_DIR="$(dirname "$0")/char_results/${KERNEL}"
mkdir -p "$OUT_DIR"

N=1000
HELPER="$(dirname "$0")/fallocate_range_helper"

[ "$(id -u)" = "0" ] || { echo "Run as root"; exit 1; }
[ -x "$HELPER" ] || { echo "build helpers first: bash build_char_helpers.sh"; exit 1; }

for MODE in collapse insert; do
    IMG="/tmp/c4_fallocate_${MODE}.img"
    MP="/mnt/c4_fallocate_${MODE}"

    cleanup() {
        umount "$MP" 2>/dev/null || true
        rm -f "$IMG"
    }
    trap cleanup EXIT

    echo "=== fallocate ${MODE} on ${KERNEL} ==="

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

    OUT=$("$HELPER" "$MP/file" "$N" "$MODE")
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

    LINE="run=$(date -Iseconds) kernel=$KERNEL mode=$MODE N=$N elapsed_ms=$ELAPSED_MS ms_per_op=$MS_PER_OP tx_delta=$TX_DELTA tx_per_op=$TX_PER_OP"
    echo "$LINE"
    echo "$LINE" >> "$OUT_DIR/fallocate_${MODE}.txt"

    umount "$MP"
    rm -f "$IMG"
    trap - EXIT
done

echo ""
echo "=== Done. Results appended to $OUT_DIR/fallocate_{collapse,insert}.txt ==="
