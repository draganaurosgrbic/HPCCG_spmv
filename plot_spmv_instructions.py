#!/usr/bin/env python3

import sys
import re
import os
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from collections import defaultdict

FORMATS = ['csr', 'ell8', 'ell7', 'tiled']
FORMAT_COLORS = {
    'csr':   '#4C72B0',
    'ell8':  '#DD8452',
    'ell7':  '#55A868',
    'tiled': '#C44E52',
}


def parse_log(log_file):
    data = defaultdict(lambda: defaultdict(dict))

    current_format = None
    current_threads = None
    current_size = None

    with open(log_file) as f:
        for line in f:
            line = line.strip()

            m = re.match(r'STARTING: Format=(\w+), Threads=(\d+), Size=(\d+ \d+ \d+)', line)
            if m:
                current_format = m.group(1)
                current_threads = int(m.group(2))
                current_size = m.group(3)
                continue

            m = re.match(r'Instructions:\s+([0-9.]+)%', line)
            if m and current_format is not None:
                data[current_size][current_format][current_threads] = float(m.group(1))

    return data


def plot_size(size, fmt_data, out_dir):
    threads = sorted(set(
        t for fmt in FORMATS for t in fmt_data.get(fmt, {}).keys()
    ))

    n_formats = len(FORMATS)
    bar_width = 0.18
    x = np.arange(len(threads))

    fig, ax = plt.subplots(figsize=(max(12, len(threads) * 1.8), 6))

    all_bars = []
    for i, fmt in enumerate(FORMATS):
        offsets = x + (i - n_formats / 2 + 0.5) * bar_width
        values = [fmt_data.get(fmt, {}).get(t, 0.0) for t in threads]
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
                ha='center', va='bottom', fontsize=7,
                color='black', fontweight='bold', rotation=90)

    ax.set_xticks(x)
    ax.set_xticklabels([str(t) for t in threads])
    ax.set_xlabel('Number of OpenMP Threads')
    ax.set_ylabel('Instructions (%)')

    size_label = 'x'.join(size.split())
    size_short = size.split()[0]
    ax.set_title(f'SpMV Instructions — Matrix {size_label}')
    ax.legend(loc='upper right')
    ax.set_ylim(bottom=0)

    plt.tight_layout()
    filename = os.path.join(out_dir, f'spmv_instructions_{size_short}.pdf')
    plt.savefig(filename, format='pdf')
    plt.close()
    print(f'Saved: {filename}')


def main():
    if len(sys.argv) != 2:
        print('Usage: python3 plot_spmv_instructions.py <log_file>')
        sys.exit(1)

    log_file = sys.argv[1]
    out_dir = os.path.dirname(os.path.abspath(log_file))

    data = parse_log(log_file)

    for size in sorted(data.keys()):
        plot_size(size, data[size], out_dir)


if __name__ == '__main__':
    main()
