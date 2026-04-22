# FastCommit Coverage for Inline Extended Attributes

**Date:** 2026-04-23
**Author:** Suyamoon Pathak (CS614 LKP, IIT Kanpur)
**Target kernel:** Linux 6.1.4
**Status:** Design approved; plan to be written next.

---

## 1. Motivation

### The gap

On a current ext4 kernel with the `fast_commit` feature enabled, **every
successful `setxattr()` or `removexattr()` call forces a full JBD2
commit** rather than going through the fast-commit path. The relevant
code is `fs/ext4/xattr.c:2422`:

```c
ext4_fc_mark_ineligible(inode->i_sb, EXT4_FC_REASON_XATTR, handle);
```

This line fires unconditionally on every return from
`ext4_xattr_set_handle()`, marking the current transaction ineligible
for fast commit.

The result: on `setxattr`-heavy workloads (SELinux labeling, ACLs,
tools like `systemd-tmpfiles`, `rpm` installs), the fast-commit feature
is effectively disabled — `fsync()` after an xattr change pays a full
JBD2 commit's ~6 ms instead of fast-commit's ~100 µs.

### ATC 2024 FastCommit context

The FastCommit paper (Shirwadkar, Kadekodi, Ts'o — USENIX ATC 2024)
mentions only 8 FC tag types vs XFS's 40 — and explicitly calls out
xattrs, hardlinks, and inline_data as uncovered. This work closes one
of those gaps.

### Why this optimization, after two failures

Candidates 1 and 2 targeted rare paths: the T_LOCKED/T_SWITCH
contention window (Candidate 1) and the `ext4_mb_prefetch_fini` async
branch (Candidate 2). Both are hit on < 1% of operations; their
measurable aggregate effect was below noise.

In contrast: `EXT4_FC_REASON_XATTR` is hit on **100% of xattr
operations**. A per-operation speedup of ~50× translates directly to a
~50× workload speedup. The signal is orders of magnitude larger than
any VM noise floor.

---

## 2. Code context (verified by direct reading)

All file/line references are against Linux 6.1.4.

### 2.1 Where the full-commit fallback happens

`fs/ext4/xattr.c:2279` defines `ext4_xattr_set_handle()`, the entry
point for all xattr modifications. Line 2422 calls
`ext4_fc_mark_ineligible()` unconditionally after the xattr
modification, regardless of success or failure.

### 2.2 Where fast_commit decides what to log per inode

`fs/ext4/fast_commit.c:863` defines `ext4_fc_write_inode()`. At lines
877–880:

```c
if (ext4_test_inode_flag(inode, EXT4_INODE_INLINE_DATA))
    inode_len = EXT4_INODE_SIZE(inode->i_sb);
else if (EXT4_INODE_SIZE(inode->i_sb) > EXT4_GOOD_OLD_INODE_SIZE)
    inode_len += ei->i_extra_isize;
```

The logged length stops at `EXT4_GOOD_OLD_INODE_SIZE + i_extra_isize`.
**The inline-xattr region (from that offset up to `EXT4_INODE_SIZE`)
is NOT logged.**

### 2.3 Where replay handles inode records

`fs/ext4/fast_commit.c:1531` defines `ext4_fc_replay_inode()`. At
lines 1565–1570:

```c
inode_len = tl->fc_len - sizeof(struct ext4_fc_inode);
raw_inode = ext4_raw_inode(&iloc);

memcpy(raw_inode, raw_fc_inode, offsetof(struct ext4_inode, i_block));
memcpy((u8 *)raw_inode + off_gen, (u8 *)raw_fc_inode + off_gen,
       inode_len - off_gen);
```

Replay copies `inode_len` bytes — **variable-length, up to
`sbi->s_inode_size`**. At line 1615 it then recomputes the inode CRC.
**Replay already handles a full-size inode record correctly; no replay
changes are needed.**

### 2.4 How inode tracking reaches fast_commit

`fs/ext4/inode.c:5801` shows `ext4_mark_iloc_dirty()` unconditionally
calls `ext4_fc_track_inode()` before updating the on-disk inode.

`ext4_xattr_set_handle()` at line 2413 calls `ext4_mark_iloc_dirty()`
on success, so **the xattr-modified inode is already registered for
fast-commit logging** — the only thing currently preventing fast
commit from succeeding is the unconditional `mark_ineligible` call at
line 2422.

### 2.5 Feature-bit persistence

`ext4_xattr_update_super_block()` at `fs/ext4/xattr.c:802` sets the
`ext4` `xattr` feature bit in the superblock the **first time** any
xattr is used on the filesystem. Line 805–806:

```c
if (ext4_has_feature_xattr(sb))
    return;
```

After the first xattr, this function is a no-op.

The feature bit must be persisted to disk via a full JBD2 commit
before we can trust that replay will see a consistent superblock.
Therefore: **the first xattr on a fresh filesystem must still be a
full commit**; our optimization activates only on the second and
subsequent xattrs.

### 2.6 Validator accepts variable-length inode records

`ext4_fc_value_len_isvalid()` at `fs/ext4/fast_commit.c:2010`:

```c
case EXT4_FC_TAG_INODE:
    len -= sizeof(struct ext4_fc_inode);
    return len >= EXT4_GOOD_OLD_INODE_SIZE &&
        len <= sbi->s_inode_size;
```

Our expanded records (up to `s_inode_size`) are already accepted.

---

## 3. Design

### 3.1 Change 1 — `fs/ext4/fast_commit.c`: expand FC_TAG_INODE when inline xattrs exist

Use the existing per-inode `EXT4_STATE_XATTR` flag, which is
authoritatively set/cleared inside the xattr code itself (`xattr.c:2226`
sets it on inline xattr add; `xattr.c:2229` clears it on inline xattr
removal). This avoids re-reading the inode body to check the magic.

Modify `ext4_fc_write_inode()` around line 877 to add an extra check
AFTER the existing `else if`:

```c
if (ext4_test_inode_flag(inode, EXT4_INODE_INLINE_DATA))
    inode_len = EXT4_INODE_SIZE(inode->i_sb);
else if (EXT4_INODE_SIZE(inode->i_sb) > EXT4_GOOD_OLD_INODE_SIZE)
    inode_len += ei->i_extra_isize;

/* If inline xattrs are present, log the full inode so the xattr
 * region is captured. Replay will memcpy the full length back. */
if (ext4_test_inode_state(inode, EXT4_STATE_XATTR))
    inode_len = EXT4_INODE_SIZE(inode->i_sb);
```

No new helper function needed — one additional two-line conditional
added to `ext4_fc_write_inode()`. Total delta in `fast_commit.c`:
~3 lines.

### 3.2 Change 2 — `fs/ext4/xattr.c`: conditionally skip `mark_ineligible`

At the top of `ext4_xattr_set_handle()`, add a local tracker:

```c
bool touched_block = false;
```

In the control flow (around lines 2363, 2380, 2389), set
`touched_block = true` immediately before each
`ext4_xattr_block_set()` call site and around line 2374 where
`i.in_inode = 1` (EA inode path):

```c
// Around line 2363:
touched_block = true;
error = ext4_xattr_block_set(handle, inode, &i, &bs);

// Around line 2374:
if (ext4_has_feature_ea_inode(inode->i_sb) && ...) {
    touched_block = true;   // EA inode is also "not inline"
    i.in_inode = 1;
}

// Around line 2380, 2389: same pattern
```

Replace line 2422's unconditional call with:

```c
if (error || touched_block ||
    !ext4_has_feature_xattr(inode->i_sb)) {
    ext4_fc_mark_ineligible(inode->i_sb,
                             EXT4_FC_REASON_XATTR, handle);
}
```

### 3.3 Data flow

1. `setxattr(fd, "security.selinux", label)` enters `ext4_xattr_set_handle()`.
2. `touched_block = false` initially.
3. Value fits inline → `ext4_xattr_ibody_set()` modifies the inode
   body. `touched_block` stays false.
4. `ext4_mark_iloc_dirty()` runs → calls `ext4_fc_track_inode()`:
   inode is registered for fast-commit logging.
5. Conditional at line 2422: `error == 0 && !touched_block &&
   ext4_has_feature_xattr(sb) == true` → skip `mark_ineligible`.
6. `fsync()` triggers fast commit. `ext4_fc_write_inode()` checks
   `ext4_fc_has_inline_xattr()`, finds the magic, logs
   `EXT4_INODE_SIZE` bytes.
7. On crash: replay's `memcpy` at `fast_commit.c:1568-1570` copies the
   full length back into the inode. Inode CRC recomputed at line 1615.

### 3.4 Correctness invariants

1. **Feature-bit persistence.** Line 2422 still marks ineligible when
   `ext4_has_feature_xattr(sb) == false`. The first xattr on a fresh
   fs thus still runs a full commit, persisting the feature bit
   before any fast commit can reference inline xattrs.
2. **Error paths.** On `error != 0`, we still mark ineligible —
   matching current behavior. No change to error semantics.
3. **Block / EA-inode paths.** `touched_block = true` on those paths
   forces the same `mark_ineligible` behavior as today. Scope strictly
   limited to inline xattrs.
4. **Inode CRC.** Replay recomputes, so logging a larger inode
   doesn't introduce CRC mismatch.
5. **Inline-xattr presence detection.** We use the pre-existing
   `EXT4_STATE_XATTR` per-inode flag, which is set/cleared by the
   xattr code itself. No magic-byte scanning, no false-positive
   risk.

### 3.5 What this design explicitly does NOT change

- No new FC tag types.
- No new compat bits.
- No changes to `fast_commit.h` (on-disk format structures).
- No mount options or sysfs knobs.
- No changes to the replay code (`ext4_fc_replay_inode`).
- No changes to other xattr call sites:
  - `fs/ext4/acl.c` (uses `ext4_xattr_set_handle` so benefits automatically)
  - `fs/ext4/crypto.c` (same)
- No changes to the `EXT4_FC_REASON_*` enum or its string table.

### 3.6 Relationship to `EXT4_FC_SUPPORTED_FEATURES`

The existing `EXT4_FC_SUPPORTED_FEATURES` mask is `0x0`. Our patch
neither reads nor modifies this mask. An unpatched kernel replaying a
log written by our patched kernel will still do the right thing
(it will memcpy `len` bytes where `len >= GOOD_OLD_INODE_SIZE` — the
validator already allows that).

---

## 4. Evaluation plan

### 4.1 Correctness gate (must pass before performance)

- `xfstests -g quick` — zero new failures vs stock 6.1.4.
- `xfstests -g auto` — specifically these tests exercise xattr logic
  and FC replay:
  - `generic/062` — xattr basics
  - `generic/118` — inline xattr
  - `generic/300` — crash recovery under metadata load
  - `generic/455` — fc replay stress
  - `ext4/032` — xattr-specific ext4 test
- Custom crash-recovery test: `setfattr` loop on `security.test` →
  `sync` → SIGKILL kjournald2 → remount → `getfattr` verify all
  xattrs present.

### 4.2 Primary performance benchmark

```bash
# Fresh 1 GB loop device, fast_commit enabled
mkfs.ext4 -F -q -O fast_commit /tmp/fc_xattr.img
mount -o loop /tmp/fc_xattr.img /mnt/fcx
touch /mnt/fcx/f

# First xattr is still a full commit (expected); prime the feature bit.
setfattr -n user.warmup -v x /mnt/fcx/f
sync

# Measure 5000 setxattr ops:
time for i in $(seq 1 5000); do
    setfattr -n user.test$i -v "val$i" /mnt/fcx/f
done
```

- **Stock expected:** ~30 s (5000 × ~6 ms per full commit).
- **Patched expected:** 1–3 s (5000 × ~100-500 µs per fast commit).

Metrics to record:
- Wall time of the loop.
- `/proc/fs/jbd2/<dev>/info` transaction count before/after.
- `/sys/fs/ext4/<dev>/fc_info` fast-commit count (after patch).
- Per-op latency distribution (use `/usr/bin/time -f '%e'` or a small
  C program with `clock_gettime`).

### 4.3 Secondary benchmarks

- **SELinux relabel simulation:** Create 10,000 small files; run a
  script that `setfattr`s `security.selinux` on each. Measure wall
  time. SELinux-labeled systems do this on package install.
- **Control: non-xattr workload.** `fio` randwrite+fsync numjobs=4 —
  should be identical to stock. Confirms no regression on unrelated
  workloads.

### 4.4 Reproducibility

- Fixed `--randseed` on fio runs.
- CPU governor pinned to `performance` on bare-metal; a no-op on VM.
- `echo 3 > /proc/sys/vm/drop_caches` between runs.
- Three repeats per config; report mean ± stddev.

### 4.5 What a positive result looks like

- `xfstests -g quick`: 0 new failures.
- Primary benchmark: wall time drops by ≥ 10× (stock ~30 s → patched ~3 s).
- Transaction count: drops by ≥ 90 % (stock ~5000 full commits →
  patched < 500).
- Non-xattr workload: within noise (≤ ±5 %) of stock.

### 4.6 What a null / negative result would look like

- Transaction count unchanged: something is still marking ineligible
  that we missed. Investigate.
- Transaction count drops but wall time doesn't: the per-op overhead
  isn't JBD2; it's syscall / VFS / SELinux. Still valid finding but
  different story.
- xfstests regressions: STOP. Almost certainly the replay path
  corrupting xattrs. Debug immediately.

---

## 5. Risks

### 5.1 Correctness risks (higher than Candidates 1 and 2)

Unlike C1 and C2 (which could only regress performance), this patch
actually changes what's written to the fast-commit log and what's
read back on replay. The failure modes include filesystem corruption.

1. **Stale `EXT4_STATE_XATTR` flag.** If the flag says xattrs are
   present but the actual bytes are garbage, we log garbage and
   corrupt on replay. Mitigation: the flag is only set inside
   `ext4_xattr_ibody_set` AFTER a successful xattr write, and only
   cleared after a successful xattr removal. Under the xattr_sem, it
   cannot be out of sync with the actual inode body.
2. **Missed touched-block case.** If we leave `touched_block = false`
   on a path that actually modified the xattr block, fast commit
   doesn't log the block, and on replay the xattr block is stale.
   Mitigation: set `touched_block = true` immediately before each
   `ext4_xattr_block_set` call and immediately before `i.in_inode = 1`
   assignment.
3. **Concurrency.** Another thread could modify the same inode
   between our xattr change and the fast commit. Existing locking
   (the inode's `EXT4_I(inode)->xattr_sem`) prevents this in the
   set_handle path; the normal JBD2 handle serializes within the
   transaction. No new concurrency surface.

### 5.2 Measurement risks (lower than C1/C2)

The effect magnitude is large enough (~50×) that VM noise can't hide
it. But:

1. **The "first xattr" full-commit shows up in short benchmarks.** If
   you measure 10 setxattr calls, one of them is a full commit, which
   dominates the wall time. Workaround: warm the feature bit before
   the measured loop.
2. **systemd-journald and other background xattr users.** Our VM may
   have background processes that touch xattrs, polluting
   `/proc/fs/jbd2/<dev>/info` stats from the ROOT filesystem. Use a
   dedicated loop device for measurement.

### 5.3 Ecosystem risks

1. **e2fsprogs compatibility.** The comment at `fast_commit.h:7` says
   the kernel and e2fsprogs versions "should always be byte
   identical." We're NOT changing `fast_commit.h`, so `fsck.ext4`
   built against stock e2fsprogs can still validate our logs. An
   older-kernel replay of our logs: the larger inode records are
   allowed by the existing validator, so an older kernel SHOULD
   replay correctly. Still — will explicitly note in a test that a
   stock kernel mounting a filesystem that crashed mid-fast-commit on
   our patched kernel recovers cleanly.
2. **Upstream review.** A maintainer might prefer a proper new tag
   type approach. That's fine — for a course/research context, this
   design is the right tradeoff. If we later want to upstream, we can
   redo the same logic as `EXT4_FC_TAG_XATTR_SET` behind a compat bit.

---

## 6. Scope boundaries

### In scope
- Expanded FC_TAG_INODE logging when inline xattrs present.
- Conditional skip of `ext4_fc_mark_ineligible` in
  `ext4_xattr_set_handle`.
- The `ext4_fc_has_inline_xattr` helper.

### Out of scope (and why)
- **Block xattrs (`i_file_acl` path).** Requires a new tag type and
  replay logic; substantial work; different risk profile. Follow-on
  patch.
- **EA inodes.** Each xattr is a separate inode; replay requires
  coordinated inode creation. Significant scope.
- **`removexattr()` → `setxattr(NULL)` path.** Already covered by
  this design because it goes through the same `ext4_xattr_set_handle`
  function; the `!value` branch ends in either
  `ext4_xattr_ibody_set` (inline) or `ext4_xattr_block_set` (block)
  with the same `touched_block` tracking.
- **Non-posix ACL xattrs.** Go through the same code path; benefit
  automatically.
- **New mount options or sysfs knobs.** Not needed.
- **On-disk format changes or compat bits.** Not needed.

---

## 7. Open questions (to resolve during plan-writing)

1. Should we add a trace event (`trace_ext4_fc_xattr_inline_fast`) to
   measure how often the fast path engages? Useful for the eval
   section but optional.
2. Should there be a sysfs counter
   (`/sys/fs/ext4/<dev>/fc_xattr_inline_fast_count`) for the same
   purpose? Possibly more useful than a tracepoint; easier to read
   from scripts.

Resolution preference: add a simple counter in `struct ext4_fc_stats`
(already exists in `fast_commit.h:118`) and expose it the same way as
the existing `fc_num_commits` counter. Cheap, matches upstream style,
readable from `/proc/fs/ext4/<dev>/fc_info`.

---

## 8. Success criteria summary

| Criterion | Required |
|---|---|
| xfstests -g quick | 0 new failures |
| xfstests generic/062, 118, 300, 455, ext4/032 | 0 new failures |
| Custom crash-recovery test | All xattrs present after mount |
| Primary benchmark wall time | ≥ 10× reduction |
| Primary benchmark transaction count | ≥ 90% reduction |
| Non-xattr fio workload | within ±5% of stock |
| No ext4 errors in dmesg during any test | true |
