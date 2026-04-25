# Candidate 3 Bare-metal Evaluation Instructions

This is the candidate that worked on our VM: 64× fewer
JBD2 commits and 27% wall-time speedup on a xattr+fsync workload, no
regressions elsewhere, all crash-recovery tests pass.

The 27% wall-time number is limited by VM loop-device fsync overhead.
On your bare-metal SSD the same patch should show a bigger speedup
because the VFS/write-back term that dominates our VM numbers is much
smaller on real storage.

**Estimated time:** ~1–1.5 hours (most of it is the kernel build).

---

## Two directories you'll work in

| Name | Path | Purpose |
|---|---|---|
| **REPO**       | `~/jbd2-project` | Our git repo — holds the patch, scripts, results |
| **KERNEL_SRC** | `~/linux-6.1.4`  | Pristine Linux 6.1.4 source — patch applies and `make` runs here |

Every command below has `# in REPO` or `# in KERNEL_SRC` — match
your cwd to the comment.

---

## 0. Prerequisites (one-time)

```bash
sudo apt update
sudo apt install -y fio attr git build-essential libncurses-dev \
                    bison flex libssl-dev libelf-dev bc dwarves zstd \
                    patch wget
```

Get a clean Linux 6.1.4 source if you don't have one:
```bash
cd ~
[ -d linux-6.1.4 ] || { wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.1.4.tar.xz && tar xf linux-6.1.4.tar.xz; }
```

Pull the latest from our repo:
```bash
cd ~/jbd2-project
git checkout master
git pull
```

Create your branch for C3 results:
```bash
cd ~/jbd2-project
git checkout -b results-c3/milan
```

---

## 1. Run on STOCK kernel first

You need to be on a Linux 6.1.4 kernel that has NOT been patched with
C3. **C1 and C2 patched kernels ARE "stock" for C3** because C1/C2
don't touch the xattr code path. Verify with:

```bash
uname -r   # any 6.1.4-* except *-c3-patched
```

Run the benchmark:

```bash
# in REPO
cd ~/jbd2-project
sudo bash our_optimization/eval_baremetal_c3.sh
```

Runtime ~5 min. Auto-detects STOCK vs PATCHED by scanning your kernel
source tree for `bool touched_block` (absent = stock).

Results save to `our_optimization/eval_results_c3/baremetal/STOCK_<kernel>/`.

Commit and push right away:
```bash
# in REPO
cd ~/jbd2-project
git add our_optimization/eval_results_c3/baremetal/
git commit -m "milan: c3 stock baseline"
git push -u origin results-c3/milan
```

---

## 2. Apply the Candidate 3 patch to KERNEL_SRC

```bash
# in KERNEL_SRC
cd ~/linux-6.1.4

# If you previously applied C1 (jbd2-fc-barrier-defer.patch) or C2
# (mballoc-async-prefetch.patch), reset first so C3 goes onto pristine
# sources:
git status --short 2>/dev/null || \
    echo "Not a git repo — if files look modified, re-extract the tarball."

# For a truly clean start, re-extract if needed:
# cd ~ && rm -rf linux-6.1.4 && tar xf linux-6.1.4.tar.xz && cd linux-6.1.4

patch -p1 < ~/jbd2-project/our_optimization/fc-inline-xattr.patch
# Expected: "patching file fs/ext4/fast_commit.c"
#           "patching file fs/ext4/xattr.c"

# Verify the patch applied
grep -n "bool touched_block" fs/ext4/xattr.c
# Expected: one match around line 2298
grep -n "EXT4_STATE_XATTR" fs/ext4/fast_commit.c
# Expected: one match around line 888
```

---

## 3. Build the patched kernel

```bash
# in KERNEL_SRC
cd ~/linux-6.1.4

cp /boot/config-$(uname -r) .config
sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-cs614-c3-patched"/' .config
grep "^CONFIG_LOCALVERSION=" .config
# Expected: CONFIG_LOCALVERSION="-cs614-c3-patched"

make olddefconfig
make -j$(nproc) bzImage modules     # ~20-45 min

sudo rm -rf /lib/modules/6.1.4-cs614-c3-patched     # clear stale
sudo make modules_install
sudo make install
sudo update-grub
```

### If `make install` gripes about `.ko.zst` files

```bash
cd ~/linux-6.1.4
sudo rm -rf /lib/modules/6.1.4-cs614-c3-patched
sudo make modules_install
sudo update-initramfs -u -k 6.1.4-cs614-c3-patched
sudo update-grub
```

---

## 4. Reboot into the patched kernel

```bash
sudo reboot
```

In GRUB, choose **Advanced options for Ubuntu** → the entry containing
**`6.1.4-cs614-c3-patched`**.

After login:
```bash
uname -r          # 6.1.4-cs614-c3-patched
uname -a          # build date should be today
```

If it drops to an initramfs shell: reboot any other working kernel, then:
```bash
# in KERNEL_SRC
cd ~/linux-6.1.4
sudo rm -rf /lib/modules/6.1.4-cs614-c3-patched
sudo make modules_install
sudo update-initramfs -c -k 6.1.4-cs614-c3-patched
sudo update-grub
sudo reboot
```

---

## 5. Run the PATCHED benchmark

```bash
# in REPO
cd ~/jbd2-project
sudo bash our_optimization/eval_baremetal_c3.sh
```

The script auto-detects PATCHED by finding `bool touched_block` in
your source tree.

Results save to `our_optimization/eval_results_c3/baremetal/PATCHED_<kernel>/`.

Runtime ~5 min.

---

## 6. Run correctness tests (optional but valuable)

Three focused crash-recovery tests (~30 seconds total):

```bash
# in REPO
cd ~/jbd2-project
sudo bash our_optimization/c3_crash_test_a.sh   # 100 inline xattrs → crash → all must recover
sudo bash our_optimization/c3_crash_test_b.sh   # set 100, remove 50 → crash → exactly 50 remain
sudo bash our_optimization/c3_crash_test_c.sh   # 500-byte block xattr → crash → full value recovered
```

All three must end with `PASS: Test X`. If any fails, capture the
output and let Suyamoon know before pushing benchmark results.

---

## 7. Push patched results

```bash
# in REPO
cd ~/jbd2-project
git add our_optimization/eval_results_c3/baremetal/
git commit -m "milan: c3 patched results"
git push origin results-c3/milan
```

Open a PR from `results-c3/milan` → `master`, or just ping Suyamoon.

---

## What we're looking for

Compare `STOCK_<kernel>/xattr_loop.txt` vs `PATCHED_<kernel>/xattr_loop.txt`:

- **tx_delta_mean:** must drop dramatically (our VM: 5000 → 78, a 64×
  reduction). **This is the key signal** that fast commit is engaging.
- **elapsed_ms_mean:** should drop. On our VM: 27%. On your SSD:
  hopefully much more (2× or better).
- **per_op_us_mean:** same trend as elapsed_ms.

If the transaction count doesn't drop meaningfully on patched, something's
wrong — flag it before pushing.

---

## Troubleshooting

- **Build fails:** send last 50 lines of the build log.
- **Won't boot patched:** reboot any other kernel from GRUB. Your
  other kernels are untouched. Follow the initramfs fix above.
- **Benchmark returns weird numbers** (e.g., patched slower than
  stock): re-run once to rule out noise, send both
  `system_info.txt` files.
- **Anything else:** ping Suyamoon.
