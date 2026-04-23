#!/bin/bash
# Test B: INSERT_RANGE crash recovery.
#
# Write a file with distinct per-block patterns, fsync for durability,
# then INSERT_RANGE (which grows the file and pushes blocks right),
# then simulate crash via lazy umount. Remount and verify that:
#   - file size grew by the inserted amount;
#   - pre-insert content appears at its new shifted position;
#   - the inserted region is a hole (all zeros).
set -euo pipefail

IMG=/tmp/c4_crashB.img
MP=/mnt/c4_crashB

rm -f "$IMG"
dd if=/dev/zero of="$IMG" bs=1M count=64 status=none
mkfs.ext4 -F -q -O fast_commit "$IMG"
mkdir -p "$MP"
mount -o loop "$IMG" "$MP"

# 128 blocks of 4 KB, each unique.
python3 -c "
with open('$MP/f','wb') as f:
    for blk in range(128):
        f.write((chr(65+(blk%26))*4096).encode())
"
sync -f "$MP/f"

# Insert 16 blocks at offset 16. After:
#   blocks 0..15 unchanged (original 0..15);
#   blocks 16..31 are a hole (zeros);
#   blocks 32..143 = original 16..127.
EXPECTED=$(python3 -c "
head = b''.join([(chr(65+(i%26))*4096).encode() for i in range(16)])
hole = b'\0' * (16*4096)
tail = b''.join([(chr(65+(i%26))*4096).encode() for i in range(16,128)])
import hashlib; print(hashlib.md5(head+hole+tail).hexdigest())
")

fallocate -i -o $((16*4096)) -l $((16*4096)) "$MP/f"
sync -f "$MP/f"

echo 3 > /proc/sys/vm/drop_caches
umount -l "$MP"
mount -o loop "$IMG" "$MP"

ACTUAL=$(md5sum "$MP/f" | cut -d' ' -f1)
SIZE=$(stat -c %s "$MP/f")
EXPECTED_SIZE=$(((128 + 16) * 4096))

echo "expected_md5=$EXPECTED"
echo "actual_md5=$ACTUAL"
echo "expected_size=$EXPECTED_SIZE actual_size=$SIZE"

umount "$MP"
rm -f "$IMG"

if [ "$EXPECTED" = "$ACTUAL" ] && [ "$SIZE" = "$EXPECTED_SIZE" ]; then
    echo "PASS: Test B (insert + crash recovery)"
    exit 0
fi
echo "FAIL: Test B"
exit 1
