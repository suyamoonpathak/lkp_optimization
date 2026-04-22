# ext4 Async Bitmap Prefetch Completion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the TODO at `fs/ext4/mballoc.c:2564` — opportunistically defer the buddy-bitmap initialization done in `ext4_mb_prefetch_fini()` to a per-superblock workqueue when the bitmap page is not yet uptodate. Allocator returns immediately instead of blocking on bitmap I/O.

**Architecture:** Add a per-sb workqueue and slab cache inside `struct ext4_sb_info`. In `ext4_mb_prefetch_fini()`, probe each prefetched group's bitmap buffer: if already uptodate, init inline (cheap CPU work); otherwise, queue a small work item whose worker calls the existing `ext4_mb_init_group()` when the I/O completes.

**Tech Stack:** Linux 6.1.4 kernel source tree at `/home/lkp-ubuntu/Downloads/Project/linux-6.1.4/`. GCC 13, GNU make, xfstests, fio, perf. Target: patched kernel named `6.1.4-cs614-c2-patched` (distinct LOCALVERSION from stock so both coexist for easy switching).

**Out of tree repo for artifacts:** `/home/lkp-ubuntu/Downloads/Project/` — the patch, benchmark scripts, and results will be committed here.

---

## Safety rails (read before starting)

1. **Separate LOCALVERSION.** We use `-cs614-c2-patched`, not `-cs614-hacker`. That keeps the stock `6.1.4-cs614-hacker` kernel completely untouched. Worst case: reboot into stock to recover. Never modify the stock kernel image.
2. **Commit before every kernel build.** A dirty tree after a build is hard to reproduce. Every code-change task in Phase 1 ends with a git add + commit of the patch file.
3. **xfstests correctness gate before performance.** Performance numbers on a kernel that fails xfstests are worthless and potentially wrong. Do not run benchmarks until Phase 3 passes.
4. **No `make modules_install` without first clearing `/lib/modules/6.1.4-cs614-c2-patched`.** Leftover modules from prior builds cause `.ko.zst` build-rule failures (we hit this already on Candidate 1).

---

## File map

### Modified (in Linux source tree)

| File | What changes |
|---|---|
| `linux-6.1.4/fs/ext4/ext4.h:1621` | Add `s_bitmap_init_wq` + `s_bitmap_init_slab` fields to `struct ext4_sb_info`. |
| `linux-6.1.4/fs/ext4/mballoc.c:~1360` (before `ext4_mb_init_group`) | Add `struct ext4_bitmap_init_work`, worker function, dispatch helper. |
| `linux-6.1.4/fs/ext4/mballoc.c:2569` | Rewrite body of `ext4_mb_prefetch_fini()` with opportunistic sync/async branching. |
| `linux-6.1.4/fs/ext4/mballoc.c:3329` (`ext4_mb_init`) | Create the slab + workqueue; cleanup on failure. |
| `linux-6.1.4/fs/ext4/mballoc.c:3506` (`ext4_mb_release`) | Flush workqueue, destroy workqueue + slab. |

### New (in our research repo)

| File | Purpose |
|---|---|
| `our_optimization/mballoc-async-prefetch.patch` | The generated patch. |
| `our_optimization/bench_async_prefetch.sh` | Microbenchmark (measurement i + iii combined). |
| `our_optimization/CANDIDATE2_results.md` | Final measured numbers. |

---

## Phase 1 — Code changes (no build yet)

### Task 1: Add workqueue and slab cache fields to `ext4_sb_info`

**Files:**
- Modify: `linux-6.1.4/fs/ext4/ext4.h:1621`

- [ ] **Step 1: Open the file and verify we're at the right spot**

Run: `grep -n "s_mb_prefetch_limit" /home/lkp-ubuntu/Downloads/Project/linux-6.1.4/fs/ext4/ext4.h`
Expected: `1621:	unsigned int s_mb_prefetch_limit;`

- [ ] **Step 2: Insert the two new fields after `s_mb_prefetch_limit`**

Change the file to add two lines after line 1621. The `old_string` / `new_string` for the Edit tool:

Old:
```c
	unsigned int s_mb_prefetch;
	unsigned int s_mb_prefetch_limit;

	/* stats for buddy allocator */
```

New:
```c
	unsigned int s_mb_prefetch;
	unsigned int s_mb_prefetch_limit;

	/* Async bitmap init support (see mballoc.c:ext4_mb_prefetch_fini) */
	struct workqueue_struct *s_bitmap_init_wq;
	struct kmem_cache       *s_bitmap_init_slab;

	/* stats for buddy allocator */
```

- [ ] **Step 3: Verify the edit**

Run: `grep -A2 "s_mb_prefetch_limit;" /home/lkp-ubuntu/Downloads/Project/linux-6.1.4/fs/ext4/ext4.h | head -5`
Expected output contains:
```
	unsigned int s_mb_prefetch_limit;

	/* Async bitmap init support (see mballoc.c:ext4_mb_prefetch_fini) */
```

---

### Task 2: Add the work-item struct, worker, and dispatch helper in mballoc.c

**Files:**
- Modify: `linux-6.1.4/fs/ext4/mballoc.c` — insert new code immediately before `int ext4_mb_init_group` at line 1364.

- [ ] **Step 1: Verify the insertion point**

Run: `grep -n "^int ext4_mb_init_group(struct super_block \*sb" /home/lkp-ubuntu/Downloads/Project/linux-6.1.4/fs/ext4/mballoc.c`
Expected: `1364:int ext4_mb_init_group(struct super_block *sb, ext4_group_t group, gfp_t gfp)`

- [ ] **Step 2: Insert the new struct + two static functions immediately before line 1364**

Old (the line to anchor against):
```c
int ext4_mb_init_group(struct super_block *sb, ext4_group_t group, gfp_t gfp)
{

	struct ext4_group_info *this_grp;
```

New:
```c
/*
 * Async bitmap init — off the allocator's critical path.
 *
 * ext4_mb_prefetch_fini() used to call ext4_mb_init_group() synchronously,
 * which can block on bitmap READ I/O. The below infrastructure lets
 * prefetch_fini offload that work to a per-sb workqueue when the bitmap
 * is not yet uptodate. See the TODO above ext4_mb_prefetch_fini().
 */
struct ext4_bitmap_init_work {
	struct work_struct  work;
	struct super_block *sb;
	ext4_group_t        group;
};

static void ext4_mb_async_init_worker(struct work_struct *work)
{
	struct ext4_bitmap_init_work *w =
		container_of(work, struct ext4_bitmap_init_work, work);

	/*
	 * ext4_mb_init_group() early-returns if NEED_INIT is already clear
	 * (another racer finished first). Errors intentionally ignored:
	 * NEED_INIT stays set, so the next synchronous caller retries.
	 */
	ext4_mb_init_group(w->sb, w->group, GFP_NOFS);

	kmem_cache_free(EXT4_SB(w->sb)->s_bitmap_init_slab, w);
}

static void ext4_mb_schedule_async_init(struct super_block *sb,
					ext4_group_t group)
{
	struct ext4_sb_info *sbi = EXT4_SB(sb);
	struct ext4_bitmap_init_work *w;

	w = kmem_cache_alloc(sbi->s_bitmap_init_slab, GFP_NOFS);
	if (!w) {
		/* Fallback: synchronous — no worse than pre-patch */
		ext4_mb_init_group(sb, group, GFP_NOFS);
		return;
	}
	INIT_WORK(&w->work, ext4_mb_async_init_worker);
	w->sb    = sb;
	w->group = group;
	queue_work(sbi->s_bitmap_init_wq, &w->work);
}

int ext4_mb_init_group(struct super_block *sb, ext4_group_t group, gfp_t gfp)
{

	struct ext4_group_info *this_grp;
```

- [ ] **Step 3: Verify the insertion**

Run: `grep -n "ext4_mb_schedule_async_init\|ext4_mb_async_init_worker\|^struct ext4_bitmap_init_work" /home/lkp-ubuntu/Downloads/Project/linux-6.1.4/fs/ext4/mballoc.c | head`
Expected: three lines with names found, each at a line number less than 1420.

---

### Task 3: Modify `ext4_mb_prefetch_fini()` to use the opportunistic path

**Files:**
- Modify: `linux-6.1.4/fs/ext4/mballoc.c:2569-2590`

- [ ] **Step 1: Confirm current body**

Run: `sed -n '2569,2590p' /home/lkp-ubuntu/Downloads/Project/linux-6.1.4/fs/ext4/mballoc.c`
Expected: the current sequential loop calling `ext4_mb_init_group` directly.

- [ ] **Step 2: Replace the function body**

Old:
```c
void ext4_mb_prefetch_fini(struct super_block *sb, ext4_group_t group,
			   unsigned int nr)
{
	while (nr-- > 0) {
		struct ext4_group_desc *gdp = ext4_get_group_desc(sb, group,
								  NULL);
		struct ext4_group_info *grp = ext4_get_group_info(sb, group);

		if (!group)
			group = ext4_get_groups_count(sb);
		group--;
		grp = ext4_get_group_info(sb, group);

		if (EXT4_MB_GRP_NEED_INIT(grp) &&
		    ext4_free_group_clusters(sb, gdp) > 0 &&
		    !(ext4_has_group_desc_csum(sb) &&
		      (gdp->bg_flags & cpu_to_le16(EXT4_BG_BLOCK_UNINIT)))) {
			if (ext4_mb_init_group(sb, group, GFP_NOFS))
				break;
		}
	}
}
```

New:
```c
void ext4_mb_prefetch_fini(struct super_block *sb, ext4_group_t group,
			   unsigned int nr)
{
	while (nr-- > 0) {
		struct ext4_group_desc *gdp = ext4_get_group_desc(sb, group,
								  NULL);
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
		 * Opportunistic: if the bitmap buffer is already uptodate,
		 * do the buddy setup inline — it is just CPU work once the
		 * page is in memory. Otherwise, defer to the per-sb
		 * workqueue so the caller (ext4_mb_regular_allocator) does
		 * not sleep waiting for the bitmap READ to complete.
		 *
		 * ext4_read_block_bitmap_nowait(sb, group, false) is a
		 * cache lookup (the false argument disables new prefetch);
		 * we use it purely to probe uptodate-ness.
		 */
		bh = ext4_read_block_bitmap_nowait(sb, group, false);
		if (!IS_ERR_OR_NULL(bh) && buffer_uptodate(bh)) {
			if (ext4_mb_init_group(sb, group, GFP_NOFS)) {
				brelse(bh);
				break;
			}
		} else {
			ext4_mb_schedule_async_init(sb, group);
		}
		if (!IS_ERR_OR_NULL(bh))
			brelse(bh);
	}
}
```

- [ ] **Step 3: Verify the edit**

Run: `grep -n "ext4_mb_schedule_async_init\|Opportunistic:" /home/lkp-ubuntu/Downloads/Project/linux-6.1.4/fs/ext4/mballoc.c`
Expected: at least 2 lines, one for the comment and one for the call.

---

### Task 4: Create workqueue + slab in `ext4_mb_init()`, wire cleanup into `out:`

**Files:**
- Modify: `linux-6.1.4/fs/ext4/mballoc.c:3468-3473` — insert creation right after backend init.
- Modify: `linux-6.1.4/fs/ext4/mballoc.c:3478` — add our cleanup to the `out:` label.

**Rationale:** The existing `out:` label in `ext4_mb_init` unconditionally frees `s_mb_offsets`, `s_mb_maxs`, etc. (all called on possibly-NULL pointers — `kfree(NULL)` is safe). We follow the same pattern: add conditional destroys to `out:`, then place the creation where it can `goto out;` on failure.

- [ ] **Step 1: Insert creation code after `ext4_mb_init_backend(sb)` succeeds**

Anchor (the current end of `ext4_mb_init`'s success path at lines 3468-3473):

Old:
```c
	/* init file for buddy data */
	ret = ext4_mb_init_backend(sb);
	if (ret != 0)
		goto out_free_locality_groups;

	return 0;
```

New:
```c
	/* init file for buddy data */
	ret = ext4_mb_init_backend(sb);
	if (ret != 0)
		goto out_free_locality_groups;

	/* Async bitmap init infrastructure (see ext4_mb_prefetch_fini) */
	sbi->s_bitmap_init_slab = kmem_cache_create("ext4_bitmap_init_work",
		sizeof(struct ext4_bitmap_init_work), 0,
		SLAB_RECLAIM_ACCOUNT, NULL);
	if (!sbi->s_bitmap_init_slab) {
		ret = -ENOMEM;
		goto out_free_locality_groups;
	}
	sbi->s_bitmap_init_wq = alloc_workqueue("ext4-bitmap-init/%s",
		WQ_UNBOUND | WQ_MEM_RECLAIM, 1, sb->s_id);
	if (!sbi->s_bitmap_init_wq) {
		ret = -ENOMEM;
		goto out_free_locality_groups;
	}

	return 0;
```

Note: we use `out_free_locality_groups` which falls through to `out:`. The cleanup for our new fields lives in `out:` (next step), so the `goto out_free_locality_groups` chain will free them.

- [ ] **Step 2: Add cleanup for our fields to the existing `out:` label**

Anchor (lines 3478-3487):

Old:
```c
out:
	kfree(sbi->s_mb_avg_fragment_size);
	kfree(sbi->s_mb_avg_fragment_size_locks);
	kfree(sbi->s_mb_largest_free_orders);
	kfree(sbi->s_mb_largest_free_orders_locks);
	kfree(sbi->s_mb_offsets);
	sbi->s_mb_offsets = NULL;
	kfree(sbi->s_mb_maxs);
	sbi->s_mb_maxs = NULL;
	return ret;
```

New:
```c
out:
	if (sbi->s_bitmap_init_wq) {
		destroy_workqueue(sbi->s_bitmap_init_wq);
		sbi->s_bitmap_init_wq = NULL;
	}
	if (sbi->s_bitmap_init_slab) {
		kmem_cache_destroy(sbi->s_bitmap_init_slab);
		sbi->s_bitmap_init_slab = NULL;
	}
	kfree(sbi->s_mb_avg_fragment_size);
	kfree(sbi->s_mb_avg_fragment_size_locks);
	kfree(sbi->s_mb_largest_free_orders);
	kfree(sbi->s_mb_largest_free_orders_locks);
	kfree(sbi->s_mb_offsets);
	sbi->s_mb_offsets = NULL;
	kfree(sbi->s_mb_maxs);
	sbi->s_mb_maxs = NULL;
	return ret;
```

- [ ] **Step 3: Verify both edits**

Run: `grep -n "s_bitmap_init_slab\|s_bitmap_init_wq" /home/lkp-ubuntu/Downloads/Project/linux-6.1.4/fs/ext4/mballoc.c | head -15`
Expected: ≥ 6 matches — two in the ext4.h struct field declarations (from Task 1), then at least one create, one destroy, and one init-cleanup in mballoc.c. After Task 5 adds more destroys the count goes up.

---

### Task 5: Destroy workqueue + slab in `ext4_mb_release()`

**Files:**
- Modify: `linux-6.1.4/fs/ext4/mballoc.c:3506` (the `ext4_mb_release` function)

- [ ] **Step 1: Confirm function location and first line**

Run: `sed -n '3506,3524p' /home/lkp-ubuntu/Downloads/Project/linux-6.1.4/fs/ext4/mballoc.c`
Expected: shows `int ext4_mb_release(struct super_block *sb)` and its body starting with variable decls and the `if (test_opt(sb, DISCARD))` block.

- [ ] **Step 2: Insert the flush+destroy at the top of the function body**

Old:
```c
int ext4_mb_release(struct super_block *sb)
{
	ext4_group_t ngroups = ext4_get_groups_count(sb);
	ext4_group_t i;
	int num_meta_group_infos;
	struct ext4_group_info *grinfo, ***group_info;
	struct ext4_sb_info *sbi = EXT4_SB(sb);
	struct kmem_cache *cachep = get_groupinfo_cache(sb->s_blocksize_bits);
	int count;

	if (test_opt(sb, DISCARD)) {
```

New:
```c
int ext4_mb_release(struct super_block *sb)
{
	ext4_group_t ngroups = ext4_get_groups_count(sb);
	ext4_group_t i;
	int num_meta_group_infos;
	struct ext4_group_info *grinfo, ***group_info;
	struct ext4_sb_info *sbi = EXT4_SB(sb);
	struct kmem_cache *cachep = get_groupinfo_cache(sb->s_blocksize_bits);
	int count;

	/*
	 * Drain the async bitmap-init workqueue before freeing any group
	 * info: pending workers call ext4_mb_init_group() which reads
	 * group_info. flush_workqueue + destroy_workqueue together
	 * guarantees no worker is still running when we return.
	 */
	if (sbi->s_bitmap_init_wq) {
		flush_workqueue(sbi->s_bitmap_init_wq);
		destroy_workqueue(sbi->s_bitmap_init_wq);
		sbi->s_bitmap_init_wq = NULL;
	}
	if (sbi->s_bitmap_init_slab) {
		kmem_cache_destroy(sbi->s_bitmap_init_slab);
		sbi->s_bitmap_init_slab = NULL;
	}

	if (test_opt(sb, DISCARD)) {
```

- [ ] **Step 3: Verify the insertion**

Run: `grep -B1 -A3 "flush_workqueue.*s_bitmap_init" /home/lkp-ubuntu/Downloads/Project/linux-6.1.4/fs/ext4/mballoc.c`
Expected: shows the flush inside `ext4_mb_release`.

---

### Task 6: Generate and save the patch

**Files:**
- Create: `our_optimization/mballoc-async-prefetch.patch`

- [ ] **Step 1: Generate the diff**

Run: `cd /home/lkp-ubuntu/Downloads/Project/linux-6.1.4 && git diff fs/ext4/ > /tmp/patch_check.diff && wc -l /tmp/patch_check.diff`
Expected: between 100 and 250 lines. If zero lines, something's wrong with git tracking — try `diff -u` against a pristine copy instead.

- [ ] **Step 2: Save the patch into our research repo**

Run:
```bash
cd /home/lkp-ubuntu/Downloads/Project
git -C linux-6.1.4 diff fs/ext4/ > our_optimization/mballoc-async-prefetch.patch
# Normalize paths so -p1 works from inside linux-6.1.4:
sed -i 's|a/fs/|a/fs/|g; s|b/fs/|b/fs/|g' our_optimization/mballoc-async-prefetch.patch
# (the sed is a no-op in most cases — included for symmetry with the earlier patch)
head -5 our_optimization/mballoc-async-prefetch.patch
```
Expected: patch headers showing `a/fs/ext4/ext4.h` and `a/fs/ext4/mballoc.c`.

- [ ] **Step 3: Commit the patch file**

Run:
```bash
cd /home/lkp-ubuntu/Downloads/Project
git add our_optimization/mballoc-async-prefetch.patch
git commit -m "candidate 2: async bitmap prefetch completion — initial patch

Implements the TODO at fs/ext4/mballoc.c:2564. Opportunistic async path:
if bitmap buffer is uptodate, init inline; else queue a work item on a
per-sb workqueue. Allocator no longer sleeps in ext4_mb_prefetch_fini.

See docs/superpowers/specs/2026-04-22-ext4-async-bitmap-prefetch-design.md"
```

---

## Phase 2 — Build the patched kernel

### Task 7: Set a unique LOCALVERSION and build

**Files:**
- Modify: `linux-6.1.4/.config` (one line)

- [ ] **Step 1: Change LOCALVERSION so the patched kernel gets a distinct name**

Run:
```bash
cd /home/lkp-ubuntu/Downloads/Project/linux-6.1.4
sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-cs614-c2-patched"/' .config
grep "^CONFIG_LOCALVERSION=" .config
```
Expected: `CONFIG_LOCALVERSION="-cs614-c2-patched"`

- [ ] **Step 2: Run `make olddefconfig` to sync the config**

Run:
```bash
cd /home/lkp-ubuntu/Downloads/Project/linux-6.1.4
make olddefconfig 2>&1 | tail -3
```
Expected: `#` then `# configuration written to .config` then `#`

- [ ] **Step 3: Build kernel and modules**

Run:
```bash
cd /home/lkp-ubuntu/Downloads/Project/linux-6.1.4
make -j$(nproc) bzImage modules 2>&1 | tee /tmp/kernel_build_c2.log
```
Expected runtime: 20–45 minutes. Final lines should include `Setup is XXXX bytes (padded to XXXX bytes).` and `Kernel: arch/x86/boot/bzImage is ready`.

- [ ] **Step 4: Verify the build produced a kernel**

Run: `ls -lh /home/lkp-ubuntu/Downloads/Project/linux-6.1.4/arch/x86/boot/bzImage`
Expected: a ~11 MB file with today's timestamp.

- [ ] **Step 5: Verify zero build errors**

Run: `grep -c "^.*: error:\|^make.*Error" /tmp/kernel_build_c2.log`
Expected: `0`. If non-zero, inspect with `grep -B2 -A2 "error:" /tmp/kernel_build_c2.log` and fix before proceeding.

---

### Task 8: Install the patched kernel (side-by-side with stock)

**Files:** none modified (system install)

- [ ] **Step 1: Clean any stale modules directory for this kernel name**

Run: `sudo rm -rf /lib/modules/6.1.4-cs614-c2-patched`
(Harmless if it didn't exist.)

- [ ] **Step 2: Install modules**

Run:
```bash
cd /home/lkp-ubuntu/Downloads/Project/linux-6.1.4
sudo make modules_install 2>&1 | tail -3
```
Expected last line: `  DEPMOD  /lib/modules/6.1.4-cs614-c2-patched`

- [ ] **Step 3: Install the kernel image + update GRUB**

Run:
```bash
cd /home/lkp-ubuntu/Downloads/Project/linux-6.1.4
sudo make install 2>&1 | tail -6
```
Expected to see `Generating /boot/initrd.img-6.1.4-cs614-c2-patched` and `done` for GRUB.

- [ ] **Step 4: Verify both kernels coexist**

Run: `ls /boot/vmlinuz-6.1.4-* && ls /lib/modules/ | grep 6.1.4`
Expected output contains BOTH `vmlinuz-6.1.4-cs614-hacker` AND `vmlinuz-6.1.4-cs614-c2-patched`.

---

### Task 9: Reboot into the patched kernel and verify

**Files:** none

- [ ] **Step 1: Reboot**

Run: `sudo reboot`

- [ ] **Step 2 (after reboot): Verify which kernel booted**

In the GRUB menu, select "Advanced options for Ubuntu" → the entry containing `6.1.4-cs614-c2-patched`.

After login, run: `uname -r`
Expected: `6.1.4-cs614-c2-patched`

If it's `6.1.4-cs614-hacker` instead, reboot and select the right entry.

- [ ] **Step 3: Verify the patch code is actually in the running kernel**

Run (indirect check via dmesg — the workqueue name will appear when the FS is mounted):
```bash
dmesg | grep -i "ext4-bitmap-init" | head -3
```
If empty at this point, that's fine (no ext4 FS might have been initialized yet). The real test is Task 15.

---

## Phase 3 — Correctness gate (must pass before Phase 4)

### Task 10: Install and prepare xfstests

**Files:** none (sets up a separate xfstests tree)

- [ ] **Step 1: Install dependencies**

Run:
```bash
sudo apt install -y xfslibs-dev libattr1-dev libacl1-dev libaio-dev \
    attr acl libssl-dev libtool-bin e2fsprogs libcap-dev quota fio
```

- [ ] **Step 2: Clone xfstests**

Run:
```bash
cd ~
git clone https://github.com/kdave/xfstests-dev.git xfstests
cd xfstests
make -j$(nproc) 2>&1 | tail -3
```
Expected: `make[1]: Leaving directory '.../xfstests'`

- [ ] **Step 3: Create two test loop devices (xfstests needs TEST_DEV and SCRATCH_DEV)**

Run:
```bash
mkdir -p /tmp/xfstests_loops
dd if=/dev/zero of=/tmp/xfstests_loops/test.img bs=1M count=2048 status=none
dd if=/dev/zero of=/tmp/xfstests_loops/scratch.img bs=1M count=2048 status=none
TEST_LOOP=$(sudo losetup --find --show /tmp/xfstests_loops/test.img)
SCRATCH_LOOP=$(sudo losetup --find --show /tmp/xfstests_loops/scratch.img)
sudo mkfs.ext4 -F -O fast_commit $TEST_LOOP
echo "TEST=$TEST_LOOP SCRATCH=$SCRATCH_LOOP"
```
Expected: two `/dev/loopN` device paths printed. **Write these down** — you'll need them in Step 4.

- [ ] **Step 4: Create xfstests config**

Run (replace `$TEST_LOOP` and `$SCRATCH_LOOP` with the devices from Step 3):
```bash
cat > ~/xfstests/local.config <<EOF
export TEST_DEV=$TEST_LOOP
export TEST_DIR=/mnt/xfstests_test
export SCRATCH_DEV=$SCRATCH_LOOP
export SCRATCH_MNT=/mnt/xfstests_scratch
export FSTYP=ext4
EOF
sudo mkdir -p /mnt/xfstests_test /mnt/xfstests_scratch
sudo mount $TEST_LOOP /mnt/xfstests_test
```
Expected: config file exists, TEST device is mounted.

---

### Task 11: Run xfstests quick group — correctness gate

**Files:** none

- [ ] **Step 1: Run the quick group**

Run:
```bash
cd ~/xfstests
sudo ./check -g quick 2>&1 | tee /tmp/xfstests_c2.log
```
Expected runtime: 30–60 minutes. Final lines summarize pass/fail counts.

- [ ] **Step 2: Parse the results**

Run: `tail -20 /tmp/xfstests_c2.log`
Expected: a summary line like `Passed all XXX tests`. If any test fails, note which test(s) and proceed to Step 3.

- [ ] **Step 3: Check whether failures are new (pre-existing xfstests failures on stock 6.1.4 are not regressions)**

If there are failures:
- Reboot into stock kernel (`6.1.4-cs614-hacker`).
- Rerun the same `sudo ./check -g quick`.
- If the same tests fail on stock, the failure is pre-existing — safe to ignore.
- If a test passes on stock but fails on patched, that's a REGRESSION — STOP and debug.

- [ ] **Step 4: Save the log into the repo**

Run:
```bash
cp /tmp/xfstests_c2.log /home/lkp-ubuntu/Downloads/Project/our_optimization/xfstests_c2_patched.log
cd /home/lkp-ubuntu/Downloads/Project
git add our_optimization/xfstests_c2_patched.log
git commit -m "candidate 2: xfstests quick log on patched kernel"
```

**GATE:** Do NOT proceed to Phase 4 unless xfstests shows zero regressions vs stock.

---

## Phase 4 — Performance measurement

### Task 12: Write the combined microbenchmark + perf sched script

**Files:**
- Create: `our_optimization/bench_async_prefetch.sh`

- [ ] **Step 1: Create the script**

Run:
```bash
cat > /home/lkp-ubuntu/Downloads/Project/our_optimization/bench_async_prefetch.sh <<'BENCHEOF'
#!/bin/bash
# Candidate 2 benchmark: async bitmap prefetch completion.
#
# Runs the microbenchmark (measurement i) and perf-sched capture
# (measurement iii) back-to-back on whichever kernel is currently booted.
# Saves results tagged by kernel name so stock vs patched runs don't collide.
#
# Usage: sudo bash bench_async_prefetch.sh

set -euo pipefail

KERNEL="$(uname -r)"
OUT_DIR="$(dirname "$0")/eval_results_c2/${KERNEL}"
mkdir -p "$OUT_DIR"

IMG_FILE="/tmp/c2_bench.img"
MOUNT_POINT="/mnt/c2_bench"
IMG_SIZE_MB=16384   # 16 GB
FALLOC_SIZE_MB=256
ITERATIONS=32
REPEATS=3

echo "=== Candidate 2 benchmark on $KERNEL ==="
echo "Results → $OUT_DIR"

[ "$(id -u)" = "0" ] || { echo "Run as root"; exit 1; }
command -v fio >/dev/null || { echo "apt install fio"; exit 1; }
command -v perf >/dev/null || { echo "apt install linux-tools-common linux-tools-$(uname -r)"; exit 1; }

# Pin CPUs to performance if available
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$f" 2>/dev/null || true
done

# System info for reproducibility
{
    echo "Date: $(date -Iseconds)"
    echo "Kernel: $KERNEL"
    echo "CPU: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
    echo "Cores: $(nproc)"
    echo "RAM: $(free -h | awk '/^Mem/{print $2}')"
} | tee "$OUT_DIR/system_info.txt"

cleanup() {
    umount "$MOUNT_POINT" 2>/dev/null || true
    [ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

##############################################################################
# Measurement (i): per-allocation latency
# Fresh mount → fallocate loop → record per-call wall time
##############################################################################
echo ""
echo "--- Measurement (i): fallocate latency ---"

LATENCIES="$OUT_DIR/fallocate_latencies_us.txt"
: > "$LATENCIES"

for r in $(seq 1 $REPEATS); do
    echo "Repeat $r/$REPEATS..."

    # Fresh image and loop device
    rm -f "$IMG_FILE"
    dd if=/dev/zero of="$IMG_FILE" bs=1M count=$IMG_SIZE_MB status=none
    LOOP=$(losetup --find --show "$IMG_FILE")
    mkfs.ext4 -F -q -O fast_commit "$LOOP"

    mkdir -p "$MOUNT_POINT"
    mount "$LOOP" "$MOUNT_POINT"
    sync && echo 3 > /proc/sys/vm/drop_caches && sleep 1

    for i in $(seq 1 $ITERATIONS); do
        rm -f "$MOUNT_POINT/f"
        # Microsecond-resolution timing via /proc/timer_list or python
        T0=$(date +%s%N)
        fallocate -l ${FALLOC_SIZE_MB}M "$MOUNT_POINT/f"
        T1=$(date +%s%N)
        echo "$r $i $(( (T1 - T0) / 1000 ))" >> "$LATENCIES"
        sync
    done

    umount "$MOUNT_POINT"
    losetup -d "$LOOP"
    unset LOOP
done

echo "Latency data: $LATENCIES"
awk 'NR > 0 { s+=$3; n++ } END { if(n) printf "  mean = %.0f us (%d samples)\n", s/n, n }' "$LATENCIES"

##############################################################################
# Measurement (iii): perf sched — allocator sleep time
##############################################################################
echo ""
echo "--- Measurement (iii): perf sched on allocator ---"

rm -f "$IMG_FILE"
dd if=/dev/zero of="$IMG_FILE" bs=1M count=$IMG_SIZE_MB status=none
LOOP=$(losetup --find --show "$IMG_FILE")
mkfs.ext4 -F -q -O fast_commit "$LOOP"
mount "$LOOP" "$MOUNT_POINT"
sync && echo 3 > /proc/sys/vm/drop_caches && sleep 1

perf sched record -a -o "$OUT_DIR/perf.data" -- \
    fio --name=allocstall \
        --rw=write --bs=1M --size=2G --numjobs=4 \
        --directory="$MOUNT_POINT" --group_reporting \
        --output="$OUT_DIR/fio_perf.txt"

perf sched latency -i "$OUT_DIR/perf.data" > "$OUT_DIR/perf_sched_latency.txt" 2>&1
perf sched timehist -i "$OUT_DIR/perf.data" 2>/dev/null | head -200 > "$OUT_DIR/perf_sched_timehist_head.txt"

echo "perf sched data: $OUT_DIR/perf_sched_latency.txt"
grep -i "ext4_mb\|kworker.*bitmap" "$OUT_DIR/perf_sched_latency.txt" | head -10 || true

umount "$MOUNT_POINT"
losetup -d "$LOOP"
unset LOOP

echo ""
echo "=== Done. Kernel: $KERNEL. Results in $OUT_DIR ==="
BENCHEOF
chmod +x /home/lkp-ubuntu/Downloads/Project/our_optimization/bench_async_prefetch.sh
```
Expected: script file exists and is executable.

- [ ] **Step 2: Commit the script**

Run:
```bash
cd /home/lkp-ubuntu/Downloads/Project
git add our_optimization/bench_async_prefetch.sh
git commit -m "candidate 2: microbenchmark + perf sched script"
```

---

### Task 13: Baseline — run benchmark on stock kernel

**Files:** produces `our_optimization/eval_results_c2/6.1.4-cs614-hacker/*`

- [ ] **Step 1: Reboot to stock**

Run: `sudo reboot` — select `6.1.4-cs614-hacker` (the non-patched, non-`.old` one, build dated before April 22).

- [ ] **Step 2: Verify kernel**

Run: `uname -r`
Expected: `6.1.4-cs614-hacker`

- [ ] **Step 3: Run the benchmark**

Run:
```bash
cd /home/lkp-ubuntu/Downloads/Project
sudo bash our_optimization/bench_async_prefetch.sh
```
Expected runtime: ~10 minutes. Result directory: `our_optimization/eval_results_c2/6.1.4-cs614-hacker/`

- [ ] **Step 4: Commit baseline results**

Run:
```bash
cd /home/lkp-ubuntu/Downloads/Project
git add our_optimization/eval_results_c2/6.1.4-cs614-hacker/
git commit -m "candidate 2: stock kernel baseline results"
```

---

### Task 14: Patched — run benchmark on patched kernel

**Files:** produces `our_optimization/eval_results_c2/6.1.4-cs614-c2-patched/*`

- [ ] **Step 1: Reboot to patched**

Run: `sudo reboot` — select `6.1.4-cs614-c2-patched`.

- [ ] **Step 2: Verify kernel**

Run: `uname -r`
Expected: `6.1.4-cs614-c2-patched`

- [ ] **Step 3: Run the benchmark**

Run:
```bash
cd /home/lkp-ubuntu/Downloads/Project
sudo bash our_optimization/bench_async_prefetch.sh
```
Expected runtime: ~10 minutes.

- [ ] **Step 4: Commit patched results**

Run:
```bash
cd /home/lkp-ubuntu/Downloads/Project
git add our_optimization/eval_results_c2/6.1.4-cs614-c2-patched/
git commit -m "candidate 2: patched kernel results"
```

---

### Task 15: Analyze and write results

**Files:**
- Create: `our_optimization/CANDIDATE2_results.md`

- [ ] **Step 1: Compute stats from the latency files**

Run:
```bash
STOCK=/home/lkp-ubuntu/Downloads/Project/our_optimization/eval_results_c2/6.1.4-cs614-hacker/fallocate_latencies_us.txt
PATCHED=/home/lkp-ubuntu/Downloads/Project/our_optimization/eval_results_c2/6.1.4-cs614-c2-patched/fallocate_latencies_us.txt

python3 <<'PY'
import statistics, sys
for name, path in [("STOCK", "$STOCK"), ("PATCHED", "$PATCHED")]:
    data = [int(l.split()[-1]) for l in open(path)]
    data.sort()
    p50 = data[len(data)//2]
    p95 = data[int(len(data)*0.95)]
    p99 = data[int(len(data)*0.99)]
    mean = statistics.mean(data)
    print(f"{name}: n={len(data)} mean={mean:.0f}us p50={p50}us p95={p95}us p99={p99}us")
PY
```
Substitute `$STOCK` and `$PATCHED` with the shell vars. Record the output.

- [ ] **Step 2: Pull key `perf sched` numbers**

Run:
```bash
for k in 6.1.4-cs614-hacker 6.1.4-cs614-c2-patched; do
    echo "=== $k ==="
    grep -i "ext4_mb\|all_sleep_time\|all_runtime" \
        /home/lkp-ubuntu/Downloads/Project/our_optimization/eval_results_c2/$k/perf_sched_latency.txt \
        | head -10
done
```

- [ ] **Step 2b: Pull fio throughput numbers (secondary macrobenchmark, per spec §4.4)**

Run:
```bash
for k in 6.1.4-cs614-hacker 6.1.4-cs614-c2-patched; do
    echo "=== $k ==="
    grep -E "IOPS=|BW=|clat.*avg=" \
        /home/lkp-ubuntu/Downloads/Project/our_optimization/eval_results_c2/$k/fio_perf.txt \
        | head -6
done
```
Expected: IOPS and BW visible for both kernels. These are produced by the `perf sched record` run in `bench_async_prefetch.sh` which wrapped a 4-job fio write.

- [ ] **Step 3: Write the results document**

Create `/home/lkp-ubuntu/Downloads/Project/our_optimization/CANDIDATE2_results.md` with this structure (fill in real numbers from Steps 1 & 2):

```markdown
# Candidate 2 Results: Async Bitmap Prefetch Completion

**Date:** (today)
**Kernels compared:** 6.1.4-cs614-hacker (stock) vs 6.1.4-cs614-c2-patched
**Workload:** fresh-mount fallocate loop, 256 MB × 32 iterations × 3 repeats
**Hardware:** (from system_info.txt)

## Measurement (i) — per-fallocate latency

| Statistic | Stock | Patched | Change |
|---|---|---|---|
| Mean | ... us | ... us | ... |
| p50 | ... us | ... us | ... |
| p95 | ... us | ... us | ... |
| p99 | ... us | ... us | ... |

Samples: 96 per kernel (32 × 3 repeats).

## Measurement (iii) — perf sched allocator sleep

Key lines from `perf sched latency`:
- Stock:    (paste)
- Patched:  (paste)

## Correctness

- xfstests -g quick: ZERO regressions (see xfstests_c2_patched.log).

## Conclusion

(Fill in honestly: "Patch improves p99 latency by X% on cold-cache
fallocate workload" or "No measurable change — VM loop device I/O is too
fast to see the effect.")

## Next steps

(If improvement shown: update Milan/Sahil scripts, run on bare-metal.)
(If null result: document in postmortem style like Candidate 1.)
```

- [ ] **Step 4: Commit and push**

Run:
```bash
cd /home/lkp-ubuntu/Downloads/Project
git add our_optimization/CANDIDATE2_results.md
git commit -m "candidate 2: results on VM (stock vs patched)"
git push origin master
```

---

## Phase 5 — Distribute to Milan and Sahil (only if Phase 4 shows improvement)

### Task 16: Adapt bare-metal evaluation scripts for Candidate 2

**Files:**
- Modify: `our_optimization/eval_milan.sh`, `our_optimization/eval_sahil.sh`
- Create: `our_optimization/INSTRUCTIONS_MILAN_C2.md`, `INSTRUCTIONS_SAHIL_C2.md`

- [ ] **Step 1: Decide whether to proceed**

If Candidate 2's VM results show a clear improvement (p95/p99 drop > 20% on cold-cache microbench), proceed. If the result is null/noise, stop here, write a postmortem like Candidate 1, and move to another candidate from the shortlist.

- [ ] **Step 2: (If proceeding) Fork the Milan script as `eval_milan_c2.sh`**

Start from `eval_milan.sh`. Replace the benchmark section with the Candidate-2-specific one (fresh-mount fallocate loop + perf sched) from `bench_async_prefetch.sh`. Keep the contributor-name plumbing, result-directory layout, and kernel-label detection (STOCK vs PATCHED via source-tree check).

- [ ] **Step 3: Generate sahil variant**

Run:
```bash
sed 's/milan/sahil/g; s/Milan/Sahil/g; s/MILAN/SAHIL/g' \
    /home/lkp-ubuntu/Downloads/Project/our_optimization/eval_milan_c2.sh \
    > /home/lkp-ubuntu/Downloads/Project/our_optimization/eval_sahil_c2.sh
chmod +x /home/lkp-ubuntu/Downloads/Project/our_optimization/eval_sahil_c2.sh
```

- [ ] **Step 4: Write the new instruction files**

Start from `INSTRUCTIONS_MILAN.md`; change all references from Candidate 1's patch name (`jbd2-fc-barrier-defer.patch`) to `mballoc-async-prefetch.patch`. Change LOCALVERSION instructions to use `-cs614-c2-patched`. Reference the new benchmark script. Save as `INSTRUCTIONS_MILAN_C2.md` and generate the sahil variant the same way.

- [ ] **Step 5: Commit and push**

Run:
```bash
cd /home/lkp-ubuntu/Downloads/Project
git add our_optimization/eval_*_c2.sh our_optimization/INSTRUCTIONS_*_C2.md
git commit -m "candidate 2: bare-metal evaluation scripts for Milan and Sahil"
git push origin master
```

---

## Self-review / spec coverage

Before handing off execution, confirm:

- [x] Design §3.1 (workqueue + slab fields) → Task 1
- [x] Design §3.2 (work-item struct) → Task 2
- [x] Design §3.3 (worker function) → Task 2
- [x] Design §3.4 (dispatch helper) → Task 2
- [x] Design §3.5 (modified prefetch_fini) → Task 3
- [x] Design §3.6 creation → Task 4
- [x] Design §3.6 destruction → Task 5
- [x] Design §4.1 correctness gate → Tasks 10-11
- [x] Design §4.2 microbench → Tasks 12-14
- [x] Design §4.3 perf sched → Tasks 12-14
- [x] Design §4.5 reproducibility (CPU governor, fixed seed, 3 repeats) → Task 12 script
- [x] Design §5 out-of-scope items → not touched by any task
- [x] Design §6 risk #5 (review resistance) → deferred; mentioned in spec only

## Rollback

If anything goes wrong at any phase:

1. **Code broken during Phase 1:** `git -C linux-6.1.4 checkout fs/ext4/` to revert all modifications.
2. **Kernel won't boot in Phase 2-4:** reboot, pick stock `6.1.4-cs614-hacker` from GRUB Advanced Options. Stock is untouched because we used a distinct LOCALVERSION.
3. **xfstests regressions in Phase 3:** leave the patched kernel installed but do not delete it yet — capture the specific failing test name for debugging, then proceed by rebooting to stock.
4. **Benchmark shows regression in Phase 4:** the patch is worse than stock — capture the data, reboot to stock, write a postmortem, do not proceed to Phase 5.
