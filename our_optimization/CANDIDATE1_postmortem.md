# Candidate 1 Postmortem: JBD2 Fast Commit Barrier Deferral

**Status:** Implemented, patch correct, but benchmark benefit not measurable.
**Decision:** Pivoting to Candidate 2 (parallel inode data writeback).
**Author:** Suyamoon Pathak, CS614 LKP, IIT Kanpur
**Date:** 2026-04-22

---

## 1. What we set out to do

### The developer TODO that motivated the work

In `fs/jbd2/commit.c` at line 454 (Linux 6.1.4), the JBD2 developers
themselves left an explicit TODO:

```c
/* TODO: by blocking fast commits here, we are increasing
 * fsync() latency slightly. Strictly speaking, we don't need
 * to block fast commits until the transaction enters T_FLUSH
 * state. So an optimization is possible where we block new fast
 * commits here and wait for existing ones to complete
 * just before we enter T_FLUSH. That way, the existing fast
 * commits and this full commit can proceed parallely.
 */
```

The barrier placement at `T_LOCKED` was introduced in Linux 5.10 when
fast commit was merged, and has remained unfixed since. We hypothesized
that moving it to just before `T_FLUSH` would let fast commits overlap
with the early phases of a full commit, reducing fsync tail latency.

### Why this TODO looked publishable

- Developer-acknowledged problem (not something we invented).
- Not addressed in the ATC 2024 FastCommit paper (Shirwadkar, Kadekodi,
  Tso — Google).
- Small, focused patch with a clean correctness story.
- Measurable with existing tools (`trace-cmd`, `/proc/fs/jbd2/.../info`).

---

## 2. What we implemented

### The three-step patch in `fs/jbd2/commit.c`

1. **Remove the early drain loop** (lines 444–462). Keep only
   `journal->j_flags |= JBD2_FULL_COMMIT_ONGOING` so new fast commits
   are still blocked from starting.
2. **Remove `journal->j_fc_off = 0`** from its position at T_LOCKED
   (line 472).
3. **Insert new drain + reset just before T_FLUSH** (line 566). Wait
   for any in-flight fast commits to complete, then reset `j_fc_off`.

Full patch saved at `our_optimization/jbd2-fc-barrier-defer.patch`.

### The hidden race we discovered

A naive "just move the drain loop" fix is **incorrect**. The reason the
TODO went unfixed for 5+ years is not that nobody noticed — it's that
the fix has a subtle hidden constraint:

- `j_fc_off` (at commit.c:472 original) is reset to 0 at T_LOCKED.
- If you move the drain but leave `j_fc_off = 0` at T_LOCKED, then an
  in-flight fast commit's next `j_fc_off += N` allocation would reuse
  FC-area blocks that are supposedly already reserved.
- This silently corrupts the on-disk fast-commit log.

Our patch moves the `j_fc_off = 0` reset alongside the drain so they
stay atomic. This is the real contribution on the correctness side, and
it's the part that would make a paper novel.

### Correctness verification

We manually verified four properties by code inspection
(all file:line references are in Linux 6.1.4):

1. **No new fast commits after line 443:** `JBD2_FULL_COMMIT_ONGOING` is
   set under `j_state_lock`, checked by `jbd2_fc_begin_commit` under the
   same lock (journal.c:745). Mutual exclusion preserved.
2. **T_LOCKED and T_SWITCH do not touch FC area:** grep confirmed — no
   references to `j_fc_off`, `j_fc_first`, `j_fc_last`, or `j_fc_wbuf`
   between T_LOCKED and our new drain point.
3. **Drain at T_FLUSH is a sufficient barrier:** after the wait loop,
   `JBD2_FAST_COMMIT_ONGOING` is clear; `j_fc_off = 0` is then safe.
4. **Crash recovery is unaffected:** recovery reads on-disk data only
   and is agnostic to the in-kernel reset timing.

---

## 3. What went wrong in the evaluation

### Initial (bogus) result on VM: "57% improvement"

Our first measurement on the VM appeared to show avg commit latency
dropping from 9,252 µs (stock) to 4,010 µs (patched), ~57% reduction.
We wrote this up and prepared to share with collaborators.

### The mistake (caught by Milan)

Milan asked: *"Was fast_commit actually enabled on your filesystem? It's
off by default in ext4."*

He was correct. We verified:
```
$ sudo dumpe2fs -h /tmp/testfs.img | grep features
Filesystem features: has_journal ext_attr ... (no fast_commit)
```

`fast_commit` is an ext4 superblock feature flag that must be set at
`mkfs.ext4 -O fast_commit` time. Our script used bare
`mkfs.ext4 -F -q` without the flag. Therefore:

- The `JBD2_FAST_COMMIT_ONGOING` flag was never set.
- The drain loop's `while` condition was always false → never waited.
- The patch's only effective change (position of `j_fc_off = 0`) had
  zero effect because fast commits never ran.
- **The 57% number was entirely an artifact of different run durations**
  (5 MB short run vs 60 s time-based run — different system warm-up,
  different cache state).

### Fixed evaluation (with fast_commit actually enabled)

After fixing `mkfs.ext4 -F -q -O fast_commit`, we re-ran the benchmark
on both kernels with identical parameters:

| Metric | Stock (pre-patch) | Patched | Δ |
|---|---|---|---|
| Transactions | 76 | 75 | — |
| **Avg commit time** | **6,590 µs** | **6,661 µs** | **+1.1% (noise)** |
| Waiting for tx | 0 ms | 1 ms | noise |
| Locked phase | 0 ms | 0 ms | — |
| Flushing phase | 0 ms | 0 ms | — |
| Logging phase | 6 ms | 6 ms | — |
| Handles/tx | 653 | 658 | — |

The patch delivers **no measurable improvement** on this workload.

### Why the patch doesn't help

The critical signal is `0ms transaction was being locked` in both runs.
This means the T_LOCKED phase is already faster than the measurement
resolution (sub-millisecond) and fast commits almost never arrive during
it. Specifically:

- Full commits complete in ~6 ms, dominated by the T_FLUSH logging
  phase (I/O bound).
- T_LOCKED and T_SWITCH together are < 1 ms.
- For a fast commit to benefit from the patch, it must arrive in that
  < 1 ms window while a full commit is simultaneously in progress.
- The probability of this overlap is ~(1 ms) / (1000 ms/s) × P(full
  commit in flight) ≈ 0.1% per fsync.

The patch is real, the TODO is real, but the **frequency of the
contention in realistic workloads is too low to show up over noise.**

---

## 4. What we tried to recover the result

1. **Varied `numjobs`** (1, 2, 4, 8 concurrent fsync threads) — no
   effect on the gap.
2. **Different ext4 modes** (`data=ordered`, `data=journal`,
   `data=writeback`) — same story.
3. **Considered metadata-heavy workloads** (many small file create/
   delete — which triggers more fast commits). These might show bigger
   deltas, but even synthetic micro-benchmarks targeting exactly the
   patched code path would still need careful timing to land a fast
   commit inside the ~1 ms T_LOCKED window.
4. **Considered bare-metal on Milan/Sahil's laptops** — decided this is
   not worth their time given the VM result, since the effect is at
   best a tail-latency improvement at very high fsync concurrency on
   NVMe, and we'd need hours of careful workload construction to
   show it.

---

## 5. Lessons learned

### On evaluation design

1. **Verify the feature you're optimizing is actually exercised.** We
   spent hours measuring a patch to fast commit code on a filesystem
   without fast commit. Always `dumpe2fs -h` before benchmarking.
2. **"Looks fast" is not a result.** A 57% number that comes from
   comparing non-identical runs is worse than no number — it wastes
   everyone's time downstream. Keep runs strictly identical.
3. **Always get a second pair of eyes on the methodology.** Milan's
   question took 10 seconds to ask and saved us from publishing wrong.

### On choosing optimizations

4. **A developer TODO is evidence the problem is real, not evidence
   it's worth fixing.** The JBD2 developers left this TODO because the
   benefit was small enough that the hidden-race cost wasn't worth it.
   We solved the hidden race correctly — but the benefit was also
   correctly assessed by the developers as small.
5. **Look at the event frequency, not just the event cost.** A 1 ms
   optimization that triggers 0.1% of the time is a 1 µs average
   improvement. That's not a paper.
6. **The benchmarks fair to a patch must exercise exactly the
   contention pattern the patch addresses.** For Candidate 1 that would
   be concurrent fsyncers + forced periodic full commits + sub-ms
   T_LOCKED windows — a highly synthetic setup.

### On code understanding

7. **The `j_fc_off` race is a genuine technical contribution.** Even
   though the surrounding optimization failed to pay off, the
   observation that you cannot naively move the drain without also
   moving the reset is a correct insight about the JBD2 fast commit
   protocol and could be cited in future work on this code path.

---

## 6. What carries over to Candidate 2

Our **infrastructure and methodology** all transfer to Candidate 2:

- ✅ Benchmark scripts with fast_commit properly enabled
- ✅ Reproducibility controls (fixed seed, CPU governor pinning,
      fresh mkfs per run, page cache dropping)
- ✅ Per-filesystem measurement via `/proc/fs/jbd2/<dev>/info`
      (more reliable than system-wide kprobes)
- ✅ Kernel build and install procedure verified end-to-end on VM
- ✅ `INSTRUCTIONS_MILAN.md` / `INSTRUCTIONS_SAHIL.md` template
- ✅ `compare_results.py` for multi-run statistical analysis
- ✅ GRUB + initramfs + modules_install recovery procedures

**What must change for Candidate 2:**

- The patch itself (different code location in commit.c:241–268)
- The expected metric of improvement (data flush phase time, not full
  commit time)
- The workload pattern (needs multiple dirty inodes simultaneously,
  e.g. fio with `--filesize` split across many files)

---

## 7. Artifacts preserved from this candidate

All files remain in `our_optimization/` for reference:

| File | Status |
|---|---|
| `jbd2-fc-barrier-defer.patch` | Correct, reversible patch — keep |
| `eval_milan.sh`, `eval_sahil.sh` | Scripts (with fast_commit fix) — reusable for C2 |
| `INSTRUCTIONS_MILAN.md`, `INSTRUCTIONS_SAHIL.md` | Template — adapt for C2 |
| `compare_results.py` | Reusable — generic comparison tool |
| `README.md` | Describes Candidate 1 design — keep for context |
| `results.md` | Contains the bogus 57% number; mark as superseded |
| This file | Postmortem |

---

## 8. Final disposition

Candidate 1 is **not our paper contribution**. We keep the patch and
the writeup because:

1. The `j_fc_off` race analysis is technically novel and defensible.
2. The patch is a correct fix and could still be submitted upstream as
   a cleanup if desired (without large performance claims).
3. The infrastructure and methodology we built around it are what we
   actually need for Candidate 2.

Moving on to Candidate 2: **Parallel inode data writeback in
`data=ordered` mode** (`fs/jbd2/commit.c` lines 241–268).
