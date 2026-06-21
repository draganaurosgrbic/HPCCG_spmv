// Standalone tool: generates the same 7-point stencil matrix HPCCG uses for
// its CPU benchmarks and dumps it to a binary CSR file, so the GPU test
// harness (spmv.cu) can load and test against the real problem matrix
// instead of only the synthetic banded matrix.
//
// Usage: dump_matrix nx ny nz output_file
//
// File layout (all integers little-endian, matching the host's native order):
//   int64_t nrows
//   int64_t ncols
//   int64_t nnz
//   int64_t row_ptr[nrows + 1]
//   int64_t col_ind[nnz]
//   double  nz[nnz]

#include <cstdio>
#include <cstdlib>
#include <iostream>
#include "generate_matrix.hpp"
#include "HPC_Sparse_Matrix.hpp"

int main(int argc, char **argv) {
  if (argc != 5) {
    std::cerr << "Usage: " << argv[0] << " nx ny nz output_file" << std::endl;
    return 1;
  }

  int nx = atoi(argv[1]);
  int ny = atoi(argv[2]);
  int nz = atoi(argv[3]);
  const char *output_path = argv[4];

  HPC_Sparse_Matrix *A;
  double *x, *b, *xexact;
  generate_matrix(nx, ny, nz, &A, &x, &b, &xexact);

  if (A == NULL || A->csr == NULL) {
    std::cerr << "Error: matrix generation failed." << std::endl;
    return 1;
  }

  FILE *f = fopen(output_path, "wb");
  if (!f) {
    std::cerr << "Error: could not open " << output_path << " for writing." << std::endl;
    return 1;
  }

  int64_t nrows = A->csr->m;
  int64_t ncols = A->csr->n;
  int64_t nnz = A->csr->non_zeros;

  fwrite(&nrows, sizeof(int64_t), 1, f);
  fwrite(&ncols, sizeof(int64_t), 1, f);
  fwrite(&nnz, sizeof(int64_t), 1, f);
  fwrite(A->csr->row_ptr, sizeof(int64_t), nrows + 1, f);
  fwrite(A->csr->col_ind, sizeof(int64_t), nnz, f);
  fwrite(A->csr->nz, sizeof(double), nnz, f);

  fclose(f);

  std::cout << "Wrote " << nrows << "x" << ncols << " matrix with " << nnz
            << " nonzeros (7-point stencil, " << nx << "x" << ny << "x" << nz
            << ") to " << output_path << std::endl;

  return 0;
}
