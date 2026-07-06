#!/usr/bin/env python3
# Plots GPU SpMV wall-clock time on Polaris (NVIDIA A100).
# X-axis: matrix size (n^3). Bars: cuSPARSE, CSR, ELLPACK-8, TransposedELLPACK.
# Annotation: actual time on cuSPARSE bars; speedup vs cuSPARSE on all others
#             (green = faster than cuSPARSE, red = slower).
# Usage: python3 plot_gpu_performance.py <gpu.txt>

import sys
import os
import csv
import math
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

FORMATS = ['cusparse', 'csr', 'ell8', 'ell7']
FORMAT_LABELS = {
    'cusparse': 'cuSPARSE',
    'csr':      'CSR',
    'ell8':     'ELLPACK',
    'ell7':     'Transposed ELLPACK',
}
FORMAT_COLORS = {
    'cusparse': '#8C8C8C',
    'csr':      '#4C72B0',
    'ell8':     '#DD8452',
    'ell7':     '#55A868',
}

TITLE_FONTSIZE      = 18
LABEL_FONTSIZE      = 16
TICK_FONTSIZE       = 14
LEGEND_FONTSIZE     = 14
ANNOTATION_FONTSIZE = 12


def parse(filepath):
    rows = []
    with open(filepath) as f:
        reader = csv.DictReader(f)
        for row in reader:
            n = int(row['N'])
            side = round(n ** (1 / 3))
            rows.append({
                'n':        side,
                'cusparse': float(row['cusparse']),
                'csr':      float(row['csr']),
                'ell8':     float(row['ell8']),
                'ell7':     float(row['ell7']),
            })
    return sorted(rows, key=lambda r: r['n'])


def plot(rows, out_dir):
    sizes = [r['n'] for r in rows]
    x = np.arange(len(sizes))
    n_formats = len(FORMATS)
    bar_width = 0.18

    fig, ax = plt.subplots(figsize=(max(12, len(sizes) * 2.2), 7.5))

    # Draw bars
    all_bars = []
    for i, fmt in enumerate(FORMATS):
        offsets = x + (i - n_formats / 2 + 0.5) * bar_width
        values = [r[fmt] for r in rows]
        bars = ax.bar(offsets, values, width=bar_width,
                      label=FORMAT_LABELS[fmt],
                      color=FORMAT_COLORS[fmt],
                      edgecolor='white', linewidth=0.5)
        for bar, val, row in zip(bars, values, rows):
            all_bars.append((bar, val, fmt, row['cusparse']))

    max_h = max(b.get_height() for b, _, _, _ in all_bars)
    ax.set_ylim(0, max_h * 1.30)

    # Annotate bars
    for bar, val, fmt, cusparse_val in all_bars:
        y = bar.get_height() + max_h * 0.01
        if fmt == 'cusparse':
            ax.text(bar.get_x() + bar.get_width() / 2, y,
                    f'{val:.3f}',
                    ha='center', va='bottom', fontsize=ANNOTATION_FONTSIZE,
                    color='black', fontweight='bold', rotation=90)
        else:
            pct = (cusparse_val - val) / cusparse_val * 100
            sign = '+' if pct >= 0 else ''
            color = '#2ca02c' if pct >= 0 else '#d62728'
            ax.text(bar.get_x() + bar.get_width() / 2, y,
                    f'{sign}{pct:.1f}%',
                    ha='center', va='bottom', fontsize=ANNOTATION_FONTSIZE,
                    color=color, fontweight='bold', rotation=90)

    ax.set_xticks(x)
    ax.set_xticklabels([f'${n}^3$' for n in sizes])
    ax.set_xlabel('Matrix Size', fontsize=LABEL_FONTSIZE)
    ax.set_ylabel('Wall-Clock Time (ms)', fontsize=LABEL_FONTSIZE)
    ax.tick_params(axis='both', labelsize=TICK_FONTSIZE)
    ax.set_title('GPU SpMV Performance — Polaris (NVIDIA A100)',
                 fontsize=TITLE_FONTSIZE, pad=14)
    ax.legend(loc='upper left', fontsize=LEGEND_FONTSIZE,
              frameon=True, framealpha=0.85)

    plt.tight_layout()
    out = os.path.join(out_dir, 'gpu_spmv_performance.pdf')
    plt.savefig(out, format='pdf', bbox_inches='tight')
    plt.close()
    print(f'Saved: {out}')


def main():
    if len(sys.argv) < 2:
        print('Usage: python3 plot_gpu_performance.py <gpu.txt> [n ...]')
        sys.exit(1)
    filepath = sys.argv[1]
    out_dir = os.path.dirname(os.path.abspath(filepath))

    selected = None
    if len(sys.argv) > 2:
        try:
            selected = {int(s) for s in sys.argv[2:]}
        except ValueError:
            print('Error: matrix sizes must be integers.')
            sys.exit(1)

    rows = parse(filepath)
    if selected is not None:
        rows = [r for r in rows if r['n'] in selected]
        if not rows:
            print(f'Warning: no data found for sizes {sorted(selected)}.')
            sys.exit(1)

    plot(rows, out_dir)


if __name__ == '__main__':
    main()
