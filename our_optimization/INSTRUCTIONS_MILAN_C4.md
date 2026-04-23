# Candidate 4 Evaluation Instructions (Milan)

Hi Milan — **short one this time.** You already have the whole C3
setup (source tree, kernel configs, GRUB entries). C4 is a separate,
small patch on `fs/ext4/extents.c` — 46 lines total, two hunks — that
adds fast-commit support for `fallocate(FALLOC_FL_COLLAPSE_RANGE)` and
`fallocate(FALLOC_FL_INSERT_RANGE)`.

On the VM we see:

- **62.5× fewer JBD2 full commits** (1001 → 16 per 1000 ops).
- **~24% wall-time speedup** for both collapse and insert.

Same architectural pattern as C3. We expect the transaction count to
drop identically on your hardware (it's a structural claim). Wall-time
gain should be larger than VM's 24% because real SSDs amortize the
non-journal cost less.

**Estimated time:** ~30–45 minutes. No xfstests this round — I already
ran them on the VM. Just the benchmark.

---

## Two directories you'll work in

| Name | Path | Purpose |
|---|---|---|
| **REPO**       | `~/jbd2-project` | Our git repo — holds the patch and bench |
| **KERNEL_SRC** | `~/linux-6.1.4`  | Linux 6.1.4 source — the one you used for C3 |

---

## 0. Update the repo and source tree

```bash
# in REPO
cd ~/jbd2-project
git checkout master
git pull
```

This pulls `fc-fallocate-range.patch`, `fallocate_range_helper.c`,
`bench_fallocate_range.sh`, and `eval_milan_c4.sh`.

---

## 1. Baseline run (kernel WITHOUT C4)

You can run the baseline on any 6.1.4 kernel that **does not** have
C4 applied. **Your existing `6.1.4-cs614-c3-patched` counts as
baseline for C4** because C3 doesn't touch `fs/ext4/extents.c` — the
fallocate path is unchanged from stock on a C3-only kernel.

So: stay on whatever you're booted into (stock, C3, whatever), and run:

```bash
# in REPO
cd ~/jbd2-project
uname -r   # any 6.1.4-* except the one you'll build in step 2
sudo bash our_optimization/eval_milan_c4.sh
```

Runtime ~2 min. Auto-detects BASELINE by scanning your kernel
source tree for the C4 identifier (absent = baseline).

Results save to
`our_optimization/eval_results_c4/milan/BASELINE_<kernel>/`.

Push right away so we have it on record:

```bash
# in REPO
cd ~/jbd2-project
git checkout -b results-c4/milan
git add our_optimization/eval_results_c4/milan/
git commit -m "milan: c4 baseline (C3-kernel, arch-equivalent to stock for fallocate)"
git push -u origin results-c4/milan
```

---

## 2. Apply the C4 patch to KERNEL_SRC

```bash
# in KERNEL_SRC
cd ~/linux-6.1.4

# If your tree already has C3 applied, C4 goes cleanly on top.
# If you want a C4-only kernel (no C3), re-extract the pristine
# tarball first. For a combined C3+C4 kernel, keep C3 applied.

patch -p1 < ~/jbd2-project/our_optimization/fc-fallocate-range.patch
# Expected: "patching file fs/ext4/extents.c"

# Verify the patch applied
grep -n "ext4_fc_track_range(handle, inode, punch_start" fs/ext4/extents.c
# Expected: one match around line 5374
grep -n "ext4_fc_track_range(handle, inode, offset_lblk" fs/ext4/extents.c
# Expected: one match around line 5531
grep -c "EXT4_FC_REASON_FALLOC_RANGE" fs/ext4/extents.c
# Expected: 2   (both are now only in code comments we added)
```

---

## 3. Build the C4 kernel

```bash
# in KERNEL_SRC
cd ~/linux-6.1.4

cp /boot/config-$(uname -r) .config
sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-cs614-c4-patched"/' .config
grep "^CONFIG_LOCALVERSION=" .config
# Expected: CONFIG_LOCALVERSION="-cs614-c4-patched"

make olddefconfig
make -j$(nproc) bzImage modules     # ~20-45 min

sudo rm -rf /lib/modules/6.1.4-cs614-c4-patched     # clear stale
sudo make modules_install
sudo make install
sudo update-grub
```

If `make install` gripes about `.ko.zst` files, same fix as C3:

```bash
cd ~/linux-6.1.4
sudo rm -rf /lib/modules/6.1.4-cs614-c4-patched
sudo make modules_install
sudo update-initramfs -u -k 6.1.4-cs614-c4-patched
sudo update-grub
```

---

## 4. Reboot into the C4 kernel

```bash
sudo reboot
```

In GRUB, choose **Advanced options for Ubuntu** → the entry containing
**`6.1.4-cs614-c4-patched`**.

After login:

```bash
uname -r          # 6.1.4-cs614-c4-patched
uname -a          # build date should be today
```

If it drops to an initramfs shell: reboot into any working kernel
from GRUB — C3 and stock are untouched — then:

```bash
cd ~/linux-6.1.4
sudo rm -rf /lib/modules/6.1.4-cs614-c4-patched
sudo make modules_install
sudo update-initramfs -c -k 6.1.4-cs614-c4-patched
sudo update-grub
sudo reboot
```

---

## 5. Run the PATCHED benchmark

```bash
# in REPO
cd ~/jbd2-project
sudo bash our_optimization/eval_milan_c4.sh
```

The script auto-detects PATCHED_C4 by finding
`ext4_fc_track_range(handle, inode, punch_start` in your source tree.

Results save to
`our_optimization/eval_results_c4/milan/PATCHED_C4_<kernel>/`.

Runtime ~2 min.

---

## 6. (Optional) crash-recovery tests

Three short tests (~45 seconds total):

```bash
# in REPO
cd ~/jbd2-project
sudo bash our_optimization/c4_crash_test_a.sh   # collapse 32 blocks → crash → verify md5+size
sudo bash our_optimization/c4_crash_test_b.sh   # insert 16 blocks  → crash → verify md5+size
sudo bash our_optimization/c4_crash_test_c.sh   # interleaved collapse/insert → crash → verify
```

All three must end with `PASS: Test X`. If any fails, capture the
output and ping Suyamoon before pushing benchmark results.

---

## 7. Push patched results

```bash
# in REPO
cd ~/jbd2-project
git add our_optimization/eval_results_c4/milan/
git commit -m "milan: c4 patched results"
git push origin results-c4/milan
```

Open a PR from `results-c4/milan` → `master`, or just ping Suyamoon.

---

## What we're looking for

Compare
`BASELINE_<kernel>/collapse_summary.txt` vs
`PATCHED_C4_<kernel>/collapse_summary.txt` (and insert):

- **tx_delta_mean:** must drop dramatically (our VM: 1001 → 16, a
  62.5× reduction). **This is the key signal** that fast commit is
  engaging for fallocate range ops.
- **elapsed_ms_mean:** should drop. On our VM: ~24% for both modes.
  On your SSD: hopefully more.
- **per_op_us_mean:** same trend as elapsed_ms.
- **commits_per_op:** must go from ~1.0 on baseline to ~0.02 on
  patched.

If the transaction count doesn't drop on patched, something is wrong
— flag it before pushing.

---

## Troubleshooting

- **Build fails:** send last 50 lines of the build log.
- **Won't boot C4:** reboot into any other GRUB entry (stock, hacker,
  c3-patched all untouched). Follow the initramfs fix above.
- **Benchmark shows no reduction on PATCHED_C4:** check that
  `grep -c EXT4_FC_REASON_FALLOC_RANGE fs/ext4/extents.c` is 2 and
  that the matches are inside `/* */` comments (the live calls
  should be gone).
- **Anything else:** ping Suyamoon.
