#!/bin/bash
# Crash-recovery Test B: set 100, remove 50 (the evens), simulated
# crash → exactly the 50 odds must remain.
#
# Usage: sudo bash c3_crash_test_b.sh

set -euo pipefail
IMG=/tmp/c3_crashB.img
MP=/mnt/c3_crashB

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

# Set 100
for i in $(seq 1 100); do
    setfattr -n "user.b_$i" -v "v$i" "$MP/f"
done
sync -f "$MP/f"

# Remove evens (50 removals)
for i in $(seq 2 2 100); do
    setfattr -x "user.b_$i" "$MP/f"
done
sync -f "$MP/f"

# Simulate crash
echo 3 > /proc/sys/vm/drop_caches
umount -l "$MP"
mount -o loop "$IMG" "$MP"

# Verify exactly 50 (odds) remain
COUNT=$(getfattr -d -m "user.b_" "$MP/f" 2>/dev/null | grep -c "^user.b_")
echo "Test B: recovered $COUNT (expected 50)"

if [ "$COUNT" -eq 50 ]; then
    echo "PASS: Test B"
    exit 0
else
    echo "FAIL: Test B - $COUNT xattrs recovered, expected 50"
    exit 1
fi
