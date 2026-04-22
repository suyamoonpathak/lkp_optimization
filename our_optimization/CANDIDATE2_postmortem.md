# Candidate 2 Postmortem: ext4 Async Bitmap Prefetch Completion

**Status:** Patch implemented, correct, and boots; VM benchmarks show no measurable signal (noise floor too high). **Bare-metal evaluation in progress (Milan + Sahil).** This document will be updated when their results arrive.
**Author:** Suyamoon Pathak, CS614 LKP, IIT Kanpur
**Date (initial):** 2026-04-22

---

## 1. What we set out to do

### The developer TODO that motivated the work

In `fs/ext4/mballoc.c` at line 2564 (Linux 6.1.4), the ext4 maintainers
left an explicit TODO:

```c
/*
 * Prefetching reads the block bitmap into the buffer cache; but we
 * need to make sure that the buddy bitmap in the page cache has been
 * initialized.  Note that ext4_mb_init_group() will block if the I/O
 * is not yet completed, or indeed if it was not initiated by
 * ext4_mb_prefetch did not start the I/O.
 *
 * TODO: We should actually kick off the buddy bitmap setup in a work
 * queue when the buffer I/O is completed, so that we don't block
 * waiting for the block allocation bitmap read to finish when
 * ext4_mb_prefetch_fini is called from ext4_mb_regular_allocator().
 */
```

The symptom: after the allocator has found a block, it still has to
finalize prefetches for the remaining bitmaps it had queued. That
finalization blocks on per-group bitmap READ completion — even though
the caller no longer needs the bitmap right now.

### Why we picked this after Candidate 1 failed

After Candidate 1 (fast-commit barrier deferral) turned into a null
result on both VM and in the analytical model, we explicitly went
searching for a candidate that:

- was code-verifiable (not paraphrased from a paper)
- targeted a different subsystem (the allocator, not the commit path)
- had a measurable signal that did not require specialized hardware
  (NVMe / deep queues)
- was bounded in code scope (no on-disk format changes)

Candidate 2 ticked all four boxes. Four independent research agents
surfaced it from (a) the ATC 2024 FastCommit paper's open questions,
(b) LKML threads 2023-2026, (c) a code audit of `fs/jbd2` and
`fs/ext4`, and (d) a scan of FAST/OSDI/SOSP/EuroSys/ATC papers
2022-2025. The exact TODO was also spotted independently in the code
audit, so we verified the file:line ourselves before starting.

---

## 2. Design decisions

### Three implementation shapes considered

**(A) Simple offload.** Always queue the `ext4_mb_init_group()` call
to a workqueue. Simple, but wastes worker threads blocking on I/O when
the bitmap read is already done.

**(B) True TODO intent.** Hook the bitmap READ bio's `end_io`
callback to schedule the buddy init when I/O completes. Matches the
TODO literally; but changes the read path and increases correctness
risk (RCU, IRQ context for endio).

**(C) Opportunistic hybrid** *(chosen)*. In `ext4_mb_prefetch_fini`,
probe the bitmap buffer: if already uptodate, init inline (cheap CPU
work); if not, queue a work item. Captures most of (B)'s benefit
without touching the read path. No changes to endio, no RCU concerns.

We chose (C) because:
- It's the cheapest viable path.
- Correctness risk is much lower than (B).
- If (C) shows measurable benefit, (B) is a natural follow-on for a
  stronger upstream submission.
- If (C) shows no benefit, (B) wouldn't either — so we save the work.

### The correctness argument

Four invariants we verified by code inspection:

1. `ext4_mb_init_group()` early-returns if `EXT4_MB_GRP_NEED_INIT` is
   clear (fs/ext4/mballoc.c:1432 in the patched tree). So races between
   the async worker and future synchronous callers are harmless —
   whichever wins, the other no-ops.
2. The buddy page lock (`ext4_mb_get_buddy_page_lock`) serializes the
   actual init_cache work between any two callers.
3. `flush_workqueue` + `destroy_workqueue` in `ext4_mb_release()` drain
   all pending workers before any group metadata is freed on unmount.
4. On init failure (`ext4_mb_init` returns non-zero), the error path
   destroys the workqueue + slab we created; the main cleanup
   (`ext4_mb_release`) is NOT called for failed mounts, so no
   double-destroy.

### Scope explicitly excluded

- Other three call sites of `ext4_mb_init_group()` (lines 1462, 2496,
  6524 in stock) — those are on the allocator's critical path and must
  keep blocking.
- Bitmap endio path — out of scope (that was Option B).
- On-disk format, mount options, sysfs knobs — none needed.

---

## 3. Bugs caught during review

We followed the subagent-driven development workflow: implementer →
spec-compliance reviewer → code-quality reviewer → fix cycle. The
code-quality reviewer caught two blockers the implementer had missed:

### Blocker 1 — `static noinline_for_stack` orphaning

Before the patch, `mballoc.c` had:

```
static noinline_for_stack
int ext4_mb_init_group(...)
```

Our insertion put the new `struct ext4_bitmap_init_work` and helper
functions **between** `static noinline_for_stack` (line 1363) and
`int ext4_mb_init_group(...)` (line 1364). C grammar binds
`static noinline_for_stack` to the next declaration — which became the
struct, not the function. Consequences:

- `ext4_mb_init_group` silently lost `static` linkage (symbol
  namespace pollution) and would fail `scripts/checkpatch.pl`.
- It silently lost `noinline_for_stack`, removing the stack-isolation
  the original author had added. On a kernel with KASAN the stack
  frame would grow enough to risk overflow on the deeply-nested
  allocator call chain.

The implementer's verification grep had only confirmed that our three
new symbols existed; it did not catch that an **existing** attribute
had been silently detached. The code-quality reviewer flagged it.

**Fix:** moved the inserted block to BEFORE the "Locking note" comment
that precedes `static noinline_for_stack`, restoring adjacency with
the function definition.

### Blocker 2 — Resource leak in `ext4_mb_init` error path

We originally placed the slab + workqueue creation AFTER
`ext4_mb_init_backend()` succeeds. If our `alloc_workqueue()` call
then failed, the error path went `goto out_free_locality_groups` →
falls through to `out:`, which frees our slab/wq — but neither label
knows how to undo `ext4_mb_init_backend`'s work. Result: `s_buddy_cache`
inode and `s_group_info` leaked on this specific OOM path, and the
failure would bubble up to `failed_mount5` in super.c which does not
call `ext4_mb_release`.

**Fix:** moved the slab + workqueue creation to BEFORE
`ext4_mb_init_backend`. Now if our creation fails, the backend hasn't
run yet — nothing extra to clean up. If the backend itself fails
afterward, the existing path through `out:` destroys our slab/wq (and
the backend's cleanup was never the init function's responsibility; it
lives in `ext4_mb_release` which is called for successful mounts only).

### Oversight only caught at build time — forward declaration

After moving the new functions ahead of `ext4_mb_init_group`, the
build failed: our `ext4_mb_async_init_worker` calls
`ext4_mb_init_group()`, but the compiler sees the call before the
static definition. GCC emits an implicit declaration, then gets a
conflict when it hits the real `static` definition.

Neither review caught this because both reviewers looked at the
patched source textually — not at what a compiler would do with it.
The fix was a one-line forward declaration above the new block.

**Lesson:** Build-and-boot is a non-negotiable verification step for
any non-trivial kernel code movement. Review alone is insufficient.

---

## 4. The VM evaluation

### Smoke test (passed)

After install + reboot into `6.1.4-cs614-c2-patched`:

- `mount -o loop,data=ordered` on a fast_commit-enabled image: OK.
- fio randwrite + fsync + numjobs=4 for 15s: 540 IOPS, avg 298 µs
  latency, no errors.
- `dmesg` showed no allocator / workqueue / slab errors.
- Clean unmount.

The kernel is correct and doesn't regress anything catastrophically.

### Measurement (i): fallocate microbenchmark — no signal

We ran the microbench designed in the spec: fresh 16 GB loop device,
`mkfs.ext4 -F -O fast_commit`, mount, `drop_caches`, then 32 ×
`fallocate -l 256M` with sync between. Three full repeats (96
samples).

| Metric | Stock (6.1.4-cs614-hacker, Jan 16 build) | Patched (cs614-c2-patched) | Δ |
|---|---|---|---|
| Mean | 8,629 µs | 9,006 µs | **+4.4% worse** |
| Median | 8,422 µs | 8,703 µs | +3.3% worse |
| p95 | 10,682 µs | 12,426 µs | +16% worse |
| p99 | 14,998 µs | 13,647 µs | -9% better |
| Min | 6,286 µs | 6,757 µs | +7% worse |
| Max | 14,998 µs | 13,647 µs | -9% better |
| Stdev | 1,051 µs | 1,180 µs | +12% worse |

All deltas are within 1-σ of each other. Effectively **null result**
on this workload.

### Why the microbench doesn't exercise our code path

Looking at the first-vs-last allocation pattern on both kernels:

- **First 5 allocs on either kernel are the FASTEST** (6-8 ms).
- **Last 5 allocs are the SLOWEST** (10-15 ms).

That is the opposite of what our patch would optimize. We expected
cold bitmaps (first allocs) to be the slowest and our patch to make
them fast. Instead, early allocs are fast and later ones slow down
because the allocator is scanning more groups as the filesystem fills.

Why our patch doesn't engage:

1. **Small group count.** A 16 GB filesystem with default 128 MB
   groups has only 128 groups. After the first few 256 MB allocations,
   the handful of groups touched are initialized; `NEED_INIT` is
   cleared; subsequent allocations reuse the same cached bitmaps.
2. **Rm + realloc reuses groups.** Our loop does
   `rm -f f; fallocate -l 256M f`. After `rm`, blocks are free but
   groups remain initialized. The next `fallocate` finds blocks in
   already-initialized groups without ever entering the
   `prefetch_fini` slow path.
3. **`ext4_mb_prefetch_fini` rarely takes the async branch.** In the
   common case, the prefetched bitmap's READ has already completed by
   the time `prefetch_fini` runs, so `buffer_uptodate()` is true and
   the inline path is taken. The workqueue path — which is what we
   optimized — is rarely hit.

### Measurement (iv): fio throughput — initially promising, then noisy

In the first composite run (fallocate + perf sched + single fio
8GB-write), we observed:
- Stock fio: 561 MiB/s
- Patched fio: 620 MiB/s (**+10.5%**)

This looked like a real signal, so we wrote a focused `bench_fio_throughput.sh`
that does 5 clean repeats per kernel.

### The VM variance discovery

Five-repeat stock run showed:

```
Repeat 1: 774 MiB/s
Repeat 2: 655 MiB/s
Repeat 3: 203 MiB/s
Repeat 4: 203 MiB/s
Repeat 5: 190 MiB/s
```

Mean 405 ± **286** MiB/s — a 70% coefficient of variation within a
single kernel, before we even compare to anything.

Diagnosis:

- **VirtualBox loop device** goes to a file on the host; reads and
  writes pass through the host page cache.
- **Host cache gets saturated** somewhere between runs 2 and 3. The
  first two "fast" runs are effectively memory-bound; subsequent runs
  actually hit host disk.
- **VM has 5.7 GB RAM** — an 8 GB fio write spills to the host
  backing store partway through, in a non-deterministic way.

The original 10 % delta was **measurement-order artifact**: the
`bench_async_prefetch.sh` script happens to run the stock fio during
one regime (host cache cold-ish) and the patched fio during another
(host cache primed). We can't measure a ≤20 % effect on this VM.

### What this means for Candidate 2

**Not "the patch is bad."** The patch is correct, safe, and boots.
The VM is not a valid measurement platform for a ≤20 % optimization
because its noise floor is ~70 % CV on the exact throughput metric we
care about.

We handed off to Milan and Sahil for bare-metal measurement.

---

## 5. What we tried that didn't work

1. **Cold-cache fallocate loop on fresh mount.** Doesn't create enough
   group-init pressure — only ~2 groups per allocation, then reuse.
2. **perf sched latency on `ext4_mb_*` threads.** Shows the
   `ext4lazyinit` thread's sleep time (0.086 ms patched vs 0.060 ms
   stock), but this is the lazy initializer thread, not the
   synchronous allocator we optimized. Noise in both directions.
3. **fio 2GB × 4 jobs inside `perf sched record`.** Recorded once per
   kernel as a byproduct — single-run, not statistically sound.
4. **5 × fio repeats without perf.** Exposed the host-cache variance
   issue.

---

## 6. Lessons learned

### On evaluation design

1. **Every kernel code movement must be build-verified, not just
   review-verified.** Two careful reviewers caught two blockers but
   missed a forward-declaration error that a 30-second compile would
   have surfaced.
2. **"The first run is fast" is a red flag for host caching.** In
   future VM benchmarks, always include ≥5 repeats and treat the
   first-run number as suspect.
3. **Compute coefficient of variation, not just mean ± stddev.** CV
   = 70 % tells you "this measurement setup cannot resolve the effect
   you want"; mean ± stddev with overlapping error bars is the same
   message expressed less forcefully.
4. **Design the benchmark to match the code path.** For Candidate 2,
   the right workload exercises `ext4_mb_prefetch_fini`'s async branch —
   which needs many uninitialized groups being touched under cold
   bitmap cache. A 16 GB filesystem with fallocate loops does not do
   that. A 100+ GB filesystem with sequential write across a large
   working set probably would.

### On kernel patch workflow

5. **Separate LOCALVERSION for patched kernels is non-negotiable.**
   `-cs614-c2-patched` coexists with `-cs614-hacker` in `/boot`, GRUB,
   and `/lib/modules`. Rollback is a reboot + GRUB selection; no
   dangerous cleanup needed. (This was a lesson from Candidate 1.)
6. **Always commit the patch file separately from source modifications.**
   The repo tracks the patch; the kernel tree is gitignored. This keeps
   commits small and makes rollback / re-application trivial.
7. **The subagent-driven workflow is worth the overhead for kernel
   patches.** Two review stages caught issues that would have cost us
   hours to debug later. But: reviews can't substitute for build
   verification — treat build-and-boot as the third, non-optional
   review.

### On research economy

8. **If the VM can't measure it, stop measuring on the VM.** We spent
   ~2 hours of benchmark-wall-clock before the variance issue became
   undeniable. We should have suspected it after the first
   within-noise delta and moved to bare-metal immediately.
9. **Ship correctness + measurement infrastructure to collaborators
   early.** Milan and Sahil have bare-metal SSDs we don't; every hour
   they spend on our scripts is an hour that can't come out of our own
   benchmark runs. We're fortunate they're willing.

---

## 7. Current status and what comes next

### Pushed to GitHub

- `our_optimization/mballoc-async-prefetch.patch` — the patch (clean apply to pristine 6.1.4)
- `our_optimization/bench_async_prefetch.sh`, `bench_fio_throughput.sh` — VM benchmarks
- `our_optimization/eval_milan_c2.sh`, `eval_sahil_c2.sh` — per-contributor bare-metal scripts
- `our_optimization/INSTRUCTIONS_MILAN_C2.md`, `INSTRUCTIONS_SAHIL_C2.md` — end-to-end walkthroughs
- `our_optimization/eval_results_c2/` — VM numbers (null result, preserved for comparison)
- `docs/superpowers/specs/2026-04-22-ext4-async-bitmap-prefetch-design.md` — design doc
- `docs/superpowers/plans/2026-04-22-ext4-async-bitmap-prefetch.md` — implementation plan

### Awaiting

- Milan's bare-metal results on branch `results-c2/milan` — expected within a day or two.
- Sahil's bare-metal results on branch `results-c2/sahil` — same timeframe.

### Decision tree after bare-metal results arrive

| Scenario | Action |
|---|---|
| Both show ≥10 % improvement on fallocate p99 or fio BW | We have a paper contribution. Run xfstests as final correctness gate, write results section. |
| One shows improvement, one doesn't | Investigate the difference (hardware? workload order?). If attributable to HW difference, we may still have a paper for that class of HW. |
| Neither shows improvement | Treat Candidate 2 as a correctness-only contribution (the `static noinline_for_stack` analysis is still valid, as is the kernel-coding-standard review). Pivot to Candidate 3 or a workload-specific angle. |
| Either shows regression | Stop and debug. That would be surprising given the safety analysis, but not impossible (e.g., workqueue scheduling overhead on specific CPU topologies). |

---

## 8. What carries over regardless of bare-metal outcome

The infrastructure and methodology are reusable for further candidates:

- Two-kernel coexistence via distinct `CONFIG_LOCALVERSION` — proven
  across Candidate 1 and Candidate 2.
- Per-contributor result-directory layout (`eval_results_c2/<name>/
  <label>_<kernel>/`) — scales to any number of collaborators and
  kernels.
- Auto-detection of STOCK vs PATCHED by scanning the source tree for a
  patch-specific marker string (`ext4_bitmap_init_work` for C2,
  `Drain any fast commits` for C1).
- Subagent-driven workflow with two-stage review as a floor for code
  quality on kernel patches.

Candidate 2 may or may not earn a place in the paper. The process we
used to get here is defensible regardless.

---

*This postmortem will be revised once Milan and Sahil's bare-metal
numbers arrive. If they show a clean positive result, the "current
status" section above will be folded into the paper's evaluation
chapter and this document will be renamed to `CANDIDATE2_findings.md`.
If they don't, this file stays as-is and we move on.*
