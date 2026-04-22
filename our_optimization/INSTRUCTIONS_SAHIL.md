# JBD2 Fast Commit Optimization — Evaluation Instructions (Sahil)

Hi Sahil — please run these steps on your bare-metal laptop that has
**Linux 6.1.4** installed. The whole thing takes ~1 hour (mostly waiting for
the kernel build). Push results back when done.

---

## Two directories you'll work in

Throughout this guide you will switch between **two** separate directories on
your laptop. Keep them mentally distinct:

| Name | Path | Purpose |
|---|---|---|
| **REPO**       | `~/jbd2-project` | Our git repo — holds the patch, scripts, and results |
| **KERNEL_SRC** | `~/linux-6.1.4`  | Clean Linux 6.1.4 source tree — you apply the patch and run `make` here |

Every command below has a `# in REPO` or `# in KERNEL_SRC` comment telling
you which directory to be in. If the comment doesn't match your current
location, `cd` before running.

---

## 0. Prerequisites (one-time setup)

Install benchmark tools and kernel build dependencies:

```bash
sudo apt update
sudo apt install -y fio trace-cmd git build-essential libncurses-dev \
                    bison flex libssl-dev libelf-dev bc dwarves zstd \
                    patch wget
```

Get a clean Linux 6.1.4 source tree — this is **KERNEL_SRC**:

```bash
cd ~
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.1.4.tar.xz
tar xf linux-6.1.4.tar.xz
# You now have ~/linux-6.1.4/   ← this is KERNEL_SRC
```

Clone our repo — this is **REPO**:

```bash
cd ~
git clone <REPO_URL> jbd2-project
# You now have ~/jbd2-project/   ← this is REPO

cd ~/jbd2-project
git checkout -b results/sahil
```

---

## 1. Run on STOCK kernel (before applying any patch)

You must be booted into Linux 6.1.4. Verify:

```bash
uname -r    # should show 6.1.4-...
```

Run the evaluation from inside REPO:

```bash
# in REPO
cd ~/jbd2-project
sudo bash our_optimization/eval_sahil.sh
```

This takes ~15 minutes. Results are saved to
`our_optimization/eval_results/sahil/STOCK_<kernel>/`.

Commit and push immediately so nothing is lost:

```bash
# in REPO
cd ~/jbd2-project
git add our_optimization/eval_results/sahil/
git commit -m "sahil: stock baseline results"
git push -u origin results/sahil
```

---

## 2. Apply the patch to KERNEL_SRC

```bash
# in KERNEL_SRC
cd ~/linux-6.1.4

patch -p1 < ~/jbd2-project/our_optimization/jbd2-fc-barrier-defer.patch
# Expected output: "patching file fs/jbd2/commit.c"

# Verify the patch applied (should find our new comment)
grep -n "Drain any fast commits" fs/jbd2/commit.c
```

---

## 3. Build the patched kernel

Still inside KERNEL_SRC:

```bash
# in KERNEL_SRC
cd ~/linux-6.1.4

# Use your currently-running kernel's config as the base
cp /boot/config-$(uname -r) .config
make olddefconfig

# Build (this is the long part — 20 to 45 min depending on cores)
make -j$(nproc) bzImage modules

# Install modules and kernel
sudo make modules_install
sudo make install

# Update GRUB to boot the new kernel by default
sudo update-grub
```

### If `make install` or GRUB complains about missing `.ko.zst` files

Leftover stale modules from a previous kernel build. Fix:

```bash
# in KERNEL_SRC
cd ~/linux-6.1.4
sudo rm -rf /lib/modules/6.1.4-cs614-hacker
sudo make modules_install
sudo update-initramfs -u -k 6.1.4-cs614-hacker
sudo update-grub
```

---

## 4. Reboot into the patched kernel

```bash
sudo reboot
```

At the GRUB menu, select **`6.1.4-cs614-hacker`** (the kernel you just built).

After reboot, confirm you're on it:

```bash
uname -r          # should show: 6.1.4-cs614-hacker
```

### If boot drops into initramfs (busybox shell)

Reboot, pick any working kernel from GRUB (e.g., your previous Ubuntu
kernel), then in that working kernel run:

```bash
# in KERNEL_SRC
cd ~/linux-6.1.4
sudo rm -rf /lib/modules/6.1.4-cs614-hacker
sudo make modules_install
sudo update-initramfs -c -k 6.1.4-cs614-hacker
sudo update-grub
sudo reboot    # try booting 6.1.4-cs614-hacker again
```

---

## 5. Run on PATCHED kernel

Once `uname -r` shows `6.1.4-cs614-hacker`, run the evaluation from REPO:

```bash
# in REPO
cd ~/jbd2-project
sudo bash our_optimization/eval_sahil.sh
```

Results go to `our_optimization/eval_results/sahil/PATCHED_<kernel>/`.
Summary table will print at the end.

---

## 6. Push the patched results

```bash
# in REPO
cd ~/jbd2-project
git add our_optimization/eval_results/sahil/
git commit -m "sahil: patched kernel results"
git push origin results/sahil
```

Either open a pull request from `results/sahil` to `master`, or just let
Suyamoon know the branch is ready.

---

## What to do if something goes wrong

**Build fails:** Send the last 50 lines of the build output.

**Benchmark numbers look way off** (e.g., patched slower than stock): Re-run
once to rule out noise, and send the `system_info.txt` from both runs.

**Can't boot the patched kernel at all:** Don't panic — boot any other
kernel from GRUB, then follow the initramfs fix above. Send the error
message from the initramfs shell if the fix doesn't help.

Ping Suyamoon with any errors and he'll help debug.
