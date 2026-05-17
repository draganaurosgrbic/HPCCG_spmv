#!/bin/bash
#PBS -N hpccg_polaris
#PBS -o hpccg_polaris.log
#PBS -j oe
#PBS -l select=1
#PBS -l filesystems=home:eagle
#PBS -l walltime=01:00:00
#PBS -A Tools
#PBS -q debug

cd $PBS_O_WORKDIR

THREADS=(1 2 3 4 6 8 12 16 24 32)
FORMATS=("csr" "ell8" "ell7" "tiled")
SIZES=("50 50 50" "100 100 100" "150 150 150" "200 200 200" "250 250 250" "300 300 300")

EXEC_PATH="$(cd .. && pwd)/test_HPCCG"

export OMP_PROC_BIND=spread
export OMP_PLACES=cores

for sz in "${SIZES[@]}"; do
    echo "=========================================================="
    echo "MATRIX SIZE: $sz"
    echo "=========================================================="

    for fmt in "${FORMATS[@]}"; do
        for t in "${THREADS[@]}"; do
            export OMP_NUM_THREADS=$t

            echo "STARTING: Format=$fmt, Threads=$t, Size=$sz"
            $EXEC_PATH $sz $fmt
            echo "----------------------------------------------------------"
        done
    done
done
