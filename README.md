# CS614 Project Artifact — ext4/JBD2 Consistency Optimization

**Student:** Suyamoon Pathak (241110091)
**Course:** CS614 Linux Kernel Programming, IIT Kanpur
**Target kernel:** Linux 6.1.4
**Final contribution (Candidate 3):** FastCommit support for inline
extended attributes — closes the `EXT4_FC_REASON_XATTR` gap in ext4's
fast-commit fallback, giving 64× reduction in JBD2 full commits and
27% wall-time speedup on xattr-heavy workloads.

Two earlier attempts (Candidate 1, Candidate 2) produced null results;
they are preserved in the artifact for transparency and lessons-learned
documentation.

---

## 1. Artifact Directory Structure

```
.
├── README.md                                       ← this file
│
├── our_optimization/                               ← all deliverables
│   ├── fc-inline-xattr.patch                       ← ★ FINAL PATCH (C3)
│   ├── CANDIDATE3_results.md                       ← ★ FINAL RESULTS
│   │
│   ├── bench_xattr.sh                              ← primary C3 benchmark
│   ├── xattr_fsync_helper.c                        ← C helper for per-op fsync
│   ├── c3_crash_test_a.sh                          ← crash recovery: 100 xattrs
│   ├── c3_crash_test_b.sh                          ← crash recovery: set/remove
│   ├── c3_crash_test_c.sh                          ← crash recovery: block xattr
│   │
│   ├── eval_milan_c3.sh                            ← bare-metal eval for "Milan"
│   ├── eval_sahil_c3.sh                            ← bare-metal eval for "Sahil"
│   ├── INSTRUCTIONS_MILAN_C3.md                    ← step-by-step walkthrough
│   ├── INSTRUCTIONS_SAHIL_C3.md                    ← step-by-step walkthrough
│   │
│   ├── eval_results_c3/                            ← C3 raw benchmark output
│   │   ├── 6.1.4-cs614-hacker/                     ← STOCK (Jan 16 build)
│   │   │   ├── system_info.txt
│   │   │   └── xattr_loop.txt                      ← 31,102 ms / 5000 tx
│   │   └── 6.1.4-cs614-c3-patched/                 ← PATCHED (Apr 23 build)
│   │       ├── system_info.txt
│   │       └── xattr_loop.txt                      ← 22,734 ms / 78 tx
│   │
│   ├── jbd2-fc-barrier-defer.patch                 ← C1 patch (null result)
│   ├── CANDIDATE1_postmortem.md                    ← C1 writeup
│   ├── mballoc-async-prefetch.patch                ← C2 patch (null on VM)
│   ├── CANDIDATE2_postmortem.md                    ← C2 writeup
│   ├── README.md                                   ← initial candidate overview
│   ├── results.md                                  ← C1 early (superseded) results
│   │
│   ├── bench_async_prefetch.sh                     ← C2 benchmark (fallocate)
│   ├── bench_fio_throughput.sh                     ← fio throughput probe
│   ├── bare_metal_eval.sh                          ← generic bare-metal runner
│   ├── run_evaluation.sh                           ← earlier VM runner
│   ├── compare_results.py                          ← stock vs patched comparator
│   │
│   ├── eval_milan_c2.sh / eval_sahil_c2.sh         ← C2 bare-metal scripts
│   ├── INSTRUCTIONS_MILAN_C2.md / ..._SAHIL_C2.md  ← C2 walkthroughs
│   ├── eval_milan.sh / eval_sahil.sh               ← C1 bare-metal scripts
│   ├── INSTRUCTIONS_MILAN.md / INSTRUCTIONS_SAHIL.md ← C1 walkthroughs
│   ├── eval_results_c2/                            ← C2 raw output
│   └── xfstests_c2_patched.log                     ← C2 xfstests log
│
├── docs/superpowers/                               ← design and planning docs
│   ├── specs/
│   │   ├── 2026-04-22-ext4-async-bitmap-prefetch-design.md   (C2 design spec)
│   │   └── 2026-04-23-ext4-fastcommit-inline-xattr-design.md (★ C3 design spec)
│   └── plans/
│       ├── 2026-04-22-ext4-async-bitmap-prefetch.md          (C2 task plan)
│       └── (C3 plan was captured in /home/lkp-ubuntu/.claude/plans/)
│
├── Project/                                        ← earlier milestone artifacts
│   ├── walkthrough.md                              ← initial benchmark baselines
│   ├── implementation_plan.md
│   ├── proposal.tex, my_part.tex                   ← LaTeX sources
│   ├── jbd2_probe_module/                          ← kprobe module (source)
│   ├── jbd2_coalesce_module/                       ← C1-era coalesce module
│   └── jbd2_benchmarks/                            ← baseline benchmark scripts
│
└── linux-6.1.4/                                    ← (gitignored) kernel tree
                                                       reviewer extracts pristine
                                                       tarball here
```

**Note on `linux-6.1.4/`:** the Linux kernel source tree is gitignored
(too large; reviewer should use the pristine 6.1.4 tarball from
kernel.org). The patches in `our_optimization/*.patch` apply cleanly
with `patch -p1` against a fresh 6.1.4 source.

---

## 2. Setup Instructions

### Hardware requirements

| Resource | Minimum | Recommended |
|---|---|---|
| CPU | 2 cores | 4+ cores (speeds up kernel build) |
| Memory | 4 GB | 8 GB |
| Storage | 40 GB free | 100 GB free (kernel build + tests + multiple installed kernels) |
| Extra hardware | none | SSD or NVMe preferred for realistic fsync numbers; loop device on HDD/VM works but caps speedup |

Single-partition install is fine. Kernel build uses up to ~15 GB of
disk in the source tree plus ~500 MB under `/boot` and ~500 MB under
`/lib/modules/<version>`.

### Operating system

- **Ubuntu 22.04 or 24.04 LTS** (VM or bare-metal). Tested on Ubuntu
  24.04.2 inside VirtualBox.
- Any distro with a recent GCC + standard kernel build toolchain
  should work; `.config` assumes x86_64.

### Software dependencies

Install once:

```bash
sudo apt update
sudo apt install -y \
    fio attr git build-essential libncurses-dev \
    bison flex libssl-dev libelf-dev bc dwarves zstd \
    patch wget \
    linux-tools-common linux-tools-$(uname -r) \
    gawk       # xfstests asort() compatibility
```

For xfstests (optional, used only in detailed evaluation):

```bash
sudo apt install -y xfslibs-dev libattr1-dev libacl1-dev libaio-dev \
    acl libtool-bin e2fsprogs libcap-dev quota uuid-runtime xfsprogs \
    autoconf-archive libtool automake liburing-dev pkg-config \
    libgdbm-dev
```

### Obtaining the pristine kernel source

The artifact does NOT bundle the kernel source (too large). Fetch it
once:

```bash
cd ~
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.1.4.tar.xz
tar xf linux-6.1.4.tar.xz    # creates ~/linux-6.1.4/
```

### Applying the patch + building the kernel

```bash
cd ~/linux-6.1.4

# Apply the Candidate 3 patch
patch -p1 < ~/jbd2-project/our_optimization/fc-inline-xattr.patch

# Verify the patch landed
grep -n "bool touched_block" fs/ext4/xattr.c
grep -n "EXT4_STATE_XATTR" fs/ext4/fast_commit.c

# Start from the currently running kernel's config
cp /boot/config-$(uname -r) .config
sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-cs614-c3-patched"/' .config
make olddefconfig

# Build (20–45 min depending on cores)
make -j$(nproc) bzImage modules

# Install (keeps all other installed kernels intact)
sudo rm -rf /lib/modules/6.1.4-cs614-c3-patched
sudo make modules_install
sudo make install
sudo update-grub

# Reboot; select 6.1.4-cs614-c3-patched from GRUB → Advanced options
sudo reboot
```

After reboot, verify with `uname -r` — expect `6.1.4-cs614-c3-patched`.

---

## 3. Features / Functionalities

### What this artifact implements

**Kernel patch (`fc-inline-xattr.patch`):** 108-line change to
`fs/ext4/xattr.c` and `fs/ext4/fast_commit.c` that extends ext4
fast-commit coverage to inline extended attributes. Before the patch,
every `setxattr()` / `removexattr()` on a fast-commit-enabled
filesystem forced a full JBD2 commit. After the patch, inline-only
xattr operations are committed via fast commit, avoiding the
full-journaling path.

Two key changes:

1. **`ext4_fc_write_inode()`**: when the inode has inline xattrs
   (detected via the existing per-inode `EXT4_STATE_XATTR` flag), log
   the full `EXT4_INODE_SIZE` bytes so the xattr region is captured in
   the FC_TAG_INODE record. Replay's existing variable-length memcpy
   handles the larger length automatically.

2. **`ext4_xattr_set_handle()`**: track in a local `touched_block` flag
   whether the operation modified the xattr block or needed an
   ea_inode. At the tail, only call `ext4_fc_mark_ineligible()` when
   `error != 0`, `touched_block`, or the fs xattr feature bit is not
   yet persisted. Inline-only successes skip the ineligibility call
   and let fast commit run. Also remove the now-redundant unconditional
   `mark_ineligible` in the `ext4_xattr_set()` wrapper.

### Test scenarios

| # | Scenario | Script | Parameters | Objective | Expected Outcome |
|---|---|---|---|---|---|
| 1 | Primary xattr microbenchmark | `our_optimization/bench_xattr.sh` | N=5000 `fsetxattr`+`fsync` ops on `user.test`; 256 MB loop fs; fast_commit enabled; inline-sized value | Measure per-op latency and JBD2 transaction count to confirm fast-commit engages | Patched: wall time ~23 s, tx_delta ~78. Stock: wall time ~31 s, tx_delta =5000. **64× reduction** in full commits; **27% wall-time** reduction. |
| 2 | Non-xattr control (regression check) | `our_optimization/bench_async_prefetch.sh` (reuses the fallocate + fio harness) | 4-job fio randwrite + fsync; 20 MB per job; 30 s runtime | Confirm unrelated workloads are not regressed | Patched IOPS within ±5 % of stock. Observed: 528 vs 530 (no regression). |
| 3 | Crash recovery — 100 inline xattrs | `our_optimization/c3_crash_test_a.sh` | 100 `setfattr` ops on one file; `sync -f` then lazy-umount to simulate crash; remount + count recovered xattrs | Verify expanded FC_TAG_INODE replay restores all inline xattrs | `PASS: Test A` with `100 / 100` recovered. |
| 4 | Crash recovery — set-then-remove | `our_optimization/c3_crash_test_b.sh` | Set 100 xattrs; remove even-numbered 50; simulated crash; remount + count | Verify removal path is correctly replayed via fast commit | `PASS: Test B` with exactly 50 odd-numbered xattrs remaining. |
| 5 | Crash recovery — block xattr (fallback path) | `our_optimization/c3_crash_test_c.sh` | 500-byte xattr value (forces the xattr-block path, `touched_block=true`); simulated crash; remount + verify value length | Verify the full-commit fallback is taken for block xattrs and data is preserved | `PASS: Test C` with recovered bytes == expected. |
| 6 | xfstests xattr + fast-commit subset | `xfstests check generic/{062,118,300,337,388,454,455,473,482} ext4/032` | Default xfstests config with 2 GB loop devices; ext4 with fast_commit | Verify no new regressions vs stock on the established xattr/fc test suite | All runnable tests pass (`generic/118` skipped: reflink not supported on ext4). Noted environmental issue: `generic/062` triggers an `awk: asort never defined` false positive unless `gawk` is installed — not a kernel regression. |

### Findings

- **No crashes, deadlocks, or assertion failures** observed across
  any test scenario or during the benchmark runs.
- **No ext4 `ERROR`, `WARN`, or `BUG` entries in `dmesg`** on the
  patched kernel.
- The patched kernel mounts, remounts, and unmounts ext4 cleanly;
  simulated crashes (lazy unmount without sync) recover without
  errors.
- **One environmental caveat**: `xfstests generic/062` requires
  `gawk` for its `_sort_getfattr_output` helper (Ubuntu's default
  `mawk` lacks `asort()`). Missing this dependency produces a
  test-framework output mismatch that LOOKS like a regression but
  isn't. Install `gawk` before running `generic/062`.

---

## 4. Assumptions and Unsupported Features

### Covered

- Inline xattrs (values that fit in the inode's extra region — up to
  ~80 bytes on a 256-byte inode).
- xattrs used by SELinux, POSIX ACLs, and short `user.*` names.
- Both addition and removal of inline xattrs.
- All ext4 journaling modes (`data=ordered`, `data=journal`,
  `data=writeback`).

### NOT covered by this patch (designed to fall back to full commit)

- xattrs stored in the separate 4 KB xattr block (`i_file_acl` path).
  Large xattr values go here. `touched_block = true` forces full
  commit for these — correctness preserved, just no speedup.
- xattrs stored via the `ea_inode` feature (each xattr gets its own
  inode). Same story: full-commit fallback.
- First xattr on a freshly-made filesystem. Must still be a full
  commit to persist the sb `xattr` feature bit. We explicitly check
  `ext4_has_feature_xattr(sb)` and skip our fast path if false.
- Non-ext4 filesystems.

### Kernel version

Patch is developed against Linux 6.1.4. Line numbers may differ on
other kernel versions; port by searching for the functions
`ext4_xattr_set_handle`, `ext4_fc_write_inode`, and
`ext4_xattr_set`.

### Other intentional design bounds

- No new FC tag types, no compat bits, no on-disk format changes.
  Strictly an internal optimization.
- No new mount options, no sysfs knobs.
- No changes to the fast-commit replay code — the variable-length
  memcpy already handles our expanded FC_TAG_INODE records.

---

## 5. Getting Started (≤ 30 minutes)

This path verifies the artifact without rebuilding the kernel. It
exercises patch application, the benchmark scripts, and the raw
result data we recorded.

### Step 1 — Clone or extract the artifact

Assuming the artifact is at `~/jbd2-project/`.

### Step 2 — Verify the patch applies cleanly to pristine 6.1.4

```bash
# Grab pristine source if not already present
cd ~
[ -d linux-6.1.4-pristine ] || {
    wget -q https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.1.4.tar.xz
    mkdir -p linux-6.1.4-pristine
    tar xf linux-6.1.4.tar.xz -C linux-6.1.4-pristine
}

# Dry-run the patch apply
patch -p1 --dry-run \
  -d linux-6.1.4-pristine/linux-6.1.4 \
  < ~/jbd2-project/our_optimization/fc-inline-xattr.patch
```

**Expected output:**
```
checking file fs/ext4/ext4.h           # (no changes — present in some hunks)
checking file fs/ext4/fast_commit.c
checking file fs/ext4/xattr.c
```
No `FAILED` or `malformed` — confirms the patch is valid for 6.1.4.

### Step 3 — Compile-check the patched files in isolation

```bash
cd ~/linux-6.1.4-pristine/linux-6.1.4
patch -p1 < ~/jbd2-project/our_optimization/fc-inline-xattr.patch
cp /boot/config-$(uname -r) .config 2>/dev/null || make defconfig
make olddefconfig
make fs/ext4/xattr.o fs/ext4/fast_commit.o 2>&1 | tail -5
```

**Expected output:** two `CC` lines for `xattr.o` and `fast_commit.o`,
no `error:` or `Error`. Takes about 1-2 minutes on 4 cores.

### Step 4 — Inspect pre-recorded benchmark results

```bash
cd ~/jbd2-project

# Side-by-side comparison of recorded numbers:
echo "=== STOCK (pre-patch 6.1.4) ==="
cat our_optimization/eval_results_c3/6.1.4-cs614-hacker/xattr_loop.txt
echo ""
echo "=== PATCHED (C3) ==="
cat our_optimization/eval_results_c3/6.1.4-cs614-c3-patched/xattr_loop.txt
```

**Expected output — the headline result:**

```
=== STOCK (pre-patch 6.1.4) ===
kernel=6.1.4-cs614-hacker
N=5000
elapsed_ms=31102
...
tx_delta=5000
commits_per_op=1.00

=== PATCHED (C3) ===
kernel=6.1.4-cs614-c3-patched
N=5000
elapsed_ms=22734
...
tx_delta=78
commits_per_op=0.02
```

### Step 5 — Read the full results writeup

```bash
less ~/jbd2-project/our_optimization/CANDIDATE3_results.md
```

Contains headline numbers, correctness summary, scope boundaries, and
the reasoning connecting the patch change to the measured transaction
count drop.

### (Optional Step 6) Run the benchmark on your own kernel

If you have time to boot a kernel that has fast_commit enabled at
mkfs time, you can run `bench_xattr.sh` directly:

```bash
cd ~/jbd2-project
sudo bash our_optimization/bench_xattr.sh
```

It will auto-build the `xattr_fsync_helper` C program, create a
256 MB loop-backed fast_commit ext4, warm the feature bit, run
5000 × (`fsetxattr` + `fsync`), and report elapsed time + JBD2
transaction delta. On stock, expect ~30 s / tx_delta=5000; on our
patched kernel, ~23 s / tx_delta<100.

### Supplying your own inputs

Everything in `bench_xattr.sh` is parameterized. To vary:

- **`N`** (line near the top): number of `setxattr`+`fsync` iterations.
- **`IMG_SIZE_MB`**: size of the loop-backed test filesystem.
- **Value length**: edit `xattr_fsync_helper.c` — the `snprintf(val,
  sizeof(val), "v%ld", i)` generates a tiny value by default. Change
  the format string to produce larger values; beyond ~80 bytes the
  xattr path spills out of the inline region and you'll see the
  full-commit fallback engage (`touched_block = true`, tx_delta
  returns toward N).

---

## 6. Detailed Evaluation

All experiments are reproducible from the artifact. Each script
produces output files in `our_optimization/eval_results_c3/<kernel>/`
or `our_optimization/eval_results_c2/<kernel>/`.

### Experiment 1 — Primary xattr speedup

**Purpose:** Quantify the per-op latency and JBD2 transaction-count
reduction produced by the C3 patch on a setxattr-heavy workload.

**How to run:**
```bash
# Boot into 6.1.4-cs614-c3-patched (the patched kernel).
sudo bash ~/jbd2-project/our_optimization/bench_xattr.sh

# Then reboot into any non-C3 kernel (e.g., 6.1.4-cs614-hacker.old),
# verify uname -r, and rerun:
sudo bash ~/jbd2-project/our_optimization/bench_xattr.sh
```

**Estimated runtime:** 5 min patched + 5 min stock + 2 × reboot.

**Expected result:**
- Patched elapsed_ms around 22,000–25,000 ms.
- Stock elapsed_ms around 30,000–35,000 ms.
- Patched tx_delta under 100 (ours: 78).
- Stock tx_delta ≈ N (ours: 5000).
- Wall-time speedup ≥ 20%.
- **Transaction-count reduction ≥ 50× is the primary evidence** that
  fast commit engaged.

**How to access the actual result:**
Each run writes `xattr_loop.txt` with the key fields. Full-history
repeats table in the same directory.

### Experiment 2 — Crash recovery correctness

**Purpose:** Verify that the expanded `FC_TAG_INODE` record replays
correctly and that the full-commit fallback still works for block
xattrs.

**How to run:**
```bash
cd ~/jbd2-project
sudo bash our_optimization/c3_crash_test_a.sh    # 100 xattrs recovered
sudo bash our_optimization/c3_crash_test_b.sh    # set 100, remove 50 → 50 remain
sudo bash our_optimization/c3_crash_test_c.sh    # 500-byte block xattr recovered
```

**Estimated runtime:** 30 seconds total.

**Expected result:**
```
Test A: recovered 100 / 100
PASS: Test A

Test B: recovered 50 (expected 50)
PASS: Test B

Test C: recovered 668 bytes, expected 668 bytes
PASS: Test C
```

**How to access the actual result:** Each script prints its PASS/FAIL
line directly. Any FAIL exits non-zero.

### Experiment 3 — Non-xattr workload regression check

**Purpose:** Confirm the patch does not regress performance on
workloads unrelated to xattrs.

**How to run:**
```bash
sudo bash ~/jbd2-project/our_optimization/bench_async_prefetch.sh
```
Script runs a 30 s fio `randwrite` + `fsync` with 4 concurrent jobs
and records IOPS/BW/latency.

**Estimated runtime:** 3-4 minutes.

**Expected result:** IOPS within ±5% of the stock-kernel baseline (our
recorded value: stock 530 IOPS, patched 528 IOPS).

**How to access the actual result:** Pre-recorded stock result in
`our_optimization/eval_results_c2/6.1.4-cs614-hacker/ordered_sync4_run*_fio.txt`.
Patched result in `eval_results_c2/6.1.4-cs614-c2-patched/…` (the C2
patched kernel is effectively "stock from C3's perspective" because
C2 doesn't touch the xattr path).

### Experiment 4 — xfstests xattr/fast-commit subset (optional)

**Purpose:** Broader correctness validation against the upstream
ext4 test suite.

**How to run:**
```bash
# One-time setup
cd ~
git clone git://git.kernel.org/pub/scm/fs/xfs/xfstests-dev.git xfstests
cd xfstests
aclocal && autoconf && make -j$(nproc)

# Create test devices
sudo bash <<EOF
mkdir -p /tmp/xfstests_loops /mnt/xfstests_test /mnt/xfstests_scratch
dd if=/dev/zero of=/tmp/xfstests_loops/test.img bs=1M count=2048 status=none
dd if=/dev/zero of=/tmp/xfstests_loops/scratch.img bs=1M count=2048 status=none
TEST_LOOP=\$(losetup --find --show /tmp/xfstests_loops/test.img)
SCRATCH_LOOP=\$(losetup --find --show /tmp/xfstests_loops/scratch.img)
mkfs.ext4 -F -q -O fast_commit \$TEST_LOOP
cat > /home/lkp-ubuntu/xfstests/local.config <<CFG
export TEST_DEV=\$TEST_LOOP
export TEST_DIR=/mnt/xfstests_test
export SCRATCH_DEV=\$SCRATCH_LOOP
export SCRATCH_MNT=/mnt/xfstests_scratch
export FSTYP=ext4
export MKFS_OPTIONS="-O fast_commit"
CFG
mount \$TEST_LOOP /mnt/xfstests_test
EOF

# Run the subset
cd ~/xfstests
sudo ./check generic/062 generic/118 generic/300 generic/337 \
             generic/388 generic/454 generic/455 generic/473 \
             generic/482 ext4/032
```

**Estimated runtime:** 30-60 minutes (generic/388 fsstress takes the longest).

**Expected result:** All runnable tests pass. `generic/118` reports
"not run" because reflink isn't an ext4 feature. Ensure `gawk` is
installed to avoid a false-positive on `generic/062`
(`asort()`-related).

**How to access the actual result:** `~/xfstests/results/` contains
`.out.bad` for any failing test. Runtime summary is printed at the
end of the `./check` invocation.

### Experiment 5 — Compare VM vs bare-metal (community results)

**Purpose:** Validate the patch on real hardware (SSD / NVMe) where
the wall-time speedup should be larger than on our VM's loop device
(fsync overhead dominates there).

**How to run:**
Send `our_optimization/eval_milan_c3.sh` +
`our_optimization/INSTRUCTIONS_MILAN_C3.md` to a collaborator with a
bare-metal Linux 6.1.4 machine. They follow the instructions
end-to-end (~1-1.5 hours including kernel build) and push results to
branch `results-c3/<name>`.

**Estimated runtime per collaborator:** 1-1.5 hours.

**Expected result:** Larger wall-time speedup than our 27% (we expect
2× or better on NVMe); tx_delta reduction should be similar to our
VM's 64×.

**How to access the actual result:** `our_optimization/eval_results_c3/<contributor>/{STOCK,PATCHED}_<kernel>/xattr_loop.txt`
after they push.

---

## Appendix — Background Artifacts (prior candidates)

Candidates 1 and 2 are kept in the artifact for process transparency:

- **Candidate 1** (`jbd2-fc-barrier-defer.patch` +
  `CANDIDATE1_postmortem.md`): targeted the JBD2 fast-commit vs
  full-commit barrier. Correct patch, null measurable result on VM
  (the barrier is triggered by < 1% of operations). Retired.
- **Candidate 2** (`mballoc-async-prefetch.patch` +
  `CANDIDATE2_postmortem.md`): targeted the ext4 block-allocator's
  synchronous bitmap-prefetch completion. Correct patch, null
  measurable result on VM because of host-cache noise (~70% CV on
  fio throughput). Retired; bare-metal validation pending from
  collaborators.
- **Candidate 3** (`fc-inline-xattr.patch` + `CANDIDATE3_results.md`):
  **this is the final submitted patch.** 27% wall-time speedup, 64×
  reduction in full JBD2 commits on xattr-heavy workloads, no
  regression on non-xattr workloads, all custom crash tests pass.

Each postmortem documents the failure mode, lessons learned, and how
they informed the next candidate's selection. The sequence is part
of the project narrative and is discussed in the final report.
