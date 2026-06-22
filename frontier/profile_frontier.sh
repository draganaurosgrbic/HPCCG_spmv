#!/bin/bash
#SBATCH -J hpccg_frontier_profile
#SBATCH -o hpccg_frontier_profile.log
#SBATCH -A csc617
#SBATCH -p batch
#SBATCH -N 1
#SBATCH -t 30:00

cd $SLURM_SUBMIT_DIR

module load python/3.10-miniforge3

THREADS=(1 2 3 4 6 8 12 16 24 32)
FORMATS=("csr" "ell8" "ell7" "tiled")
SIZES=("50 50 50" "100 100 100" "150 150 150" "200 200 200" "250 250 250" "300 300 300")

EXEC_PATH="$(cd .. && pwd)/test_HPCCG"
PARSE_SCRIPT="$(pwd)/parse_perf.py"
JOB_ID=${SLURM_JOB_ID:-"pid_$$"}

export OMP_PROC_BIND=spread
export OMP_PLACES=cores

for sz in "${SIZES[@]}"; do
    sz_name=$(echo $sz | tr ' ' '_')
    echo "=========================================================="
    echo "MATRIX SIZE: $sz"
    echo "=========================================================="

    for fmt in "${FORMATS[@]}"; do
        case $fmt in
            "csr")   fmt_mode=1 ;;
            "ell7")  fmt_mode=2 ;;
            "ell8")  fmt_mode=3 ;;
            "tiled") fmt_mode=4 ;;
            *)       fmt_mode=0 ;;
        esac

        for t in "${THREADS[@]}"; do
            export OMP_NUM_THREADS=$t

            PERF_FILE="perf_${fmt}_${sz_name}_t${t}_${JOB_ID}.data"

            echo "STARTING: Format=$fmt, Threads=$t, Size=$sz"

            perf record -o "$PERF_FILE" -g \
                -e cycles,instructions,L1-dcache-load-misses,cache-misses \
                $EXEC_PATH $sz $fmt

            if [ -f "$PERF_FILE" ]; then
                python3 $PARSE_SCRIPT $fmt_mode "$PERF_FILE"
                rm "$PERF_FILE"
            fi

            echo "----------------------------------------------------------"
        done
    done
done
