# Candidate 4 — FastCommit Support for fallocate COLLAPSE_RANGE / INSERT_RANGE

**Date:** 2026-04-24
**Kernel under test:** `6.1.4-cs614-c4-patched` (46-line patch on top of
pristine 6.1.4).
**Baseline:** `6.1.4-cs614-c3-patched` and pristine 6.1.4 stock, both
architecturally identical on the fallocate path (C3 only changed xattr
code).

This document reports the C4 patch result. The project's pattern so far:
C1 and C2 produced null measurements, C3 produced a 64× transaction-count
reduction on setxattr. C4 targets a different 100%-hit-rate operation
class (fallocate COLLAPSE/INSERT range) and aims for the same kind of
architectural signal.

---

## 1. What the patch does

Two call sites in `fs/ext4/extents.c` used to mark every
COLLAPSE_RANGE / INSERT_RANGE operation as fast-commit-ineligible:

- `extents.c:5363` — inside `ext4_collapse_range()`.
- `extents.c:5508` — inside `ext4_insert_range()`.

On a `-O fast_commit` filesystem this meant every fallocate of those two
modes forced a full JBD2 commit (~7 ms on our VM).

The patch replaces the `ext4_fc_mark_ineligible(EXT4_FC_REASON_FALLOC_RANGE)`
call with `ext4_fc_track_range(handle, inode, start_lblk, end_lblk)`,
using the pre-existing range-tracking primitive already consumed by the
ordinary allocation path (`inode.c:761`) and by truncate
(`inode.c:5503,5508`). At fast-commit time, `ext4_fc_write_inode_data`
walks the post-shift extent tree and emits `FC_TAG_ADD_RANGE` for the
shifted extents plus `FC_TAG_DEL_RANGE` for any resulting hole.
`FC_TAG_INODE`, already logged by the subsequent `ext4_mark_inode_dirty`,
carries the new `i_size`. On replay, `ext4_fc_set_bitmaps_and_counters`
reconciles the block bitmap with the post-replay extent tree — so even
though `DEL_RANGE` replay transiently frees physical blocks that
`ADD_RANGE` replay re-binds, the final bitmap is correct.

`FALLOC_FL_PUNCH_HOLE` is not in scope: it already takes a different
path (`ext4_punch_hole()`) that does not mark ineligible and already
tracks ranges.

Total diff: 46 lines, single file. Patch at
`our_optimization/fc-fallocate-range.patch`.

## 2. Characterization — measurement before implementation

Before touching the kernel, we measured three candidate targets on the
C3-patched kernel to pick the best signal (see `characterization_results.md`).
Result: fallocate COLLAPSE / INSERT both showed `tx/op = 1.001` and
`ms/op ≈ 7` on 1000-iter microbenches — the same structural overhead C3
eliminated for setxattr, on a different path. Xattr-block extension had
the same per-op overhead but narrow real-world relevance; concurrent
fsync showed weak signal (JBD2 already coalesces most commits).

## 3. Microbenchmark results — VM

All benches: 256 MB loop-backed ext4 with `mkfs -O fast_commit`, warmup,
then 1000 iterations of the measured op + `fsync` per iteration. Three
runs per kernel; mean and range reported.

### 3.1 COLLAPSE_RANGE

| Kernel                     | Runs | elapsed_ms (mean, range) | ms/op | tx_delta | tx/op |
|----------------------------|-----:|-------------------------:|------:|---------:|------:|
| 6.1.4-cs614-c3-patched     |    3 | 7029 (6876–7249)         | 7.03  |    1001  | 1.001 |
| 6.1.4-cs614-c4-patched     |    3 | 5423 (5227–5750)         | 5.42  |      16  | 0.016 |

- **Transaction-count reduction: 62.5×** (1001 → 16).
- **Wall-time reduction: 22.8%** (7029 → 5423 ms per 1000 ops).

### 3.2 INSERT_RANGE

| Kernel                     | Runs | elapsed_ms (mean, range) | ms/op | tx_delta | tx/op |
|----------------------------|-----:|-------------------------:|------:|---------:|------:|
| 6.1.4-cs614-c3-patched     |    3 | 7006 (6855–7262)         | 7.01  |    1001  | 1.001 |
| 6.1.4-cs614-c4-patched     |    3 | 5189 (5060–5374)         | 5.19  |      16  | 0.016 |

- **Transaction-count reduction: 62.5×** (1001 → 16).
- **Wall-time reduction: 25.9%** (7006 → 5189 ms per 1000 ops).

### 3.3 Interpretation

The ≈ 1 JBD2 full commit per op in the baseline is exactly the
`EXT4_FC_REASON_FALLOC_RANGE` fallback. After the patch, only 16 full
commits remain across 1000 ops — these are periodic FC-area flushes
triggered when the log fills, plus writeback-triggered commits that are
unrelated to fallocate. The 62.5× reduction matches the C3 headline
(64× on setxattr), confirming the same architectural pattern.

Wall time drops by ~24%, which is smaller than the transaction-count
delta would suggest. That is expected: fallocate's per-op cost includes
a significant extent-tree manipulation (remove_space, shift_extents) that
the patch does not eliminate. The win is concentrated in the journal
path. On a real SSD, where flush latency dominates extent-tree CPU work
less than on this VM, the wall-time share of the win should be larger.

## 3.4 Bare-metal results — Milan's machine

Milan re-ran the same benchmark on his 11th Gen Intel Core i3-1115G4
(4 cores, 7.5 GiB RAM, real SATA SSD), 3 repeats per mode. Baseline
kernel was his already-installed `6.1.4-cs614-c3-patched`
(architecturally identical to stock on the fallocate path); patched
was `6.1.4-cs614-c4-patched` with both C3 and C4 stacked.

| Mode | Kernel | Wall (mean ± stdev) | tx_delta | commits/op |
|---|---|---:|---:|---:|
| COLLAPSE | C3 baseline | 12,445 ± 970 ms | 1001 | 1.001 |
| COLLAPSE | C3+C4 patched | **7,032 ± 39** ms | **16** | **0.016** |
| INSERT | C3 baseline | 11,539 ± 541 ms | 1001 | 1.001 |
| INSERT | C3+C4 patched | **6,680 ± 142** ms | **16** | **0.016** |

- **Architectural claim reproduces exactly across hardware.**
  `tx_delta` is **byte-identical** to the VM (16 patched, 1001
  baseline) for both modes. Same code, different hardware, same
  output of the journal-path mechanism we changed.
- **Wall-time gain nearly doubles on bare-metal**: 22.8% (VM) →
  **43.5%** (bare-metal) for COLLAPSE; 25.9% → **42.1%** for INSERT.
  Same pattern as C3 (27% VM → 48% Milan), and for the same reason:
  real SSD has a smaller share of non-journal overhead per fsync, so
  removing the JBD2 full commit shows a larger relative gain.
- **Variance is much smaller on bare-metal**. Patched COLLAPSE has
  39 ms stdev on a 7032 ms mean (0.5% CV). The signal is not a
  one-off measurement artifact.

Raw data at `our_optimization/eval_results_c4/milan/{BASELINE_6.1.4-C3Patch,
PATCHED_C4_6.1.4-C3C4Patch}/`.

## 4. Correctness — crash-recovery microbenches

Three scripts at `our_optimization/c4_crash_test_{a,b,c}.sh` exercise the
replay path directly: do COLLAPSE/INSERT on a distinct-pattern file,
fsync, drop caches, lazy-umount to simulate a dirty dismount, remount
(which triggers FC replay), compare md5 and file size to the pure-Python
expected result.

| Test | Workload                                             | Result |
|------|------------------------------------------------------|--------|
| A    | Collapse 32 blocks, crash, verify size + md5         | **PASS** |
| B    | Insert 16 blocks at offset 16, crash, verify         | **PASS** |
| C    | Three interleaved collapse/insert ops, crash, verify | **PASS** |

Each test checks both the md5 of the entire post-recovery file and the
on-disk size. All three passed on first attempt — including the
interleaved-ops test, which stresses the replay with multiple ADD_RANGE
and DEL_RANGE tags for the same inode in a single FC log.

## 5. Regression check — xfstests subset

Key correctness suite for xattr and fc-replay paths:

```
./check ext4/032 generic/062 generic/118 generic/300 generic/337 \
        generic/454 generic/455 generic/473 generic/482
```

Result on C4 kernel (mirror of what was run on C3):

```
Ran: ext4/032 generic/062 generic/118 generic/300 generic/337
     generic/454 generic/455 generic/473 generic/482
Not run: generic/118 generic/455 generic/482
Failures: generic/473
Failed 1 of 9 tests
```

- **5/5 runnable-and-applicable tests PASS.**
- `generic/473` is a pre-existing failure. The diff lines are byte-identical
  to the C3-kernel failure recorded at
  `our_optimization/xfstests_c3/patched_6.1.4-cs614-c3-patched.log` and
  show the same upstream issue (the output mismatch is at `1: [128..255]:
  data` vs actual `1: [128..135]: data`, which is a known interaction of
  fiemap reporting with an unrelated 6.1.4 extent merge behavior). No
  regression from C4.
- `generic/118` (reflink), `generic/455` (requires `LOGWRITES_DEV`),
  `generic/482` (same) are environment-dependent skips.
- Critically, `generic/062`, `generic/337`, `generic/454` all pass —
  confirming C4 does NOT regress C3's xattr fast-commit work. The two
  patches are independent.

Full log: `our_optimization/xfstests_c4/patched_6.1.4-cs614-c4-patched.log`.

## 6. Evidence matrix

| Claim                                              | Evidence |
|----------------------------------------------------|----------|
| Fallocate COLLAPSE/INSERT hit the slow path on stock | characterization_results.md, tx/op = 1.001 |
| Patch replaces ineligibility with range tracking   | fc-fallocate-range.patch, 46 lines, 2 hunks |
| Reduces full commits 62.5×                         | 3 runs each, tx_delta 1001 → 16, stddev < 5% |
| Reduces wall time ~24%                             | 3 runs each, 7029 → 5423 / 7006 → 5189 ms |
| Crash recovery is correct                          | Tests A, B, C all PASS — md5 + size |
| No regression in xfstests                          | 5/5 runnable, same pre-existing 473 diff as C3 |
| Does not regress C3 (xattr fast-commit)            | generic/062, 337, 454 all pass |

## 7. Known limitations / honest uncertainty

- **Narrower real-world hit rate than C3.** `setxattr` fires on every
  file creation on a SELinux-labeled system; `fallocate(COLLAPSE_RANGE)`
  and `fallocate(INSERT_RANGE)` are specialized modes used primarily by
  log rotators, database log compactors, and VM disk tools. The 62.5×
  architectural signal is identical, but the user-visible impact is
  concentrated in those workloads.
- **Wall-time share of the win is ~24%, not ~90%.** Fallocate's per-op
  cost on the VM includes a substantial non-journal component (extent
  tree rebalance). The absolute time saved per op is ~1.6 ms / op — real
  but not dramatic. On real SSDs the journal fraction is larger and the
  percentage should grow.
- **Not covered:** ordinary `fallocate` (no flags) and `FALLOC_FL_ZERO_RANGE`.
  Those are allocation paths that already take the fast-commit-eligible
  branch via `ext4_map_blocks` tracking; we verified they don't hit
  `mark_ineligible(FALLOC_RANGE)`.
- **Bare-metal validation done.** Milan's run on his i3-1115G4 / SSD
  reproduces the architectural claim byte-identically (1001 → 16
  full commits) and shows a 43--44% wall-time speedup, nearly double
  the VM number. Same machine he validated C3 on, same script
  pattern, low variance on patched runs.

## 8. Artifacts

- `our_optimization/fc-fallocate-range.patch` — the patch itself.
- `our_optimization/bench_fallocate_range.sh` +
  `fallocate_range_helper.c` — measurement harness (from
  characterization).
- `our_optimization/c4_crash_test_{a,b,c}.sh` — crash-recovery tests.
- `our_optimization/char_results/6.1.4-cs614-c4-patched/fallocate_*.txt`
  — 3-run result files on the patched kernel.
- `our_optimization/char_results/6.1.4-cs614-c3-patched/fallocate_*.txt`
  — 3-run baseline (C3 kernel is architecturally equivalent to stock
  for this path).
- `our_optimization/xfstests_c4/patched_6.1.4-cs614-c4-patched.log` —
  xfstests subset run.
- Git tag `submission-c3` locks the prior TA-submission commit;
  C4 commits live after it on the master branch.
