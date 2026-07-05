#!/usr/bin/env python3
# Generates LaTeX tables of L1D and LLC cache miss rates for each SpMV format
# and matrix size, with relative change vs CSR (negative = fewer misses).
# Produces one .tex file per (thread count, metric) pair.
# Usage: python3 generate_table_cache_misses.py <log_file>

import sys
import re
import os
from collections import defaultdict

FORMATS = ['csr', 'ell8', 'ell7', 'tiled']
FORMAT_LABELS = {
    'csr':  'CSR',
    'ell8': 'ELLPACK-8',
    'ell7': 'TransposedELLPACK',
    'tiled': 'TILED',
}
METRIC_LABELS = {
    'l1d': 'L1D',
    'llc': 'LLC',
}


def parse_log(log_file):
    # data[threads][format][size_short] = {'l1d': pct, 'llc': pct}
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


def rel_str(val, csr_val):
    """Relative change vs CSR as a LaTeX string, e.g. $+100.0\%$ or $-10.0\%$."""
    if csr_val is None or csr_val == 0:
        return '---'
    rel = (val - csr_val) / csr_val * 100
    sign = '+' if rel >= 0 else ''
    return f'${sign}{rel:.1f}\\%$'


def generate_table(threads, fmt_data, metric, sizes):
    """
    Layout: sizes as rows, formats as columns.
      Columns: Size | CSR | ELL8 Miss% | ELL8 Δ | ELL7 Miss% | ELL7 Δ | TILED Miss% | TILED Δ
    """
    mlabel = METRIC_LABELS[metric]
    non_csr = [f for f in FORMATS if f != 'csr']

    # 1 (size) + 1 (CSR) + 2*3 (ELL8/ELL7/TILED miss%+delta) = 8 columns
    col_spec = '@{}l r | rr rr rr @{}'

    lines = []
    lines.append(r'\begin{table}[!ht]')
    lines.append(r'\centering')
    lines.append(
        f'\\caption{{{mlabel} cache miss rates (\\%) per SpMV format and matrix size '
        f'({threads}~OpenMP thread{"s" if threads != 1 else ""}). '
        f'The $\\Delta$\\,CSR column shows the relative change in miss rate '
        f'vs.\\ CSR (negative values indicate fewer cache misses).}}'
    )
    lines.append(f'\\label{{tab:cache-{metric}-t{threads}}}')
    lines.append(r'\resizebox{\textwidth}{!}{%')
    lines.append(r'\small')
    lines.append(f'\\begin{{tabular}}{{{col_spec}}}')
    lines.append(r'\toprule')

    # --- Header row 1: format group labels ---
    # Columns: Size | CSR | \mc{2}{ELL8} | \mc{2}{ELL7} | \mc{2}{TILED}
    hdr1 = (
        r'\textbf{Size}'
        r' & \textbf{CSR}'
    )
    for fmt in non_csr:
        hdr1 += f' & \\multicolumn{{2}}{{c}}{{\\textbf{{{FORMAT_LABELS[fmt]}}}}}'
    hdr1 += r' \\'
    lines.append(hdr1)

    # cmidrule under each non-CSR pair: CSR is col 2; pairs start at col 3
    cmidrules = ''
    for i, _ in enumerate(non_csr):
        lo = 3 + 2 * i
        hi = lo + 1
        cmidrules += f'\\cmidrule(lr){{{lo}-{hi}}}'
    lines.append(cmidrules)

    # --- Header row 2: Miss% / Δ CSR sub-headers ---
    hdr2 = r' & '  # Size cell empty, CSR already labelled above
    hdr2 += f'\\textbf{{Miss\\%}}'
    for _ in non_csr:
        hdr2 += r' & \textbf{Miss\%} & \textbf{$\Delta$\,CSR}'
    hdr2 += r' \\'
    lines.append(hdr2)
    lines.append(r'\midrule')

    # --- Data rows: one per matrix size ---
    for s in sizes:
        csr_val = fmt_data.get('csr', {}).get(s, {}).get(metric)

        if csr_val is not None:
            csr_cell = f'${csr_val:.1f}\\%$'
        else:
            csr_cell = '---'

        row = f'${s}^3$'
        row += f' & {csr_cell}'

        for fmt in non_csr:
            val = fmt_data.get(fmt, {}).get(s, {}).get(metric)
            if val is None:
                row += ' & --- & ---'
            else:
                row += f' & ${val:.1f}\\%$ & {rel_str(val, csr_val)}'

        row += r' \\'
        lines.append(row)

    lines.append(r'\bottomrule')
    lines.append(r'\end{tabular}%')
    lines.append(r'}')
    lines.append(r'\end{table}')

    return '\n'.join(lines)


def main():
    if len(sys.argv) != 2:
        print('Usage: python3 generate_table_cache_misses.py <log_file>')
        sys.exit(1)

    log_file = sys.argv[1]
    out_dir = os.path.dirname(os.path.abspath(log_file))

    data = parse_log(log_file)
    if not data:
        print('No cache-miss data found in log.')
        sys.exit(1)

    for threads in sorted(data.keys()):
        fmt_data = data[threads]
        sizes = sorted(
            {s for fmt in FORMATS for s in fmt_data.get(fmt, {})},
            key=int,
        )
        if not sizes:
            continue

        for metric in ('l1d', 'llc'):
            table = generate_table(threads, fmt_data, metric, sizes)
            out_path = os.path.join(out_dir, f'table_cache_{metric}_t{threads}.tex')
            with open(out_path, 'w') as f:
                f.write(table)
                f.write('\n')
            print(f'Saved: {out_path}')


if __name__ == '__main__':
    main()
