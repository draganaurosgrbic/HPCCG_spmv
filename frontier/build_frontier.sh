#!/bin/bash

module load PrgEnv-amd

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

make -C "$REPO_DIR" clean
make -C "$REPO_DIR" \
    CXX=CC \
    LINKER=CC \
    CPP_OPT_FLAGS="-O3 -march=native -mprefer-vector-width=256 -g -save-temps -DWALL" \
    OMP_FLAGS="-fopenmp"
