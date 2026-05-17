import subprocess
import re
import sys
import os

def get_perf_stats(target_prefix, data_file):
    if not os.path.exists(data_file):
        print(f"Error: Data file '{data_file}' not found.")
        return False

    command = ['perf', 'report', '-i', data_file, '--stdio', '--group', '--no-children']

    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True)

        pattern = rf"^\s*([0-9.]+)%\s+([0-9.]+)%\s+([0-9.]+)%\s+([0-9.]+)%.*?({target_prefix}.*)"

        found = False
        for line in result.stdout.splitlines():
            match = re.search(pattern, line)
            if match:
                cycles_pct  = float(match.group(1))
                instr_pct   = float(match.group(2))
                l1_misses   = float(match.group(3))
                llc_misses  = float(match.group(4))
                symbol      = match.group(5).strip()

                print(f"\nResults for: {symbol}")
                print("-" * 50)
                print(f"Cycles:            {cycles_pct:>7.2f}%")
                print(f"Instructions:      {instr_pct:>7.2f}%")
                print(f"L1D Misses:        {l1_misses:>7.2f}%")
                print(f"LLC Misses:        {llc_misses:>7.2f}%")

                found = True
                break

        if not found:
            print(f"Function matching '{target_prefix}' not found in the profile.")

        return found

    except Exception as e:
        print(f"Error during parsing: {e}")
        return False

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: python3 parse_perf.py [mode] [filename]")
        sys.exit(1)

    mode_map = {
        "1": "csr_spmv",
        "2": "ellpack7_spmv",
        "3": "ellpack8_spmv",
        "4": "ellpack7_tiled_spmv"
    }
    target = mode_map.get(sys.argv[1], "csr_spmv")
    get_perf_stats(target, sys.argv[2])
