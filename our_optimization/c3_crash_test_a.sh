#!/bin/bash
# Crash-recovery Test A: 100 setfattr → simulated crash → all 100
# must be recoverable.
#
# Usage: sudo bash c3_crash_test_a.sh

set -euo pipefail
IMG=/tmp/c3_crashA.img
MP=/mnt/c3_crashA

[ "$(id -u)" = "0" ] || { echo "Run as root"; exit 1; }

cleanup() { umount "$MP" 2>/dev/null || true; }
trap cleanup EXIT

rm -f "$IMG"
dd if=/dev/zero of="$IMG" bs=1M count=256 status=none
mkfs.ext4 -F -q -O fast_commit "$IMG"
mkdir -p "$MP"
mount -o loop "$IMG" "$MP"
touch "$MP/f"

# Warmup (sets the xattr feature bit via full commit).
setfattr -n user.warmup -v x "$MP/f"
sync

# 100 inline xattrs under fast-commit-eligible handle.
for i in $(seq 1 100); do
    setfattr -n "user.a_$i" -v "val_$i" "$MP/f"
done

# Force fsync to push through the FC log.
sync -f "$MP/f"

# Simulate crash: drop caches and lazy-umount (no clean unmount).
echo 3 > /proc/sys/vm/drop_caches
umount -l "$MP"

# Remount; recovery runs here.
mount -o loop "$IMG" "$MP"

# Count recovered xattrs.
COUNT=$(getfattr -d -m "user.a_" "$MP/f" 2>/dev/null | grep -c "^user.a_")
echo "Test A: recovered $COUNT / 100"

if [ "$COUNT" -eq 100 ]; then
    echo "PASS: Test A"
    exit 0
else
    echo "FAIL: Test A - only $COUNT of 100 xattrs recovered"
    exit 1
fi
