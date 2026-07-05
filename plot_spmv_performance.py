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

# These figures are typically placed at half-textwidth (~3.25in) in the
# thesis. Font sizes here are a moderate increase over matplotlib defaults;
# legibility after the shrink mainly comes from giving the figure enough
# vertical room (see figsize below) and moving the legend out of the way,
# not from inflating fonts past what the canvas can fit without overlap.
TITLE_FONTSIZE = 18
LABEL_FONTSIZE = 16
TICK_FONTSIZE = 14
LEGEND_FONTSIZE = 14
ANNOTATION_FONTSIZE = 12


def parse_log(log_file, metric):
    data = defaultdict(lambda: defaultdict(dict))

    current_format = None
    current_threads = None
    current_size = None
    sparsemv_values = []

    def save_entry():
        if current_format and len(sparsemv_values) >= 3:
            val = sparsemv_values[0] if metric == 'time' else sparsemv_values[2]
            data[current_size][current_format][current_threads] = val

    with open(log_file) as f:
        for line in f:
            line = line.strip()

            m = re.match(r'STARTING: Format=(\w+), Threads=(\d+), Size=(\d+ \d+ \d+)', line)
            if m:
                save_entry()
                current_format = m.group(1)
                current_threads = int(m.group(2))
                current_size = m.group(3)
                sparsemv_values = []
                continue

            m = re.match(r'SPARSEMV:\s+([0-9.e+\-]+)', line)
            if m and current_format is not None:
                sparsemv_values.append(float(m.group(1)))

    save_entry()
    return data


def plot_size(size, fmt_data, metric, out_dir, selected_threads=None):
    all_threads = sorted(set(
        t for fmt in FORMATS for t in fmt_data.get(fmt, {}).keys()
    ))
    if selected_threads:
        threads = [t for t in all_threads if t in selected_threads]
        if not threads:
            print(f'Warning: no data for requested threads in size {size}, skipping.')
            return
    else:
        threads = all_threads

    n_formats = len(FORMATS)
    bar_width = 0.18
    x = np.arange(len(threads))

    fig, ax = plt.subplots(figsize=(max(12, len(threads) * 1.8), 7.5))

    all_bars = []
    for i, fmt in enumerate(FORMATS):
        offsets = x + (i - n_formats / 2 + 0.5) * bar_width
        values = [fmt_data.get(fmt, {}).get(t, 0.0) for t in threads]
        csr_values = [fmt_data.get('csr', {}).get(t, None) for t in threads]
        bars = ax.bar(offsets, values, width=bar_width, label=fmt.upper(),
                      color=FORMAT_COLORS[fmt], edgecolor='white', linewidth=0.5)
        for bar, val, csr_val in zip(bars, values, csr_values):
            all_bars.append((bar, val, fmt, csr_val))

    # expand ylim to make room for annotations
    max_h = max((b.get_height() for b, _, _, _ in all_bars), default=1)
    ax.set_ylim(0, max_h * 1.3)

    for bar, val, fmt, csr_val in all_bars:
        if val == 0:
            continue
        y = bar.get_height() + max_h * 0.01

        if fmt == 'csr':
            if metric == 'time':
                label = f'{val:.3f}s'
            else:
                label = f'{val/1000:.2f}G'
            ax.text(bar.get_x() + bar.get_width() / 2, y, label,
                    ha='center', va='bottom', fontsize=ANNOTATION_FONTSIZE,
                    color='black', fontweight='bold', rotation=90)
        else:
            if csr_val and csr_val != 0:
                if metric == 'time':
                    improvement = (csr_val - val) / csr_val * 100
                else:
                    improvement = (val - csr_val) / csr_val * 100
                color = '#2ca02c' if improvement >= 0 else '#d62728'
                sign = '+' if improvement >= 0 else ''
                ax.text(bar.get_x() + bar.get_width() / 2, y,
                        f'{sign}{improvement:.1f}%',
                        ha='center', va='bottom', fontsize=ANNOTATION_FONTSIZE,
                        color=color, fontweight='bold', rotation=90)

    ax.set_xticks(x)
    ax.set_xticklabels([str(t) for t in threads])
    ax.set_xlabel('Number of OpenMP Threads', fontsize=LABEL_FONTSIZE)
    ax.tick_params(axis='both', labelsize=TICK_FONTSIZE)

    if metric == 'time':
        ax.set_ylabel('Wall-Clock Time (seconds)', fontsize=LABEL_FONTSIZE)
        title_metric = 'Wall-Clock Time'
    else:
        ax.set_ylabel('Performance (MFLOPS)', fontsize=LABEL_FONTSIZE)
        title_metric = 'MFLOPS'

    size_label = 'x'.join(size.split())
    size_short = size.split()[0]
    ax.set_title(f'SpMV {title_metric} — Matrix {size_label}', fontsize=TITLE_FONTSIZE, pad=14)
    ax.legend(loc='upper right', fontsize=LEGEND_FONTSIZE, frameon=True, framealpha=0.85)

    plt.tight_layout()
    filename = os.path.join(out_dir, f'spmv_{metric}_{size_short}.pdf')
    plt.savefig(filename, format='pdf', bbox_inches='tight')
    plt.close()
    print(f'Saved: {filename}')


def main():
    if len(sys.argv) < 3 or sys.argv[2].lower() not in ('time', 'mflops'):
        print('Usage: python3 plot_spmv_performance.py <log_file> <time|mflops> [thread ...]')
        sys.exit(1)

    log_file = sys.argv[1]
    metric = sys.argv[2].lower()
    out_dir = os.path.dirname(os.path.abspath(log_file))

    selected_threads = None
    if len(sys.argv) > 3:
        try:
            selected_threads = set(int(t) for t in sys.argv[3:])
        except ValueError:
            print('Error: thread counts must be integers.')
            sys.exit(1)

    data = parse_log(log_file, metric)

    for size in sorted(data.keys()):
        plot_size(size, data[size], metric, out_dir, selected_threads)


if __name__ == '__main__':
    main()
