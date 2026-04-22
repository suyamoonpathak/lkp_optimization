# Async Bitmap Prefetch Completion in ext4 Block Allocator

**Date:** 2026-04-22
**Author:** Suyamoon Pathak (CS614 LKP, IIT Kanpur)
**Target kernel:** Linux 6.1.4
**Status:** Design approved; plan to be written next.

---

## 1. Motivation

The ext4 block allocator (`fs/ext4/mballoc.c`) contains an explicit developer
TODO acknowledging a performance issue on the allocation path. Every
allocation that passes through `ext4_mb_regular_allocator()` and triggers
bitmap prefetching ends with a call to `ext4_mb_prefetch_fini()`, which
**blocks the allocator** while bitmap reads complete and buddy structures
are built.

The TODO, verbatim (`fs/ext4/mballoc.c:2564–2567`):

> TODO: We should actually kick off the buddy bitmap setup in a work queue
> when the buffer I/O is completed, so that we don't block waiting for the
> block allocation bitmap read to finish when `ext4_mb_prefetch_fini` is
> called from `ext4_mb_regular_allocator`.

This design implements the pragmatic middle ground ("Option C" in our
brainstorming): an **opportunistic async path** that does the init
synchronously if the bitmap is already cached, and defers to a workqueue
otherwise.

### 1.1 Why this is worth doing

- **Direct developer TODO** — not our speculation; the JBD2/ext4 maintainers
  identified this themselves.
- **Self-contained** — the change is confined to `fs/ext4/mballoc.c` plus
  small additions to `struct ext4_sb_info`. No on-disk format change. No
  new mount options. No compat bits.
- **Measurable** — allocation wall-time and `perf sched` allocator sleep
  time are both directly observable at the function boundary.
- **Paper-worthy** — we can cleanly characterize it as "sync-to-async
  bitmap prefetch completion in the ext4 allocator; tail-latency reduction
  on cold-cache workloads."

### 1.2 Why Option C (not A or B)

Three shapes were considered during brainstorming:

- **(A)** Always offload `prefetch_fini`'s work to the queue. Simple but
  wastes worker threads blocking on I/O when the bitmap read is already
  done.
- **(B)** Hook into the bitmap READ bio's `end_io` callback to trigger the
  init. Matches the TODO's exact wording, but changes the read path and
  increases correctness risk.
- **(C, chosen)** Opportunistic — check if the bitmap page is already
  uptodate; if yes, init inline (cheap); if no, defer via workqueue. No
  change to the read path. Lower correctness risk than (B). Captures
  essentially the same benefit as (B) because most of the time, by the
  moment `prefetch_fini` runs, the READ bios are already complete.

---

## 2. Code context (verified)

All line numbers below are against Linux 6.1.4.

### 2.1 The allocator loop

`ext4_mb_regular_allocator()` at `fs/ext4/mballoc.c:2592` walks block
groups looking for a good one. Inside the loop it calls
`ext4_mb_prefetch()` (line 2697) to kick off async bitmap READs for the
next batch of groups. When the allocator finishes, at line 2787 it calls:

```c
if (nr)
    ext4_mb_prefetch_fini(sb, prefetch_grp, nr);
```

`nr` is the number of groups whose bitmaps were submitted for read but may
not have been used. `prefetch_grp` is the starting group.

### 2.2 The blocking point

`ext4_mb_prefetch_fini()` at `fs/ext4/mballoc.c:2569` iterates `nr`
groups and calls:

```c
if (ext4_mb_init_group(sb, group, GFP_NOFS))
    break;
```

`ext4_mb_init_group()` at `fs/ext4/mballoc.c:1364` calls
`ext4_mb_init_cache()` (line 1394). `ext4_mb_init_cache()` reads the
bitmap via the buffer cache and waits for the bitmap's buffer head to
become uptodate before it can build the buddy structures. If the
bitmap READ issued by `ext4_mb_prefetch()` hasn't completed yet, this
wait sleeps.

### 2.3 Other call sites of `ext4_mb_init_group()`

Lines 1462 (from `ext4_mb_load_buddy_gfp`), 2496
(`ext4_mb_good_group_nolock`), and 6524 also call this function. **These
are NOT touched** by this design — they are on the critical allocation
path and need the bitmap to make progress.

---

## 3. Design

### 3.1 New state in `struct ext4_sb_info`

Two additions (in `fs/ext4/ext4.h`, appended to the existing struct):

```c
/* Async bitmap init support (see mballoc.c:ext4_mb_prefetch_fini) */
struct workqueue_struct *s_bitmap_init_wq;
struct kmem_cache       *s_bitmap_init_slab;
```

The workqueue is single-threaded per-sb (`alloc_workqueue` with
`WQ_UNBOUND | WQ_MEM_RECLAIM`, max_active=1). Rationale:
- `WQ_UNBOUND` — work items may block on I/O; we don't want to pin
  them to a specific CPU.
- `WQ_MEM_RECLAIM` — we call into this path from allocator with
  `GFP_NOFS`; the workqueue must be able to make progress under
  memory pressure.
- max_active=1 — parallel bitmap init across groups doesn't help; groups
  are independent and the work is cheap. Keeps worker count bounded.

### 3.2 New work-item type (in `fs/ext4/mballoc.c`)

```c
struct ext4_bitmap_init_work {
    struct work_struct  work;
    struct super_block *sb;
    ext4_group_t        group;
};
```

Allocated from the per-sb slab cache.

### 3.3 Worker function (new, in `fs/ext4/mballoc.c`)

```c
static void ext4_mb_async_init_worker(struct work_struct *work)
{
    struct ext4_bitmap_init_work *w =
        container_of(work, struct ext4_bitmap_init_work, work);

    /*
     * Re-check NEED_INIT under the buddy page lock inside
     * ext4_mb_init_group(); it no-ops if someone else got there
     * first (existing behavior at mballoc.c:1385).
     */
    ext4_mb_init_group(w->sb, w->group, GFP_NOFS);

    kmem_cache_free(EXT4_SB(w->sb)->s_bitmap_init_slab, w);
}
```

Errors from `ext4_mb_init_group()` are intentionally ignored here. The
`EXT4_GROUP_INFO_NEED_INIT_BIT` flag stays set on failure, so the next
allocator call touching this group retries synchronously (same as
today's behavior on I/O error).

### 3.4 Dispatch helper (new, in `fs/ext4/mballoc.c`)

```c
static void ext4_mb_schedule_async_init(struct super_block *sb,
                                        ext4_group_t group)
{
    struct ext4_sb_info *sbi = EXT4_SB(sb);
    struct ext4_bitmap_init_work *w;

    w = kmem_cache_alloc(sbi->s_bitmap_init_slab, GFP_NOFS);
    if (!w) {
        /* fallback: do it synchronously — no worse than today */
        ext4_mb_init_group(sb, group, GFP_NOFS);
        return;
    }
    INIT_WORK(&w->work, ext4_mb_async_init_worker);
    w->sb    = sb;
    w->group = group;
    queue_work(sbi->s_bitmap_init_wq, &w->work);
}
```

### 3.5 Modified `ext4_mb_prefetch_fini()`

Current body (lines 2569–2590) iterates each candidate group and calls
`ext4_mb_init_group()` synchronously. New body adds a cache-uptodate
probe:

```c
void ext4_mb_prefetch_fini(struct super_block *sb, ext4_group_t group,
                           unsigned int nr)
{
    while (nr-- > 0) {
        struct ext4_group_desc *gdp = ext4_get_group_desc(sb, group, NULL);
        struct ext4_group_info *grp;
        struct buffer_head     *bh;

        if (!group)
            group = ext4_get_groups_count(sb);
        group--;
        grp = ext4_get_group_info(sb, group);

        if (!(EXT4_MB_GRP_NEED_INIT(grp) &&
              ext4_free_group_clusters(sb, gdp) > 0 &&
              !(ext4_has_group_desc_csum(sb) &&
                (gdp->bg_flags & cpu_to_le16(EXT4_BG_BLOCK_UNINIT)))))
            continue;

        /*
         * Opportunistic: if the bitmap page is already uptodate, do
         * the buddy setup inline — it is cheap once the page is in
         * memory. Otherwise, defer to the per-sb workqueue so the
         * caller (ext4_mb_regular_allocator) does not sleep on I/O.
         */
        bh = ext4_read_block_bitmap_nowait(sb, group, false);
        if (!IS_ERR_OR_NULL(bh) && buffer_uptodate(bh)) {
            /* fast path: page in cache, no I/O wait */
            if (ext4_mb_init_group(sb, group, GFP_NOFS)) {
                brelse(bh);
                break;
            }
        } else {
            /* slow path: I/O still pending — offload */
            ext4_mb_schedule_async_init(sb, group);
        }
        if (!IS_ERR_OR_NULL(bh))
            brelse(bh);
    }
}
```

Note: the call to `ext4_read_block_bitmap_nowait(sb, group, false)` is
a cache lookup (the `false` argument disables prefetch issuance). We
only use it to probe whether the page is already uptodate; we do not
issue new I/O here.

### 3.6 Lifecycle — creation and destruction

**Create** in `ext4_mb_init()` (after the existing buddy cache setup):
```c
sbi->s_bitmap_init_slab = kmem_cache_create("ext4_bitmap_init_work",
        sizeof(struct ext4_bitmap_init_work), 0, SLAB_RECLAIM_ACCOUNT,
        NULL);
if (!sbi->s_bitmap_init_slab) { /* cleanup + return -ENOMEM */ }

sbi->s_bitmap_init_wq = alloc_workqueue("ext4-bitmap-init/%s",
        WQ_UNBOUND | WQ_MEM_RECLAIM, 1, sb->s_id);
if (!sbi->s_bitmap_init_wq) { /* cleanup + return -ENOMEM */ }
```

**Destroy** in `ext4_mb_release()` (at the start, before freeing group
info):
```c
if (sbi->s_bitmap_init_wq) {
    flush_workqueue(sbi->s_bitmap_init_wq);
    destroy_workqueue(sbi->s_bitmap_init_wq);
}
if (sbi->s_bitmap_init_slab)
    kmem_cache_destroy(sbi->s_bitmap_init_slab);
```

`flush_workqueue` + `destroy_workqueue` together guarantee no work items
reference freed group info. `kmem_cache_destroy` requires all objects
to be freed first; the flush above ensures this.

### 3.7 Freeze / remount-ro / unmount correctness

- **Unmount**: `ext4_mb_release()` drains the queue before group info is
  freed. Safe.
- **Freeze** (`ext4_freeze`): existing freeze path quiesces the allocator
  via `sb_start_pagefault` and journal barrier. No new work items can be
  queued while frozen. In-flight work items either complete before
  freeze returns (because of the allocator quiesce) or stay queued until
  thaw. The workqueue will not process them under freeze because the
  allocator itself is blocked; no correctness issue.
- **Remount-ro**: same as freeze — allocator is quiesced.

### 3.8 Concurrency and locking summary

- **`ext4_mb_init_group()` is already race-safe**: the early-return at
  line 1385 (`!EXT4_MB_GRP_NEED_INIT(this_grp)`) handles the case where
  two callers race to init the same group. Our async path reuses this
  existing primitive, so no new races are introduced.
- **`bb_state` bit flips** (`NEED_INIT`, `BBITMAP_READ`) are atomic via
  `test_and_set_bit`. No changes needed.
- **Buddy page lock** (`ext4_mb_get_buddy_page_lock`) serializes the
  actual init_cache work. No changes needed.

---

## 4. Evaluation plan

### 4.1 Correctness

Must pass before any performance claim:

- `xfstests -g quick` on the patched kernel — zero new failures vs stock.
- `xfstests -g auto` — specifically `generic/230` (group init), `generic/300`
  (crash-recovery under allocator load), `generic/204` (ENOSPC).
- Boot-loop: mount → heavy allocation → unmount, 100 iterations, watch
  for leaks (`slabtop`) and pending-work warnings.

### 4.2 Performance — (i) per-allocation latency microbenchmark

Measurement **(i)** from the brainstorming:
- Fresh 16 GB loop device, `mkfs.ext4 -F -O fast_commit`.
- Mount, immediately run a loop (fsync between iterations to keep the
  commit path busy; unlink happens implicitly when the loop re-creates
  the same filename):
  ```
  for i in $(seq 1 32); do
      rm -f /mnt/test/f
      /usr/bin/time -f '%e' fallocate -l 256M /mnt/test/f 2>>latencies.txt
      sync
  done
  ```
- 32 allocations × 256 MB = 8 GB total; well within the 16 GB device
  so we never hit ENOSPC and allocation policy stays stable.
- Collect per-allocation wall time from `latencies.txt`; compute
  p50/p95/p99 across three full repeats (so 96 data points per config).
- Expected result: p95/p99 reductions on early allocations (cold cache),
  flat or within-noise on late allocations (warm cache).

### 4.3 Performance — (iii) allocator sleep mechanism

Measurement **(iii)**:
- `perf sched record -a -- sudo fio --name=allocstall --rw=write \`
  `--size=2G --bs=1M --numjobs=4 --directory=/mnt/test`
- `perf sched latency | grep ext4_mb` — look for
  `ext4_mb_regular_allocator` sleep time.
- Expected result: visible reduction in the time this function sleeps,
  attributable to the `prefetch_fini` no-wait path.

### 4.4 Secondary: fio throughput ramp

- `fio` seq-write on freshly-mounted FS, 60s.
- Expected result: faster throughput ramp-up in the first few seconds.
  Secondary because the signal is noisier than microbenchmark.

### 4.5 Reproducibility

- Fixed `--randseed` in all fio runs.
- CPU governor pinned to `performance` during runs.
- `echo 3 > /proc/sys/vm/drop_caches` between runs.
- Identical workload parameters across stock and patched runs.
- Three repeats per config; report mean ± stddev.

---

## 5. Scope boundaries

### In scope
- New workqueue and slab cache in `ext4_sb_info`.
- New work-item type, worker function, dispatch helper.
- Modified `ext4_mb_prefetch_fini()` with opportunistic sync/async branching.
- Create/destroy hooks in `ext4_mb_init()` and `ext4_mb_release()`.

### Explicitly out of scope (and why)
- **Other call sites of `ext4_mb_init_group()`** (lines 1462, 2496, 6524).
  They are on the allocator's critical path — the bitmap must be ready
  before proceeding. Making them async would require restructuring the
  allocator itself. Separate project.
- **Changes to `ext4_read_block_bitmap_nowait` or the bitmap endio path**.
  The TODO literally suggests hooking endio, but doing so increases
  correctness risk (read path changes, RCU considerations, different
  code review standards). Option C sidesteps this.
- **New mount options or sysfs knobs**. This is a pure internal
  optimization. If a user-visible knob is needed later, it can be added
  separately.
- **On-disk format changes**. None required.

---

## 6. Risks (honest)

1. **Small benefit on VM loop device.** Loop device I/O is fast relative
   to a real HDD or SATA SSD; the bitmap read may already be complete by
   the time `prefetch_fini` runs, making sync and async paths
   indistinguishable. Mitigation: run the microbenchmark immediately
   after a fresh mount with `drop_caches` applied; this is the worst
   case for bitmap cache coldness.
2. **Worker priority.** The workqueue runs at default priority. Under
   system load, async init may lag, causing the next allocator call to
   block synchronously on the still-uninitialized group. Net: no
   regression — this is exactly the current behavior — but the expected
   win may not materialize under that specific condition.
3. **Memory pressure.** `kmem_cache_alloc(GFP_NOFS)` can fail. We fall
   back to synchronous init. Correctness is preserved; benefit is zero
   in that case.
4. **`kmem_cache` cost.** Per-sb slab cache adds ~1 KB of slab metadata.
   Negligible.
5. **Review resistance.** Upstream reviewers may prefer Option B (endio
   hook) for closer TODO fidelity. If we submit upstream later, we can
   say Option C is a stepping stone; for a course/paper evaluation,
   Option C is the right choice.

---

## 7. What a positive result looks like

- `xfstests -g quick`: zero new failures.
- Microbenchmark: p99 per-fallocate allocation time drops by ≥ 30%
  in the first 16 allocations after mount. Warm-cache (later)
  allocations unchanged.
- `perf sched`: `ext4_mb_regular_allocator` total sleep time during the
  benchmark drops by a measurable amount (≥ 20%); the reduced sleep
  time is correlated with the removal of `prefetch_fini` waits (can be
  confirmed via `ftrace` function graph).
- No regression on sequential write throughput or on cold-cache reads.

If the microbenchmark improvement is less than the noise floor (say,
< 10% of p99), we report it as a null result with mechanism trace still
showing the reduced sleep time, and discuss why the user-visible signal
didn't materialize on our hardware.

---

## 8. Open questions (to be resolved during plan-writing)

- Do we create the workqueue unconditionally or only when `s_mb_prefetch > 0`?
  (The knob controls whether prefetching is enabled at all.)
- Should the worker use `GFP_NOFS` or `GFP_KERNEL`? The original
  `ext4_mb_init_group` callers use both depending on context; outside the
  allocator path, `GFP_KERNEL` is probably fine.
- Should we add a counter (`s_mb_async_init_queued`, `s_mb_async_init_sync`)
  exposed via `/sys/fs/ext4/<dev>/mb_stats` for observability? Useful for
  the paper, but optional.
