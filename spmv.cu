#include <cuda_runtime.h>
#include <cusparse.h>
#include <cublas_v2.h>
#include <vector>
#include <numeric>
#include <cmath>
#include <algorithm>
#include <map>
#include <iostream>
#include <stdio.h>

const int PADDING_VALUE = 0;

#define CHECK_CUDA(call) \
    do { \
        cudaError_t err = (call); \
        if (err != cudaSuccess) { \
            fprintf(stderr, "CUDA error at %s:%d: %s\n", __FILE__, __LINE__, cudaGetErrorString(err)); \
            exit(1); \
        } \
    } while (0)

#define CHECK_CUSPARSE(call) \
    do { \
        cusparseStatus_t err = (call); \
        if (err != CUSPARSE_STATUS_SUCCESS) { \
            fprintf(stderr, "cuSPARSE error at %s:%d: %d\n", __FILE__, __LINE__, err); \
            exit(1); \
        } \
    } while (0)

struct Vector {
    size_t length;
    double* vals;
};

struct Csr {
    int64_t nrows;
    int64_t ncols;
    int64_t nnz;
    int* col_ind;
    int* row_ptr;
    double* nz;
};

struct Ellpack8 {
    size_t nrows;
    size_t ncols;
    size_t max_row_nnz;
    int* col_ind;
    double* nz;
};

struct Ellpack7 {
    size_t nrows;
    size_t ncols;
    size_t nrows_padded;
    int* col_ind[7];
    double* nz[7];
};

// Loads a matrix dumped by dump_matrix (binary CSR: nrows, ncols, nnz header
// followed by row_ptr/col_ind/nz arrays) and expands it into the same
// (row, col, nz) triplet form banded_matrix_fill produces, so none of the
// host_fill functions below need to know where the matrix came from.
void load_csr_matrix(const char* path, std::vector<size_t>& row, std::vector<size_t>& col, std::vector<double>& nz, size_t& nrows, size_t& ncols) {
    FILE* f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "Error: could not open matrix file %s\n", path);
        exit(1);
    }

    int64_t file_nrows, file_ncols, file_nnz;
    fread(&file_nrows, sizeof(int64_t), 1, f);
    fread(&file_ncols, sizeof(int64_t), 1, f);
    fread(&file_nnz, sizeof(int64_t), 1, f);

    std::vector<int64_t> row_ptr(file_nrows + 1);
    std::vector<int64_t> col_ind(file_nnz);
    std::vector<double> values(file_nnz);

    fread(row_ptr.data(), sizeof(int64_t), file_nrows + 1, f);
    fread(col_ind.data(), sizeof(int64_t), file_nnz, f);
    fread(values.data(), sizeof(double), file_nnz, f);
    fclose(f);

    nrows = static_cast<size_t>(file_nrows);
    ncols = static_cast<size_t>(file_ncols);

    row.resize(file_nnz);
    col.resize(file_nnz);
    nz.resize(file_nnz);
    for (int64_t r = 0; r < file_nrows; ++r) {
        for (int64_t j = row_ptr[r]; j < row_ptr[r + 1]; ++j) {
            row[j] = static_cast<size_t>(r);
            col[j] = static_cast<size_t>(col_ind[j]);
            nz[j] = values[j];
        }
    }
}

void banded_matrix_fill(size_t nrows, size_t ncols, std::vector<size_t>& row, std::vector<size_t>& col, std::vector<double>& nz) {
    row.reserve(8 * nrows);
    col.reserve(8 * nrows);
    nz.reserve(8 * nrows);

    for (size_t i = 0; i < nrows; ++i) {
        for (size_t j = i; j < i + 7 && j < ncols; ++j) {
            row.push_back(i);
            col.push_back(j);
            nz.push_back(static_cast<double>(rand()) / RAND_MAX);
        }
    }
}

void csr_host_fill(const std::vector<size_t>& row_in, const std::vector<size_t>& col_in, const std::vector<double>& nz_in, int64_t nrows, int64_t ncols, Csr& host_csr) {
    host_csr.nrows = nrows;
    host_csr.ncols = ncols;
    host_csr.nnz = nz_in.size();

    host_csr.col_ind = new int[host_csr.nnz];
    host_csr.nz = new double[host_csr.nnz];
    host_csr.row_ptr = new int[host_csr.nrows + 1];

    for (size_t i = 0; i < host_csr.nnz; ++i) {
        host_csr.nz[i] = nz_in[i];
        host_csr.col_ind[i] = static_cast<int>(col_in[i]);
    }

    std::fill(host_csr.row_ptr, host_csr.row_ptr + host_csr.nrows + 1, 0);
    for (size_t i = 0; i < host_csr.nnz; ++i) {
        host_csr.row_ptr[row_in[i] + 1]++;
    }
    for (int64_t i = 0; i < host_csr.nrows; ++i) {
        host_csr.row_ptr[i + 1] += host_csr.row_ptr[i];
    }
}

void ellpack8_host_fill(const std::vector<size_t>& row_in, const std::vector<size_t>& col_in, const std::vector<double>& nz_in, size_t nrows, size_t ncols, Ellpack8& host_ell) {
    host_ell.nrows = nrows;
    host_ell.ncols = ncols;
    host_ell.max_row_nnz = 8;

    size_t total_ell_elements = host_ell.nrows * host_ell.max_row_nnz;
    host_ell.nz = new double[total_ell_elements];
    host_ell.col_ind = new int[total_ell_elements];

    std::fill(host_ell.col_ind, host_ell.col_ind + total_ell_elements, PADDING_VALUE);
    std::fill(host_ell.nz, host_ell.nz + total_ell_elements, 0.0);

    std::vector<int> row_counts(nrows, 0);
    for (size_t i = 0; i < nz_in.size(); ++i) {
        size_t r = row_in[i];
        size_t c_idx = row_counts[r]++;
        size_t ell_idx = r * host_ell.max_row_nnz + c_idx;
        host_ell.nz[ell_idx] = nz_in[i];
        host_ell.col_ind[ell_idx] = col_in[i];
    }
}

void ellpack7_host_fill(const std::vector<size_t>& row_in, const std::vector<size_t>& col_in, const std::vector<double>& nz_in, size_t nrows, size_t ncols, Ellpack7& host_ell) {
    host_ell.nrows = nrows;
    host_ell.ncols = ncols;
    host_ell.nrows_padded = (nrows + 7) / 8 * 8;

    for (int i = 0; i < 7; ++i) {
        host_ell.nz[i] = new double[host_ell.nrows_padded];
        host_ell.col_ind[i] = new int[host_ell.nrows_padded];
        std::fill(host_ell.nz[i], host_ell.nz[i] + host_ell.nrows_padded, 0.0);
        std::fill(host_ell.col_ind[i], host_ell.col_ind[i] + host_ell.nrows_padded, PADDING_VALUE);
    }

    std::vector<int> row_counts(nrows, 0);
    for (size_t i = 0; i < nz_in.size(); ++i) {
        size_t r = row_in[i];
        size_t c_idx = row_counts[r]++;
        if (c_idx < 7) {
            host_ell.nz[c_idx][r] = nz_in[i];
            host_ell.col_ind[c_idx][r] = col_in[i];
        }
    }
}

__global__ void csr_spmv_kernel(const Csr* __restrict__ A, const double* __restrict__ x, double* __restrict__ y) {
    size_t row = blockIdx.x * blockDim.x + threadIdx.x;

    if (row < A->nrows) {
        const int* __restrict__ row_ptr = A->row_ptr;
        const int* __restrict__ col_ind = A->col_ind;
        const double* __restrict__ nz = A->nz;

        double sum = 0.0;
        for (size_t i = row_ptr[row]; i < row_ptr[row + 1]; ++i) {
            sum += nz[i] * x[col_ind[i]];
        }
        y[row] = sum;
    }
}

__global__ void ellpack8_spmv_kernel(const Ellpack8* __restrict__ A, const double* __restrict__ x, double* __restrict__ y) {
    size_t row = blockIdx.x * blockDim.x + threadIdx.x;

    if (row < A->nrows) {
        const int* __restrict__ col_ind = A->col_ind;
        const double* __restrict__ nz = A->nz;
        size_t base = row * 8;

        double sum = nz[base + 0] * x[col_ind[base + 0]] +
                     nz[base + 1] * x[col_ind[base + 1]] +
                     nz[base + 2] * x[col_ind[base + 2]] +
                     nz[base + 3] * x[col_ind[base + 3]] +
                     nz[base + 4] * x[col_ind[base + 4]] +
                     nz[base + 5] * x[col_ind[base + 5]] +
                     nz[base + 6] * x[col_ind[base + 6]] +
                     nz[base + 7] * x[col_ind[base + 7]];
        y[row] = sum;
    }
}

__global__ void ellpack7_spmv_kernel(const Ellpack7* __restrict__ A, const double* __restrict__ x, double* __restrict__ y) {
    size_t row = blockIdx.x * blockDim.x + threadIdx.x;

    if (row < A->nrows) {
        double sum = 0.0;
        #pragma unroll 7
        for (size_t i = 0; i < 7; ++i) {
            const double* __restrict__ nz_i = A->nz[i];
            const int* __restrict__ col_ind_i = A->col_ind[i];
            sum += nz_i[row] * x[col_ind_i[row]];
        }
        y[row] = sum;
    }
}

void check_correctness(const char* name, size_t N, const double* d_y_ref, const double* d_y_test) {
    std::vector<double> h_ref(N), h_test(N);
    CHECK_CUDA(cudaMemcpy(h_ref.data(), d_y_ref, N * sizeof(double), cudaMemcpyDeviceToHost));
    CHECK_CUDA(cudaMemcpy(h_test.data(), d_y_test, N * sizeof(double), cudaMemcpyDeviceToHost));

    double max_abs_diff = 0.0;
    for (size_t i = 0; i < N; ++i) {
        max_abs_diff = std::max(max_abs_diff, std::fabs(h_ref[i] - h_test[i]));
    }
    if (max_abs_diff > 1e-9) {
        fprintf(stderr, "WARNING: %s result mismatch vs cuSPARSE at N=%zu (max abs diff = %.3e)\n", name, N, max_abs_diff);
    }
}

// Runs `launch` a few times untimed (to avoid measuring first-call/JIT
// overhead), then several more times under a single pair of CUDA events,
// returning the average elapsed time per call in milliseconds.
template <typename F>
float time_kernel(F&& launch, int warmup_iters = 3, int timed_iters = 10) {
    for (int i = 0; i < warmup_iters; ++i) launch();
    CHECK_CUDA(cudaGetLastError());
    CHECK_CUDA(cudaDeviceSynchronize());

    cudaEvent_t start, stop;
    CHECK_CUDA(cudaEventCreate(&start));
    CHECK_CUDA(cudaEventCreate(&stop));

    CHECK_CUDA(cudaEventRecord(start, 0));
    for (int i = 0; i < timed_iters; ++i) launch();
    CHECK_CUDA(cudaEventRecord(stop, 0));
    CHECK_CUDA(cudaEventSynchronize(stop));
    CHECK_CUDA(cudaGetLastError());

    float ms = 0.0f;
    CHECK_CUDA(cudaEventElapsedTime(&ms, start, stop));
    CHECK_CUDA(cudaEventDestroy(start));
    CHECK_CUDA(cudaEventDestroy(stop));
    return ms / timed_iters;
}

void run_test(size_t N, const char* matrix_file = nullptr) {
    std::vector<size_t> h_row_vec, h_col_vec;
    std::vector<double> h_nz_vec;

    if (matrix_file != nullptr) {
        size_t file_ncols;
        load_csr_matrix(matrix_file, h_row_vec, h_col_vec, h_nz_vec, N, file_ncols);
    } else {
        banded_matrix_fill(N, N, h_row_vec, h_col_vec, h_nz_vec);
    }

    const size_t block_size = 256;
    const size_t grid_size = (N + block_size - 1) / block_size;

    int64_t nnz = h_nz_vec.size();

    Csr h_csr;
    csr_host_fill(h_row_vec, h_col_vec, h_nz_vec, N, N, h_csr);
    Ellpack8 h_ell8;
    ellpack8_host_fill(h_row_vec, h_col_vec, h_nz_vec, N, N, h_ell8);
    Ellpack7 h_ell7;
    ellpack7_host_fill(h_row_vec, h_col_vec, h_nz_vec, N, N, h_ell7);

    Vector h_x;
    h_x.length = N;
    h_x.vals = new double[N];
    for (size_t i = 0; i < N; ++i) h_x.vals[i] = static_cast<double>(rand()) / RAND_MAX;

    Csr *d_csr;
    CHECK_CUDA(cudaMalloc(&d_csr, sizeof(Csr)));
    int *d_csr_col_ind, *d_csr_row_ptr;
    double *d_csr_nz;
    CHECK_CUDA(cudaMalloc(&d_csr_col_ind, nnz * sizeof(int)));
    CHECK_CUDA(cudaMalloc(&d_csr_row_ptr, (N + 1) * sizeof(int)));
    CHECK_CUDA(cudaMalloc(&d_csr_nz, nnz * sizeof(double)));

    Ellpack8 *d_ell8;
    CHECK_CUDA(cudaMalloc(&d_ell8, sizeof(Ellpack8)));
    size_t ell8_nnz_padded = h_ell8.nrows * h_ell8.max_row_nnz;
    int *d_ell8_col_ind;
    double *d_ell8_nz;
    CHECK_CUDA(cudaMalloc(&d_ell8_col_ind, ell8_nnz_padded * sizeof(int)));
    CHECK_CUDA(cudaMalloc(&d_ell8_nz, ell8_nnz_padded * sizeof(double)));

    Ellpack7 *d_ell7;
    CHECK_CUDA(cudaMalloc(&d_ell7, sizeof(Ellpack7)));
    int *d_ell7_col_ind[7];
    double *d_ell7_nz[7];
    for (int i = 0; i < 7; ++i) {
        CHECK_CUDA(cudaMalloc(&d_ell7_col_ind[i], h_ell7.nrows_padded * sizeof(int)));
        CHECK_CUDA(cudaMalloc(&d_ell7_nz[i], h_ell7.nrows_padded * sizeof(double)));
    }

    double *d_x, *d_y_csr, *d_y_ell8, *d_y_ell7, *d_y_cusparse;
    CHECK_CUDA(cudaMalloc(&d_x, N * sizeof(double)));
    CHECK_CUDA(cudaMalloc(&d_y_csr, N * sizeof(double)));
    CHECK_CUDA(cudaMalloc(&d_y_ell8, N * sizeof(double)));
    CHECK_CUDA(cudaMalloc(&d_y_ell7, N * sizeof(double)));
    CHECK_CUDA(cudaMalloc(&d_y_cusparse, N * sizeof(double)));
    CHECK_CUDA(cudaMemcpy(d_csr_col_ind, h_csr.col_ind, nnz * sizeof(int), cudaMemcpyHostToDevice));
    CHECK_CUDA(cudaMemcpy(d_csr_row_ptr, h_csr.row_ptr, (N + 1) * sizeof(int), cudaMemcpyHostToDevice));
    CHECK_CUDA(cudaMemcpy(d_csr_nz, h_csr.nz, nnz * sizeof(double), cudaMemcpyHostToDevice));

    Csr h_d_csr;
    h_d_csr.nrows = h_csr.nrows;
    h_d_csr.ncols = h_csr.ncols;
    h_d_csr.nnz = h_csr.nnz;
    h_d_csr.col_ind = d_csr_col_ind;
    h_d_csr.row_ptr = d_csr_row_ptr;
    h_d_csr.nz = d_csr_nz;
    CHECK_CUDA(cudaMemcpy(d_csr, &h_d_csr, sizeof(Csr), cudaMemcpyHostToDevice));

    CHECK_CUDA(cudaMemcpy(d_ell8_col_ind, h_ell8.col_ind, ell8_nnz_padded * sizeof(int), cudaMemcpyHostToDevice));
    CHECK_CUDA(cudaMemcpy(d_ell8_nz, h_ell8.nz, ell8_nnz_padded * sizeof(double), cudaMemcpyHostToDevice));
    Ellpack8 h_d_ell8;
    h_d_ell8.nrows = h_ell8.nrows;
    h_d_ell8.ncols = h_ell8.ncols;
    h_d_ell8.max_row_nnz = h_ell8.max_row_nnz;
    h_d_ell8.col_ind = d_ell8_col_ind;
    h_d_ell8.nz = d_ell8_nz;
    CHECK_CUDA(cudaMemcpy(d_ell8, &h_d_ell8, sizeof(Ellpack8), cudaMemcpyHostToDevice));

    Ellpack7 h_d_ell7;
    h_d_ell7.nrows = h_ell7.nrows;
    h_d_ell7.ncols = h_ell7.ncols;
    h_d_ell7.nrows_padded = h_ell7.nrows_padded;
    for (int i = 0; i < 7; ++i) {
        CHECK_CUDA(cudaMemcpy(d_ell7_col_ind[i], h_ell7.col_ind[i], h_ell7.nrows_padded * sizeof(int), cudaMemcpyHostToDevice));
        CHECK_CUDA(cudaMemcpy(d_ell7_nz[i], h_ell7.nz[i], h_ell7.nrows_padded * sizeof(double), cudaMemcpyHostToDevice));
        h_d_ell7.col_ind[i] = d_ell7_col_ind[i];
        h_d_ell7.nz[i] = d_ell7_nz[i];
    }
    CHECK_CUDA(cudaMemcpy(d_ell7, &h_d_ell7, sizeof(Ellpack7), cudaMemcpyHostToDevice));
    CHECK_CUDA(cudaMemcpy(d_x, h_x.vals, N * sizeof(double), cudaMemcpyHostToDevice));

    float time_csr = time_kernel([&]() {
        csr_spmv_kernel<<<grid_size, block_size>>>(d_csr, d_x, d_y_csr);
    });

    float time_ell8 = time_kernel([&]() {
        ellpack8_spmv_kernel<<<grid_size, block_size>>>(d_ell8, d_x, d_y_ell8);
    });

    float time_ell7 = time_kernel([&]() {
        ellpack7_spmv_kernel<<<grid_size, block_size>>>(d_ell7, d_x, d_y_ell7);
    });

    cusparseHandle_t cusparse_handle = NULL;
    cusparseSpMatDescr_t matA_desc;
    cusparseDnVecDescr_t vecX_desc, vecY_desc;
    double alpha = 1.0, beta = 0.0;

    CHECK_CUSPARSE(cusparseCreate(&cusparse_handle));
    CHECK_CUSPARSE(cusparseCreateCsr(&matA_desc, h_csr.nrows, h_csr.ncols, h_csr.nnz,
                                     d_csr_row_ptr, d_csr_col_ind, d_csr_nz,
                                     CUSPARSE_INDEX_32I, CUSPARSE_INDEX_32I,
                                     CUSPARSE_INDEX_BASE_ZERO, CUDA_R_64F));
    CHECK_CUSPARSE(cusparseCreateDnVec(&vecX_desc, N, d_x, CUDA_R_64F));
    CHECK_CUSPARSE(cusparseCreateDnVec(&vecY_desc, N, d_y_cusparse, CUDA_R_64F));

    size_t buffer_size = 0;
    CHECK_CUSPARSE(cusparseSpMV_bufferSize(
        cusparse_handle, CUSPARSE_OPERATION_NON_TRANSPOSE,
        &alpha, matA_desc, vecX_desc, &beta, vecY_desc,
        CUDA_R_64F, CUSPARSE_SPMV_ALG_DEFAULT, &buffer_size));

    void* d_buffer = NULL;
    CHECK_CUDA(cudaMalloc(&d_buffer, buffer_size));

    float time_cusparse = time_kernel([&]() {
        CHECK_CUSPARSE(cusparseSpMV(cusparse_handle, CUSPARSE_OPERATION_NON_TRANSPOSE,
                                    &alpha, matA_desc, vecX_desc, &beta, vecY_desc,
                                    CUDA_R_64F, CUSPARSE_SPMV_ALG_DEFAULT, d_buffer));
    });

    check_correctness("CSR", N, d_y_cusparse, d_y_csr);
    check_correctness("ELLPACK8", N, d_y_cusparse, d_y_ell8);
    check_correctness("ELLPACK7", N, d_y_cusparse, d_y_ell7);

    printf("%lu,%.6f,%.6f,%.6f,%.6f\n", N, time_cusparse, time_csr, time_ell8, time_ell7);

    delete[] h_csr.col_ind; delete[] h_csr.row_ptr; delete[] h_csr.nz;
    for (int i = 0; i < 7; ++i) {
        delete[] h_ell7.col_ind[i];
        delete[] h_ell7.nz[i];
    }
    delete[] h_ell8.col_ind; delete[] h_ell8.nz;
    delete[] h_x.vals;

    CHECK_CUDA(cudaFree(d_csr));
    CHECK_CUDA(cudaFree(d_csr_col_ind));
    CHECK_CUDA(cudaFree(d_csr_row_ptr));
    CHECK_CUDA(cudaFree(d_csr_nz));

    CHECK_CUDA(cudaFree(d_ell7));
    for (int i = 0; i < 7; ++i) {
        CHECK_CUDA(cudaFree(d_ell7_col_ind[i]));
        CHECK_CUDA(cudaFree(d_ell7_nz[i]));
    }
    CHECK_CUDA(cudaFree(d_ell8));
    CHECK_CUDA(cudaFree(d_ell8_col_ind));
    CHECK_CUDA(cudaFree(d_ell8_nz));

    CHECK_CUDA(cudaFree(d_x));
    CHECK_CUDA(cudaFree(d_y_csr));
    CHECK_CUDA(cudaFree(d_y_ell7));
    CHECK_CUDA(cudaFree(d_y_ell8));
    CHECK_CUDA(cudaFree(d_y_cusparse));
    CHECK_CUDA(cudaFree(d_buffer));

    CHECK_CUSPARSE(cusparseDestroySpMat(matA_desc));
    CHECK_CUSPARSE(cusparseDestroyDnVec(vecX_desc));
    CHECK_CUSPARSE(cusparseDestroyDnVec(vecY_desc));
    CHECK_CUSPARSE(cusparseDestroy(cusparse_handle));
}

int main(int argc, char** argv) {
    std::cout << "N,cusparse,csr,ell8,ell7" << std::endl;

    if (argc > 1) {
        // Each argument is a path to a matrix dumped by dump_matrix.
        for (int i = 1; i < argc; ++i) {
            run_test(0, argv[i]);
        }
    } else {
        // No matrix files given: fall back to the synthetic banded matrix.
        std::vector<size_t> sizes = {100, 1000, 10000, 100000, 1000000, 10000000};
        for (size_t size : sizes) {
            run_test(size);
        }
    }
    return 0;
}
