#!/bin/bash
# Test C: multiple collapse + insert ops interleaved, then crash.
#
# Stress the replay path with a sequence of range-shifting operations.
# Each op fsyncs so the FC log accumulates multiple ADD_RANGE/DEL_RANGE
# entries for the same inode. Verifies the final state after crash
# matches sequential-application semantics.
set -euo pipefail

IMG=/tmp/c4_crashC.img
MP=/mnt/c4_crashC

rm -f "$IMG"
dd if=/dev/zero of="$IMG" bs=1M count=64 status=none
mkfs.ext4 -F -q -O fast_commit "$IMG"
mkdir -p "$MP"
mount -o loop "$IMG" "$MP"

# 200 blocks of 4 KB, each unique via index.
python3 -c "
with open('$MP/f','wb') as f:
    for blk in range(200):
        f.write((bytes([blk & 0xff]) * 4096))
"
sync -f "$MP/f"

# Operations (computed against a pure bytes array for the expected state):
#   1. collapse  4 blocks at offset  80  -> file becomes 196 blocks
#   2. insert    8 blocks at offset  40  -> file becomes 204 blocks
#   3. collapse 12 blocks at offset 100  -> file becomes 192 blocks
EXPECTED=$(python3 <<'PY'
import hashlib
a = b''.join([(bytes([i & 0xff]) * 4096) for i in range(200)])
def collapse(a, off_blk, len_blk):
    return a[:off_blk*4096] + a[(off_blk+len_blk)*4096:]
def insert(a, off_blk, len_blk):
    return a[:off_blk*4096] + b'\0'*(len_blk*4096) + a[off_blk*4096:]
a = collapse(a, 80, 4)
a = insert(a, 40, 8)
a = collapse(a, 100, 12)
print(hashlib.md5(a).hexdigest(), len(a))
PY
)
EXPECTED_MD5=$(echo "$EXPECTED" | awk '{print $1}')
EXPECTED_SIZE=$(echo "$EXPECTED" | awk '{print $2}')

fallocate -c -o $((80*4096))  -l $((4*4096))  "$MP/f"; sync -f "$MP/f"
fallocate -i -o $((40*4096))  -l $((8*4096))  "$MP/f"; sync -f "$MP/f"
fallocate -c -o $((100*4096)) -l $((12*4096)) "$MP/f"; sync -f "$MP/f"

echo 3 > /proc/sys/vm/drop_caches
umount -l "$MP"
mount -o loop "$IMG" "$MP"

ACTUAL_MD5=$(md5sum "$MP/f" | cut -d' ' -f1)
ACTUAL_SIZE=$(stat -c %s "$MP/f")

echo "expected_md5=$EXPECTED_MD5"
echo "actual_md5=$ACTUAL_MD5"
echo "expected_size=$EXPECTED_SIZE actual_size=$ACTUAL_SIZE"

umount "$MP"
rm -f "$IMG"

if [ "$EXPECTED_MD5" = "$ACTUAL_MD5" ] && [ "$ACTUAL_SIZE" = "$EXPECTED_SIZE" ]; then
    echo "PASS: Test C (interleaved collapse+insert + crash recovery)"
    exit 0
fi
echo "FAIL: Test C"
exit 1
