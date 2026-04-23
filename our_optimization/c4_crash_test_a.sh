#!/bin/bash
# Test A: COLLAPSE_RANGE crash recovery.
#
# Write a file with distinct per-block patterns, fsync for durability,
# then COLLAPSE_RANGE + fsync, then simulate crash via lazy umount.
# Remount and verify the file content matches what collapse should
# produce. If FC replay is correct, the shifted blocks are in place.
set -euo pipefail

IMG=/tmp/c4_crashA.img
MP=/mnt/c4_crashA

rm -f "$IMG"
dd if=/dev/zero of="$IMG" bs=1M count=64 status=none
mkfs.ext4 -F -q -O fast_commit "$IMG"
mkdir -p "$MP"
mount -o loop "$IMG" "$MP"

# 256 blocks of 4 KB, each block filled with a unique letter pattern.
python3 -c "
with open('$MP/f','wb') as f:
    for blk in range(256):
        f.write((chr(65+(blk%26))*4096).encode())
"
sync -f "$MP/f"

# Expected content AFTER collapse of blocks 32..63 (32 blocks, 128 KB):
#   original blocks 0..31 stay; original blocks 64..255 shift left to 32..223.
# File shrinks from 1 MB to 896 KB (224 blocks).
EXPECTED=$(python3 -c "
keep_head = b''.join([(chr(65+(i%26))*4096).encode() for i in range(32)])
keep_tail = b''.join([(chr(65+(i%26))*4096).encode() for i in range(64,256)])
import hashlib; print(hashlib.md5(keep_head+keep_tail).hexdigest())
")

# Collapse middle 32 blocks, starting at block 32.
fallocate -c -o $((32*4096)) -l $((32*4096)) "$MP/f"
sync -f "$MP/f"

# Simulate crash: drop caches and lazy umount so journal is replayed at mount.
echo 3 > /proc/sys/vm/drop_caches
umount -l "$MP"
mount -o loop "$IMG" "$MP"

ACTUAL=$(md5sum "$MP/f" | cut -d' ' -f1)
SIZE=$(stat -c %s "$MP/f")
EXPECTED_SIZE=$((224 * 4096))

echo "expected_md5=$EXPECTED"
echo "actual_md5=$ACTUAL"
echo "expected_size=$EXPECTED_SIZE actual_size=$SIZE"

umount "$MP"
rm -f "$IMG"

if [ "$EXPECTED" = "$ACTUAL" ] && [ "$SIZE" = "$EXPECTED_SIZE" ]; then
    echo "PASS: Test A (collapse + crash recovery)"
    exit 0
fi
echo "FAIL: Test A"
exit 1
