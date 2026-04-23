#!/bin/bash
# C4 characterization driver: builds helpers, runs all three benches
# three times each, drops caches between runs. Run as root:
#
#   sudo bash our_optimization/run_c4_characterization.sh
#
# When it finishes, the results are in:
#   our_optimization/char_results/<uname -r>/{fallocate_*,xattr_block,concurrent_T*}.txt
set -euo pipefail

[ "$(id -u)" = "0" ] || { echo "Run as root (sudo bash $0)"; exit 1; }

cd "$(dirname "$0")"

echo "=== Building helpers ==="
bash build_char_helpers.sh
echo ""

for RUN in 1 2 3; do
    echo "=============================="
    echo " RUN ${RUN}/3 "
    echo "=============================="
    sync && echo 3 > /proc/sys/vm/drop_caches
    bash bench_fallocate_range.sh
    sync && echo 3 > /proc/sys/vm/drop_caches
    bash bench_xattr_block.sh
    sync && echo 3 > /proc/sys/vm/drop_caches
    bash bench_concurrent_fsync.sh
    echo ""
done

echo ""
echo "=== All runs complete ==="
KERNEL="$(uname -r)"
OUT_DIR="char_results/${KERNEL}"
echo "Results directory: $OUT_DIR"
ls -1 "$OUT_DIR"/*.txt 2>/dev/null
echo ""
echo "Each .txt file has 3 lines (one per run). Summary follows:"
for f in "$OUT_DIR"/*.txt; do
    [ -f "$f" ] || continue
    echo "--- $(basename "$f") ---"
    cat "$f"
done
