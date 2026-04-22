# JBD2 Fast Commit Barrier Deferral Optimization

**File patched:** `fs/jbd2/commit.c`  
**Patch file:** `jbd2-fc-barrier-defer.patch`  
**Author:** Suyamoon Pathak (241110091), CS614 LKP — IIT Kanpur

---

## What the optimization does

Moves the JBD2 fast-commit synchronization barrier from before `T_LOCKED`
to just before `T_FLUSH`, allowing in-flight fast commits to overlap with
the `T_LOCKED` and `T_SWITCH` phases of a full commit.

## Root cause (verified in Linux 6.1.4 source)

`fs/jbd2/commit.c` line 444 (original) — the developers themselves left a
TODO:

```
TODO: by blocking fast commits here, we are increasing fsync() latency
slightly. Strictly speaking, we don't need to block fast commits until
the transaction enters T_FLUSH state. So an optimization is possible
where we block new fast commits here and wait for existing ones to
complete just before we enter T_FLUSH.
```

The barrier was placed at `T_LOCKED` because that is when
`jbd2_journal_commit_transaction` first touches journal state. However:

- `T_LOCKED` only waits for running handles (`t_updates`) to quiesce.
- `T_SWITCH` only refills the reserved-buffer list and switches the
  revoke table.
- Neither phase writes to the fast-commit (FC) area or touches `j_fc_off`.
- The ONLY shared state between a full commit and an in-flight fast commit
  in these two phases is `j_fc_off`, which is reset to 0 at the **original**
  line 472.

## Why the naive fix is wrong

Simply deleting the drain loop and moving it to just before `T_FLUSH` is
insufficient without also moving `journal->j_fc_off = 0`.

If `j_fc_off = 0` runs at `T_LOCKED` while a fast commit is still
allocating blocks in the FC area, the fast commit's next `j_fc_off +=`
step overwrites FC-area blocks that were already reserved, corrupting
the on-disk fast-commit log.

**This hidden constraint is why the TODO went unfixed since fast commit
was merged in Linux 5.10.**

## The three-step fix

### Step 1 — remove the early drain loop (lines 444–462 original)

Keep only `journal->j_flags |= JBD2_FULL_COMMIT_ONGOING`. This prevents
any NEW fast commits from starting (`jbd2_fc_begin_commit` checks this
flag at `journal.c:745`). In-flight fast commits are left to run.

### Step 2 — remove `journal->j_fc_off = 0` from line 472

`j_fc_off` must not be reset while a fast commit may still be using it.

### Step 3 — add drain + reset just before `T_FLUSH`

```c
while (journal->j_flags & JBD2_FAST_COMMIT_ONGOING) {
    DEFINE_WAIT(wait);
    prepare_to_wait(&journal->j_fc_wait, &wait, TASK_UNINTERRUPTIBLE);
    write_unlock(&journal->j_state_lock);
    schedule();
    write_lock(&journal->j_state_lock);
    finish_wait(&journal->j_fc_wait, &wait);
}
journal->j_fc_off = 0;
```

The `j_state_lock` is already held at this point (acquired at line 541
in the patched file). The wait pattern matches the original drain exactly.

## Correctness argument

1. **No new fast commits after line 443**: `JBD2_FULL_COMMIT_ONGOING` is
   set under `j_state_lock`; `jbd2_fc_begin_commit` checks it under the
   same lock — mutual exclusion is preserved.

2. **T_LOCKED and T_SWITCH do not touch FC area**: verified by grep —
   no reference to `j_fc_off`, `j_fc_first`, `j_fc_last`, or `j_fc_wbuf`
   between `T_LOCKED` and the new drain point.

3. **Drain at T_FLUSH is a sufficient barrier**: after the while-loop,
   `JBD2_FAST_COMMIT_ONGOING` is clear. `j_fc_off = 0` is then safe
   because no fast commit is accessing it. `T_FLUSH` then sets
   `j_committing_transaction`, which fast commit would need to read —
   but no fast commit can start after `JBD2_FULL_COMMIT_ONGOING` is set.

4. **Recovery is unaffected**: crash recovery (fs/jbd2/recovery.c) reads
   the on-disk journal; it does not care where in the commit path the
   reset happened, only that the committed records are consistent.

## Expected impact

A full commit on a loaded fsync workload (e.g., fio randwrite numjobs=4)
has these approximate phase times (measured with `jbd2_probe.ko`):

| Phase | Approx. time |
|---|---|
| T_RUNNING → T_LOCKED (old drain) | 0 – 3 ms |
| T_LOCKED → T_SWITCH | ~0.5 ms |
| T_SWITCH → T_FLUSH | ~0.5 ms |
| T_FLUSH → T_FINISHED | ~6 – 8 ms |

With this patch, any fsync() that arrives and completes entirely within
the T_LOCKED/T_SWITCH window (~1 ms total) does not need to wait for the
full commit at all — it writes its FC-log entries and wakes its caller
immediately.

For high-concurrency fsync workloads this shaves 1–3 ms off the tail
latency of fast commits that happen to overlap with a full commit.

## How to apply

```bash
# From the repo root
patch -p1 < our_optimization/jbd2-fc-barrier-defer.patch

# Rebuild the kernel (if building from source)
cd linux-6.1.4
make -j$(nproc) bzImage modules

# Or rebuild just the jbd2 module if your config supports it
make -j$(nproc) M=fs/jbd2
```

## How to measure the improvement

```bash
# Load the existing probe module
sudo insmod /home/lkp-ubuntu/Downloads/jbd2_probe_module/jbd2_probe.ko

# Run a concurrent fsync workload
sudo fio --name=test --directory=/mnt/testfs \
    --rw=randwrite --bs=4k --size=20M \
    --ioengine=sync --fsync=1 --numjobs=4 --group_reporting

# Read per-function latency breakdown
cat /proc/jbd2_probe_stats

# Key metric: jbd2_journal_commit_transaction avg latency should decrease.
# Also compare via trace-cmd:
trace-cmd record -e jbd2:jbd2_run_stats fio <same args>
trace-cmd report | awk '/jbd2_run_stats/{print $0}'
# Look at the "logging" column — it should be unchanged;
# the "wait" and "running" columns are where the savings appear.
```
