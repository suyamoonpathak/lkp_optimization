# Candidate 4 — Characterization Results

**Date:** 2026-04-23
**Kernel measured:** `6.1.4-cs614-c3-patched` (VM, 2 vCPU, 4 GB RAM)
**Goal:** Pick the highest-signal target for a follow-on optimization by
measuring absolute overhead of three candidates before writing any kernel
code. Methodology is the same one that made C3 succeed: measure the per-op
JBD2 full-commit count and the per-op wall time; require a visible
architectural signal before committing effort.

All benches use 256 MB loop images with `mkfs.ext4 -F -q -O fast_commit`,
a warmup op, and the JBD2 transaction counter from
`/proc/fs/jbd2/<loop>-8/info`. Each workload was run three times.

---

## Summary table

| Candidate workload              | N     | elapsed_ms (mean ± range) | ms/op | tx_delta (mean) | tx/op | signal |
|---------------------------------|------:|--------------------------:|------:|----------------:|------:|--------|
| fallocate COLLAPSE_RANGE        | 1000  | 7029 (6876–7249)          | 7.03  | 1001            | 1.001 | **Strong** |
| fallocate INSERT_RANGE          | 1000  | 7006 (6855–7262)          | 7.01  | 1001            | 1.001 | **Strong** |
| xattr block (4 KB value)        | 1000  | 7233 (7199–7257)          | 7.23  | 1001            | 1.001 | **Strong** |
| concurrent fsync T=1            |  100  |  728 (698–768)            | 7.28  |    2            | 0.020 | Weak |
| concurrent fsync T=4            |  400  |  866 (800–959)            | 2.17  |    3            | 0.007 | Weak |
| concurrent fsync T=8            |  800  | 1313 (1243–1349)          | 1.64  |    4            | 0.005 | Weak |
| concurrent fsync T=16           | 1600  | 1935 (1823–2097)          | 1.21  |    5            | 0.003 | Weak |

Signal thresholds used (from the plan):
- **Strong:** tx/op ≥ 0.5 AND ms/op ≥ 1.
- **Moderate:** 0.1 ≤ tx/op < 0.5.
- **Weak:** tx/op < 0.1.

---

## Detailed findings

### Fallocate COLLAPSE_RANGE / INSERT_RANGE — Strong signal

Both modes produce `tx_delta = 1001` for 1000 ops (one full commit per op,
plus the warmup). `ms/op ≈ 7` is the classic full-commit latency on this VM
— identical to what stock-kernel setxattr showed for Candidate 3. The
signal is structurally identical to the one that made C3 work:

- **100% hit rate** within the narrow class "fallocate punch/insert_range
  plus fsync on fast-commit fs".
- **tx/op = 1.001** means every op is a full JBD2 commit — exactly the
  wasted overhead a fast-commit fallback elimination should remove.
- **Variance is small** (range/mean ~5%): the signal is not VM noise.

Call sites verified at `fs/ext4/extents.c:5363` (COLLAPSE) and
`fs/ext4/extents.c:5508` (INSERT). `FALLOC_FL_PUNCH_HOLE` goes through
`ext4_punch_hole()` and does NOT mark ineligible, so PUNCH is out of scope
for this target.

**Important caveat on real-world hit rate.** COLLAPSE_RANGE and
INSERT_RANGE are rarer than plain fallocate or PUNCH_HOLE. Their main
users are log rotation tools (remove a head or tail), database log
compaction, and VM disk shrinking. So the per-op signal is strong but
the path fires less often than setxattr does in real desktops/servers.
This does not invalidate the target — it just means the real-world impact
is concentrated in a few workloads rather than dispersed across all
metadata activity.

### xattr block (4 KB value) — Strong signal, but narrow relevance

On a C3 kernel, a 4000-byte value exceeds the inline xattr region and
falls into the `ext4_xattr_block_set` path, which sets `touched_block =
true` in the C3 patch's logic and therefore still calls
`ext4_fc_mark_ineligible(EXT4_FC_REASON_XATTR, handle)`. Every op is one
full commit. Signal magnitude matches fallocate (≈ 7 ms/op, tx/op =
1.001).

**Why it still got a Strong-signal classification:** absolute overhead is
identical to fallocate's.

**Why I'm still not picking it as the C4 target:** (1) typical xattrs
are small (SELinux labels ~30 B, POSIX ACLs ~40 B) — all inline, already
handled by C3. The 4 KB case is unusual in practice. (2) Extending the
fast-commit path to cover the xattr BLOCK would require a new FC tag
type to log the 4 KB block contents, a replay handler, and handling of
the ref-counted EA block sharing logic. That is substantially more
invasive than fallocate's fix looks to be (fallocate only updates
extent-tree + inode timestamps, both of which FC already knows how to
log via FC_TAG_INODE and existing extent range tags). Poor
signal-per-line-of-code vs fallocate.

### Concurrent fsync — Weak signal, group-commit already works

This is the most informative negative result. Observations:

| T  | tx_delta (mean) | linear prediction (T × tx_delta@T=1) | coalescing ratio |
|----|-----------------|--------------------------------------|------------------|
| 1  | 2               | 2                                    | 1.00             |
| 4  | 3               | 8                                    | 0.37             |
| 8  | 4               | 16                                   | 0.25             |
| 16 | 5               | 32                                   | 0.16             |

Coalescing ratio falls to 0.16 at T=16 — meaning JBD2 is already merging
~84% of what a purely serial-commit approach would have emitted. Group
commit is clearly working. And `ms/op` drops from 7.28 (T=1) to 1.21
(T=16) — wall time gets better with parallelism, which is the user-facing
outcome group commit is supposed to deliver.

There is *some* residual headroom (16% of commits not coalesced), but a
CJFS-style compound-flush backport is a ~200-line port from Linux 5.18.18
for a gain that would be dominated by noise on our VM. This target is
**not worth pursuing** on our hardware.

Also worth noting: the low absolute tx_delta numbers confirm that
`pwrite + fsync` on an ext4 fast-commit-enabled filesystem goes through
the fast-commit path, not a full JBD2 commit. The `/proc/fs/jbd2` counter
only counts full commits — so fast-committed fsyncs don't appear. This
is consistent with stock C3's 78 full commits for 5000 setxattr ops: the
JBD2 tx counter is a clean "did we hit the slow path?" signal.

---

## Honest uncertainty

- **Fallocate's 7 ms/op is not all JBD2.** Some fraction is the extent-tree
  manipulation (btree rebalance, block allocator). A patch that removes
  the full-commit fallback will eliminate the journal overhead but leave
  the extent work — so the post-patch wall time won't be as good as
  C3's (which only had inode-body writes). Expected post-patch ms/op on
  fallocate: ~1–2 ms, not the ~60 µs we see for C3's inline xattrs.
- **Extent replay correctness is the risk.** FC replay already has
  `ext4_fc_replay_add_range` and `ext4_fc_replay_del_range` machinery,
  but COLLAPSE/INSERT alter the extent layout in a non-trivial way. Has
  to be validated with generic/300, generic/455, generic/473, and a
  dedicated crash-recovery test before we can trust it.
- **FALLOC_RANGE might already use FC_TAG tracking for the inode.** That
  would mean the current full-commit fallback is the only missing piece,
  which is the best case. Needs code read before claiming so.
- **Workload relevance concern, restated.** Even with a perfect patch,
  the user-visible impact only shows up in workloads that do
  COLLAPSE/INSERT_RANGE frequently. This is narrower than C3's hit
  profile (SELinux = every file creation). The paper contribution stands
  on the architectural-reduction claim (1001 full commits → <10 per
  1000 ops), which is an apples-to-apples reproduction of the C3 story
  on a different path.

---

## Decision

**C4 target: fallocate COLLAPSE_RANGE / INSERT_RANGE — eliminate the
`EXT4_FC_REASON_FALLOC_RANGE` fallback.**

Reasons:
1. Strongest signal-per-line-of-code ratio among the three candidates.
2. Independent of C3 — this is a net-new hit path, not an incremental
   extension of existing work. The paper can cite "two independent
   full-commit paths eliminated" rather than "one path plus a widened
   version of itself".
3. Reuses the exact methodology and measurement harness from C3. Same
   transaction-count signal, same bench structure, same
   eligibility-marking pattern in the source.
4. Correctness risk is bounded: extent-level FC logging machinery
   already exists; the change is expected to be a conditional
   mark_ineligible analogous to the C3 fix at xattr.c:2422.

Next step: start the C4 design / planning cycle. Before writing a patch,
read `extents.c:5280-5520` (ext4_collapse_range, ext4_insert_range) and
`fs/ext4/fast_commit.c` around extent range tag generation to confirm
the conditional-skip approach is viable.

## Artifacts

- `bench_fallocate_range.sh` + `fallocate_range_helper.c` — the
  fallocate bench and helper.
- `bench_xattr_block.sh` + `xattr_block_fsync_helper.c` — the xattr
  block bench and helper.
- `bench_concurrent_fsync.sh` + `concurrent_fsync_helper.c` — the
  concurrent fsync bench and helper.
- `build_char_helpers.sh` — single-step helper compile.
- `run_c4_characterization.sh` — driver that runs all three benches
  three times (not used for this run; runs were invoked individually
  to stream output).
- `char_results/6.1.4-cs614-c3-patched/` — per-run result files
  (`fallocate_{collapse,insert}.txt`, `xattr_block.txt`,
  `concurrent_T{1,4,8,16}.txt`).
