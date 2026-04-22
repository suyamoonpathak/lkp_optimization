# Candidate 2 Evaluation Instructions (Milan)

Hi Milan — this is a **new patch** (Candidate 2), separate from the earlier
barrier-deferral work (which we retired after it showed null results on VM).

Candidate 2 targets a different code path: `ext4_mb_prefetch_fini()` in the
block allocator. It implements an explicit kernel-developer TODO — defer
buddy-bitmap init to a workqueue when the bitmap isn't cached.

On our VM, the effect was within noise (host-cache effects dominate). You
have real SSD storage and more RAM, so the effect has a real chance of
showing up on your machine. That's why we need your run.

**Estimated time:** ~1.5 hours (most of it is the kernel build + reboots).

---

## Two directories you'll work in

| Name | Path | Purpose |
|---|---|---|
| **REPO**       | `~/jbd2-project` | Our git repo — holds the patch + scripts + results |
| **KERNEL_SRC** | `~/linux-6.1.4`  | Clean Linux 6.1.4 source tree — patch applies and `make` runs here |

Every command below has a `# in REPO` or `# in KERNEL_SRC` comment telling
you which directory to be in.

---

## 0. Prerequisites (one-time)

```bash
sudo apt update
sudo apt install -y fio git build-essential libncurses-dev bison flex \
                    libssl-dev libelf-dev bc dwarves zstd patch wget \
                    linux-tools-common linux-tools-$(uname -r)
```

If you don't already have a pristine Linux 6.1.4 tree:
```bash
cd ~
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.1.4.tar.xz
tar xf linux-6.1.4.tar.xz     # creates ~/linux-6.1.4/
```

Pull the latest from our repo:
```bash
cd ~/jbd2-project
git checkout master
git pull
```

Create your branch for these results:
```bash
cd ~/jbd2-project
git checkout -b results-c2/milan
```

---

## 1. Run on STOCK kernel first

You must be booted into a Linux 6.1.4 kernel that has NOT been patched
with Candidate 2 yet. If you're still booted into the Candidate-1 kernel
(`6.1.4-cs614-hacker`), that's fine — Candidate 1 did not touch the
allocator code path, so it's effectively "stock" for Candidate 2.

Verify with `uname -r` — should show some `6.1.4-*` variant.

```bash
# in REPO
cd ~/jbd2-project
sudo bash our_optimization/eval_milan_c2.sh
```

Runtime: ~20 min. Results are saved to
`our_optimization/eval_results_c2/milan/STOCK_<kernel>/`.

Commit and push right away:

```bash
# in REPO
cd ~/jbd2-project
git add our_optimization/eval_results_c2/milan/
git commit -m "milan: c2 stock baseline"
git push -u origin results-c2/milan
```

---

## 2. Apply the Candidate 2 patch to KERNEL_SRC

```bash
# in KERNEL_SRC
cd ~/linux-6.1.4

patch -p1 < ~/jbd2-project/our_optimization/mballoc-async-prefetch.patch
# Expected: "patching file fs/ext4/ext4.h" and "patching file fs/ext4/mballoc.c"

# Verify the patch applied
grep -n "ext4_bitmap_init_work" fs/ext4/mballoc.c | head
# Expected: 2-3 matches
```

If `patch` complains about "already patched" or "not found" — make sure
you applied this to a PRISTINE 6.1.4 tree. If you previously applied the
Candidate 1 patch (`jbd2-fc-barrier-defer.patch`), that's in a different
file (`fs/jbd2/commit.c`) so it doesn't conflict. But if you have stale
modifications anywhere, reset first:
```bash
cd ~/linux-6.1.4 && git checkout . 2>/dev/null \
    || (cd ~ && rm -rf linux-6.1.4 && tar xf linux-6.1.4.tar.xz && \
        cd linux-6.1.4 && patch -p1 < ~/jbd2-project/our_optimization/mballoc-async-prefetch.patch)
```

---

## 3. Build the patched kernel with a distinct LOCALVERSION

We use a distinct name so it coexists with your stock / C1 kernel and
rollback is just a reboot.

```bash
# in KERNEL_SRC
cd ~/linux-6.1.4

# Copy your currently-running kernel's config as baseline
cp /boot/config-$(uname -r) .config

# Set the version suffix
sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-cs614-c2-patched"/' .config
grep "^CONFIG_LOCALVERSION=" .config
# Expected: CONFIG_LOCALVERSION="-cs614-c2-patched"

make olddefconfig

# Build — 20-45 min depending on cores
make -j$(nproc) bzImage modules

# Install
sudo rm -rf /lib/modules/6.1.4-cs614-c2-patched    # clear any stale modules
sudo make modules_install
sudo make install

# Update GRUB so you can pick it
sudo update-grub
```

### If `make install` complains about missing `.ko.zst` files

```bash
# in KERNEL_SRC
cd ~/linux-6.1.4
sudo rm -rf /lib/modules/6.1.4-cs614-c2-patched
sudo make modules_install
sudo update-initramfs -u -k 6.1.4-cs614-c2-patched
sudo update-grub
```

---

## 4. Reboot into the patched kernel

```bash
sudo reboot
```

In the GRUB menu, select **"Advanced options for Ubuntu"** → the entry
containing `6.1.4-cs614-c2-patched`.

After login, confirm:
```bash
uname -r          # should show: 6.1.4-cs614-c2-patched
```

If GRUB boots the wrong kernel, reboot and pick again. If it drops to an
initramfs shell, boot any other working kernel from GRUB, then:
```bash
# in KERNEL_SRC
cd ~/linux-6.1.4
sudo rm -rf /lib/modules/6.1.4-cs614-c2-patched
sudo make modules_install
sudo update-initramfs -c -k 6.1.4-cs614-c2-patched
sudo update-grub
sudo reboot
```

---

## 5. Run the same benchmark on the PATCHED kernel

```bash
# in REPO
cd ~/jbd2-project
sudo bash our_optimization/eval_milan_c2.sh
```

Results go to `our_optimization/eval_results_c2/milan/PATCHED_<kernel>/`.
The script auto-detects "PATCHED" by scanning your kernel source for the
new `ext4_bitmap_init_work` struct.

---

## 6. Push the patched results

```bash
# in REPO
cd ~/jbd2-project
git add our_optimization/eval_results_c2/milan/
git commit -m "milan: c2 patched results"
git push origin results-c2/milan
```

Then either open a pull request from `results-c2/milan` to `master`, or
just ping Suyamoon that the branch is ready.

---

## What we care about in the numbers

Compare the STOCK and PATCHED result directories:

- `fallocate_latencies_us.txt` — per-allocation wall time. Look at p95/p99.
- `fio_repeats.txt` — 5 sequential-write runs. Compare mean ± stddev.
- `perf_sched_latency.txt` — look at `ext4_mb_*` sleep times.

The patch should:
- Reduce p95/p99 of fallocate allocation latency (cold cache wins).
- Possibly improve fio throughput if the allocator was a bottleneck.
- NOT regress anything.

If the numbers show a regression, that's also an important result — send
them anyway.

---

## If something goes wrong

- **Build fails:** send the last 50 lines of the build log.
- **Kernel won't boot:** just reboot and pick any other kernel from GRUB.
  The patched kernel is installed with a unique name; your other kernels
  are untouched.
- **Benchmark errors:** send the tail of the script output.
- **Anything weird:** ping Suyamoon.
