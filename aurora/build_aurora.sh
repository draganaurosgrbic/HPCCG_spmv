#!/bin/bash

module load oneapi

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

make -C "$REPO_DIR" clean
make -C "$REPO_DIR" \
    CXX=icpx \
    LINKER=icpx \
    CPP_OPT_FLAGS="-O3 -march=native -mprefer-vector-width=512 -g -save-temps -DWALL" \
    OMP_FLAGS="-qopenmp"
