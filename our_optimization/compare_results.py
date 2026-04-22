#!/usr/bin/env python3
"""
Compare stock vs patched JBD2 evaluation results.
Usage: python3 compare_results.py eval_results/STOCK_* eval_results/PATCHED_*
"""
import sys, os, re, glob
from statistics import mean, stdev

def parse_fio(path):
    """Extract IOPS, BW, avg latency, p99 latency from a fio output file."""
    d = {}
    try:
        txt = open(path).read()
        m = re.search(r'IOPS=([0-9.]+)k?', txt)
        if m:
            v = float(m.group(1))
            d['iops'] = v * 1000 if 'k' in txt[m.start():m.end()+1] else v
        m = re.search(r'BW=([0-9.]+)\s*(KiB|MiB|GiB)', txt)
        if m:
            bw, unit = float(m.group(1)), m.group(2)
            d['bw_kib'] = bw if unit == 'KiB' else bw * 1024 if unit == 'MiB' else bw * 1048576
        # clat avg (usec)
        for line in txt.splitlines():
            if ('clat' in line or 'lat (' in line) and 'avg=' in line:
                m = re.search(r'avg=([0-9.]+)', line)
                if m:
                    d['lat_avg_us'] = float(m.group(1))
                    break
        # p99 latency
        for line in txt.splitlines():
            if '99.00th' in line:
                m = re.search(r'\[\s*([0-9]+)\]', line)
                if m:
                    d['lat_p99_us'] = float(m.group(1))
                    break
    except Exception as e:
        print(f"  warn: {path}: {e}")
    return d

def get_runs(result_dir, pattern):
    """Collect all runs matching pattern, return list of parsed dicts."""
    files = sorted(glob.glob(os.path.join(result_dir, f"*{pattern}*_fio.txt")))
    return [parse_fio(f) for f in files]

def avg_metric(runs, key):
    vals = [r[key] for r in runs if key in r]
    if not vals:
        return None, None
    return mean(vals), stdev(vals) if len(vals) > 1 else 0.0

def fmt(val, std, unit=""):
    if val is None:
        return "N/A"
    if std and std > 0:
        return f"{val:.0f}±{std:.0f}{unit}"
    return f"{val:.0f}{unit}"

def pct_change(stock, patched):
    if stock and patched and stock > 0:
        return (patched - stock) / stock * 100
    return None

def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <stock_dir> <patched_dir>")
        sys.exit(1)

    stock_dir, patched_dir = sys.argv[1], sys.argv[2]

    for d in (stock_dir, patched_dir):
        if not os.path.isdir(d):
            print(f"ERROR: directory not found: {d}")
            sys.exit(1)

    # Print system info side-by-side
    print("=" * 72)
    print("JBD2 Fast Commit Barrier Deferral — Results Comparison")
    print("=" * 72)
    for label, d in [("STOCK", stock_dir), ("PATCHED", patched_dir)]:
        info = os.path.join(d, "system_info.txt")
        if os.path.exists(info):
            for line in open(info):
                if any(k in line for k in ("Kernel:", "CPU:", "Date:")):
                    print(f"  [{label}] {line.rstrip()}")
    print()

    # Benchmark configurations to compare
    configs = [
        ("ordered_syncwrite_j4",    "ordered/randwrite  numjobs=4  (PRIMARY)"),
        ("ordered_syncwrite_j1",    "ordered/randwrite  numjobs=1"),
        ("ordered_syncwrite_j2",    "ordered/randwrite  numjobs=2"),
        ("ordered_syncwrite_j8",    "ordered/randwrite  numjobs=8"),
        ("ordered_seqwrite_j1",     "ordered/seqwrite   numjobs=1  (CONTROL)"),
        ("journal_syncwrite_j4",    "journal/randwrite  numjobs=4"),
        ("writeback_syncwrite_j4",  "writeback/randwrite numjobs=4"),
    ]

    # Header
    print(f"{'Workload':<38}  {'Metric':<12}  {'Stock':>12}  {'Patched':>12}  {'Change':>8}")
    print("-" * 90)

    for pattern, desc in configs:
        stock_runs   = get_runs(stock_dir,   pattern)
        patched_runs = get_runs(patched_dir, pattern)

        if not stock_runs and not patched_runs:
            continue

        metrics = [
            ("IOPS",        'iops',        ""),
            ("BW (KiB/s)",  'bw_kib',      ""),
            ("lat avg (µs)","lat_avg_us",   ""),
            ("lat p99 (µs)","lat_p99_us",  ""),
        ]

        first = True
        for mname, mkey, unit in metrics:
            sv, ss = avg_metric(stock_runs,   mkey)
            pv, ps = avg_metric(patched_runs, mkey)
            chg    = pct_change(sv, pv)

            row_label = desc if first else ""
            first = False

            # Color-code improvement direction
            chg_str = "N/A"
            if chg is not None:
                sign = "+" if chg >= 0 else ""
                chg_str = f"{sign}{chg:.1f}%"

            print(f"  {row_label:<36}  {mname:<12}  {fmt(sv,ss):>12}  {fmt(pv,ps):>12}  {chg_str:>8}")
        print()

    # Summary box
    stock_primary   = get_runs(stock_dir,   "ordered_syncwrite_j4")
    patched_primary = get_runs(patched_dir, "ordered_syncwrite_j4")
    sv, _ = avg_metric(stock_primary,   'lat_avg_us')
    pv, _ = avg_metric(patched_primary, 'lat_avg_us')

    if sv and pv:
        print("=" * 72)
        print("KEY RESULT (ordered/randwrite numjobs=4 — primary optimization target):")
        print(f"  Stock   avg commit latency: {sv:.0f} µs")
        print(f"  Patched avg commit latency: {pv:.0f} µs")
        print(f"  Improvement: {pct_change(sv, pv):.1f}%")
        print("=" * 72)

if __name__ == "__main__":
    main()
