#!/bin/bash
#PBS -N dump_matrices
#PBS -o dump_matrices.log
#PBS -j oe
#PBS -l select=1
#PBS -l filesystems=home:eagle
#PBS -l walltime=00:30:00
#PBS -A Tools
#PBS -q debug

cd $PBS_O_WORKDIR

DUMP_PATH="$(cd .. && pwd)/dump_matrix"
SIZES=("50 50 50" "100 100 100" "150 150 150" "200 200 200" "250 250 250" "300 300 300")

for sz in "${SIZES[@]}"; do
    sz_name=$(echo $sz | tr ' ' '_')
    echo "Generating matrix_${sz_name}.bin ..."
    $DUMP_PATH $sz "matrix_${sz_name}.bin"
done
