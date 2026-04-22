#!/bin/bash
# Crash-recovery Test C: force the block-xattr path (large value) and
# verify the full-commit fallback correctly persists it.
#
# This test catches the case where our touched_block tracking might
# have missed a code path, causing inline fast commit to be taken for
# a change that actually touched the xattr block.
#
# Usage: sudo bash c3_crash_test_c.sh

set -euo pipefail
IMG=/tmp/c3_crashC.img
MP=/mnt/c3_crashC

[ "$(id -u)" = "0" ] || { echo "Run as root"; exit 1; }

cleanup() { umount "$MP" 2>/dev/null || true; }
trap cleanup EXIT

rm -f "$IMG"
dd if=/dev/zero of="$IMG" bs=1M count=256 status=none
mkfs.ext4 -F -q -O fast_commit "$IMG"
mkdir -p "$MP"
mount -o loop "$IMG" "$MP"
touch "$MP/f"

# Warmup
setfattr -n user.warmup -v x "$MP/f"
sync

# Write a 4000-byte xattr — well over inline limit, forces block path.
BIG=$(head -c 4000 /dev/urandom | base64 -w0)
setfattr -n user.big -v "$BIG" "$MP/f"
sync -f "$MP/f"

# Save expected value length
EXPECTED=$(echo -n "$BIG" | wc -c)

# Simulate crash
echo 3 > /proc/sys/vm/drop_caches
umount -l "$MP"
mount -o loop "$IMG" "$MP"

# Verify the value came back
RECOVERED=$(getfattr -n user.big --only-values "$MP/f" 2>/dev/null | wc -c)
echo "Test C: recovered $RECOVERED bytes, expected $EXPECTED bytes"

if [ "$RECOVERED" -eq "$EXPECTED" ]; then
    echo "PASS: Test C"
    exit 0
else
    echo "FAIL: Test C - $RECOVERED bytes recovered, expected $EXPECTED"
    exit 1
fi
