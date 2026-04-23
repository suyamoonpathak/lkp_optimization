#!/bin/bash
# Compile the three C helpers used by the C4 characterization benches.
set -euo pipefail
cd "$(dirname "$0")"

gcc -O2 -Wall -Wextra -o fallocate_range_helper fallocate_range_helper.c
gcc -O2 -Wall -Wextra -o xattr_block_fsync_helper xattr_block_fsync_helper.c
gcc -O2 -Wall -Wextra -o concurrent_fsync_helper concurrent_fsync_helper.c -lpthread

echo "Built:"
ls -lh fallocate_range_helper xattr_block_fsync_helper concurrent_fsync_helper
