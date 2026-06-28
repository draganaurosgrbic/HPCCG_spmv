#!/usr/bin/env python3
# Plots SpMV cache-miss percentages vs matrix size for a fixed thread count.
# Produces two PDFs (L1D misses and LLC misses) from a log produced by
# profile_cache_frontier.sh.
# Usage: python3 plot_cache_misses.py <log_file>

import sys
import re
import os
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from collections import defaultdict

TITLE_FONTSIZE = 18
LABEL_FONTSIZE = 16
TICK_FONTSIZE = 14
LEGEND_FONTSIZE = 14
ANNOTATION_FONTSIZE = 12

FORMATS = ['csr', 'ell8', 'ell7', 'tiled']
FORMAT_COLORS = {
    'csr':   '#4C72B0',
    'ell8':  '#DD8452',
    'ell7':  '#55A868',
    'tiled': '#C44E52',
}

METRIC_PATTERN = {
    'l1d': r'L1D Misses:\s+([0-9.]+)%',
    'llc': r'LLC Misses:\s+([0-9.]+)%',
}
METRIC_LABEL = {
    'l1d': 'L1D Cache Misses (%)',
    'llc': 'LLC Cache Misses (%)',
}
METRIC_TITLE = {
    'l1d': 'L1D Cache Misses',
    'llc': 'LLC Cache Misses',
}


def parse_log(log_file):
    # Returns: data[threads][format][size_short] = {'l1d': pct, 'llc': pct}
    data = defaultdict(lambda: defaultdict(lambda: defaultdict(dict)))
    current_format = None
    current_threads = None
    current_size_short = None
    current_metrics = {}

    with open(log_file) as f:
        for line in f:
            line = line.strip()

            m = re.match(r'STARTING: Format=(\w+), Threads=(\d+), Size=(\d+) \d+ \d+', line)
            if m:
                if current_format is not None and current_metrics:
                    data[current_threads][current_format][current_size_short] = dict(current_metrics)
                current_format = m.group(1)
                current_threads = int(m.group(2))
                current_size_short = m.group(3)
                current_metrics = {}
                continue

            m = re.match(r'L1D Misses:\s+([0-9.]+)%', line)
            if m and current_format is not None:
                current_metrics['l1d'] = float(m.group(1))

            m = re.match(r'LLC Misses:\s+([0-9.]+)%', line)
            if m and current_format is not None:
                current_metrics['llc'] = float(m.group(1))

    if current_format is not None and current_metrics:
        data[current_threads][current_format][current_size_short] = dict(current_metrics)

    return data


def plot_metric(threads, fmt_data, metric, out_dir):
    sizes = sorted(set(
        s for fmt in FORMATS for s in fmt_data.get(fmt, {}).keys()
    ), key=int)
    if not sizes:
        return

    n_formats = len(FORMATS)
    bar_width = 0.18
    x = np.arange(len(sizes))

    fig, ax = plt.subplots(figsize=(max(12, len(sizes) * 1.8), 7.5))

    all_bars = []
    for i, fmt in enumerate(FORMATS):
        offsets = x + (i - n_formats / 2 + 0.5) * bar_width
        values = [fmt_data.get(fmt, {}).get(s, {}).get(metric, 0.0) for s in sizes]
        bars = ax.bar(offsets, values, width=bar_width, label=fmt.upper(),
                      color=FORMAT_COLORS[fmt], edgecolor='white', linewidth=0.5)
        for bar, val in zip(bars, values):
            all_bars.append((bar, val))

    max_h = max((b.get_height() for b, _ in all_bars), default=1)
    ax.set_ylim(0, max_h * 1.3)

    for bar, val in all_bars:
        if val == 0:
            continue
        ax.text(bar.get_x() + bar.get_width() / 2,
                bar.get_height() + max_h * 0.01,
                f'{val:.1f}%',
                ha='center', va='bottom', fontsize=ANNOTATION_FONTSIZE,
                color='black', fontweight='bold', rotation=90)

    size_labels = [f'{s}³' for s in sizes]
    ax.set_xticks(x)
    ax.set_xticklabels(size_labels)
    ax.tick_params(axis='both', labelsize=TICK_FONTSIZE)
    ax.set_xlabel('Matrix Size (n³)', fontsize=LABEL_FONTSIZE)
    ax.set_ylabel(METRIC_LABEL[metric], fontsize=LABEL_FONTSIZE)
    ax.set_title(f'SpMV {METRIC_TITLE[metric]} — {threads} Threads', fontsize=TITLE_FONTSIZE)
    ax.legend(loc='upper center', bbox_to_anchor=(0.5, -0.18),
              ncol=n_formats, fontsize=LEGEND_FONTSIZE, frameon=False)

    plt.tight_layout()
    filename = os.path.join(out_dir, f'spmv_{metric}_t{threads}.pdf')
    plt.savefig(filename, format='pdf', bbox_inches='tight')
    plt.close()
    print(f'Saved: {filename}')


def main():
    if len(sys.argv) != 2:
        print('Usage: python3 plot_cache_misses.py <log_file>')
        sys.exit(1)

    log_file = sys.argv[1]
    out_dir = os.path.dirname(os.path.abspath(log_file))

    data = parse_log(log_file)
    if not data:
        print('No cache-miss data found in log.')
        sys.exit(1)

    for threads in sorted(data.keys()):
        for metric in ('l1d', 'llc'):
            plot_metric(threads, data[threads], metric, out_dir)


if __name__ == '__main__':
    main()
