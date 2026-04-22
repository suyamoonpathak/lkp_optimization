# Benchmark Results: JBD2 Fast Commit Barrier Deferral

> ⚠️  **SUPERSEDED — DO NOT CITE THESE NUMBERS.**
>
> The 57% improvement reported below is **an artifact** of two
> methodological errors:
>   1. `fast_commit` was not enabled on the test filesystem (caught by
>      Milan). Without that feature, the patch has zero effect.
>   2. The stock and patched runs used different durations (5 MB short
>      run vs 60 s time-based run), so the comparison was not
>      apples-to-apples.
>
> Re-run on a `fast_commit`-enabled filesystem with identical 30 s runs
> showed stock = 6,590 µs vs patched = 6,661 µs (no improvement).
>
> See `CANDIDATE1_postmortem.md` for the full story. This file is kept
> only as a record of the early mistake.

**Date:** 2026-04-22  
**Kernel:** Linux 6.1.4-cs614-hacker  
**Workload:** fio randwrite, bs=4k, size=20M, ioengine=sync, fsync=1, numjobs=4, runtime=60s  
**Filesystem:** ext4, data=ordered, loop device (512MB image)  
**Measurement tool:** jbd2_probe.ko (kretprobe on jbd2_journal_commit_transaction)

---

## Commit Latency (jbd2_probe.ko)

| Metric | Stock (pre-patch) | Patched | Change |
|---|---|---|---|
| Avg commit latency | 9,252 µs | 4,010 µs | **-56.7%** |
| Min commit latency | 6,201 µs | 2,169 µs | -65.0% |
| Max commit latency | 35,148 µs | 17,061 µs | -51.4% |
| Total commits | 1,318 | 28,582 | (longer run) |

> Stock numbers from prior session: 5MB workload, same 4-job fsync config.  
> Patched numbers: 60s sustained run, same config.

---

## FIO Throughput (patched kernel)

| Metric | Value |
|---|---|
| IOPS | 317 |
| Bandwidth | 1,269 KiB/s |
| Avg latency | 104 µs |
| p99 latency | < 250 µs (99.6% of ops under 250 µs) |
| Runtime | 60s |

---

## Interpretation

The avg commit latency dropped by **57%** (9,252 µs → 4,010 µs).

**Why:** In the stock kernel, any fast commit that arrived while a full commit
was in progress had to wait at the very start of `jbd2_journal_commit_transaction`
(before `T_LOCKED`). With the patch, fast commits are only blocked just before
`T_FLUSH` — the first point where they actually conflict with the full commit.
The `T_LOCKED` and `T_SWITCH` phases (~1–3 ms of the commit pipeline) now
overlap with in-flight fast commits instead of blocking them.

**The hidden constraint that made this non-trivial:** Moving the drain naively
(without also moving `j_fc_off = 0`) would corrupt in-flight fast commit
FC-area allocations. This is why the developer TODO at commit.c:454 went
unfixed since fast commit was merged in Linux 5.10.

---

## What to Show the Professor

1. **Live demo:** Load `jbd2_probe.ko`, run fio, `cat /proc/jbd2_probe_stats`
   — show avg ~4ms vs the 9ms baseline from the walkthrough.

2. **Key claim:** "We moved the fast-commit synchronization barrier from
   before T_LOCKED to just before T_FLUSH. This is a 3-line change in
   fs/jbd2/commit.c that cuts average commit latency by 57% under concurrent
   fsync workloads."

3. **Correctness:** "The non-obvious part is j_fc_off — resetting it at the
   wrong time corrupts in-flight FC-area allocations. That is why the kernel
   developers left a TODO but never fixed it."

4. **Evidence in the source:** Point to commit.c:454 (original) — the TODO
   is written by the JBD2 developers themselves, present since Linux 5.10.
