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

struct SlicedEllpack {
    size_t nrows;
    size_t ncols;
    size_t slice_size;
    int* slice_ptr;
    int* col_ind;
    double* nz;
    int* row_map; // row_map[sorted_position] = original_row_index
};

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

void sliced_ellpack_host_fill(const std::vector<size_t>& row_in, const std::vector<size_t>& col_in, const std::vector<double>& nz_in, size_t nrows, size_t ncols, SlicedEllpack& host_sell, const size_t slice_size) {
    host_sell.nrows = nrows;
    host_sell.ncols = ncols;
    host_sell.slice_size = slice_size;

    std::vector<std::vector<std::pair<int, double>>> rows_data(nrows);
    std::vector<std::pair<size_t, size_t>> row_metadata(nrows);

    for (size_t i = 0; i < nz_in.size(); ++i) {
        size_t r = row_in[i];
        rows_data[r].push_back({static_cast<int>(col_in[i]), nz_in[i]});
    }

    for (size_t i = 0; i < nrows; ++i) {
        row_metadata[i] = {i, rows_data[i].size()};
    }

    std::sort(row_metadata.begin(), row_metadata.end(), [](const auto& a, const auto& b) {
        return a.second > b.second;
    });

    // row_map[sorted position] = original row index. The kernel processes
    // rows in sorted (slice) order, so this map is required to scatter each
    // computed result back to its row's original position in y.
    host_sell.row_map = new int[nrows];
    for (size_t i = 0; i < nrows; ++i) {
        host_sell.row_map[i] = static_cast<int>(row_metadata[i].first);
    }

    size_t num_slices = (nrows + slice_size - 1) / slice_size;
    host_sell.slice_ptr = new int[num_slices + 1];
    host_sell.slice_ptr[0] = 0;
    size_t current_padded_nnz = 0;

    for (size_t i = 0; i < num_slices; ++i) {
        size_t current_slice_size = std::min(slice_size, nrows - i * slice_size);
        size_t max_nnz_in_slice = 0;

        for (size_t j = 0; j < current_slice_size; ++j) {
            size_t original_row_idx = row_metadata[i * slice_size + j].first;
            max_nnz_in_slice = std::max(max_nnz_in_slice, rows_data[original_row_idx].size());
        }

        current_padded_nnz += current_slice_size * max_nnz_in_slice;
        host_sell.slice_ptr[i + 1] = current_padded_nnz;
    }

    host_sell.col_ind = new int[current_padded_nnz];
    host_sell.nz = new double[current_padded_nnz];

    for (size_t i = 0; i < num_slices; ++i) {
        size_t current_slice_size = std::min(slice_size, nrows - i * slice_size);
        size_t max_nnz_in_slice = (host_sell.slice_ptr[i+1] - host_sell.slice_ptr[i]) / current_slice_size;
        size_t slice_base_idx = host_sell.slice_ptr[i];

        for (size_t j = 0; j < current_slice_size; ++j) {
            size_t row_idx_in_slice = j;
            size_t original_row_idx = row_metadata[i * slice_size + j].first;
            const auto& row_data = rows_data[original_row_idx];

            for (size_t k = 0; k < max_nnz_in_slice; ++k) {
                size_t padded_idx = slice_base_idx + k * current_slice_size + row_idx_in_slice;
                if (k < row_data.size()) {
                    host_sell.col_ind[padded_idx] = row_data[k].first;
                    host_sell.nz[padded_idx] = row_data[k].second;
                } else {
                    host_sell.col_ind[padded_idx] = PADDING_VALUE;
                    host_sell.nz[padded_idx] = 0.0;
                }
            }
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

        double sum = 0.0;
        for (size_t i = 0; i < A->max_row_nnz; ++i) {
            size_t idx = row * A->max_row_nnz + i;
            sum += nz[idx] * x[col_ind[idx]];
        }
        y[row] = sum;
    }
}

__global__ void ellpack7_spmv_kernel(const Ellpack7* __restrict__ A, const double* __restrict__ x, double* __restrict__ y) {
    size_t row = blockIdx.x * blockDim.x + threadIdx.x;

    if (row < A->nrows) {
        double sum = 0.0;
        for (size_t i = 0; i < 7; ++i) {
            const double* __restrict__ nz_i = A->nz[i];
            const int* __restrict__ col_ind_i = A->col_ind[i];
            sum += nz_i[row] * x[col_ind_i[row]];
        }
        y[row] = sum;
    }
}

__global__ void sliced_ellpack_spmv_kernel(
    const SlicedEllpack* __restrict__ A,
    const double* __restrict__ x,
    double* __restrict__ y) {
    int row = blockIdx.x * blockDim.x + threadIdx.x;

    if (row < A->nrows) {
        const int* __restrict__ slice_ptr = A->slice_ptr;
        const int* __restrict__ col_ind = A->col_ind;
        const double* __restrict__ nz = A->nz;
        const int* __restrict__ row_map = A->row_map;

        double sum = 0;
        int slice_index = row / A->slice_size;
        int row_in_slice = row % A->slice_size;
        int max_elements_in_this_slice = slice_ptr[slice_index + 1] - slice_ptr[slice_index];
        int rows_in_this_slice = (slice_index * A->slice_size + A->slice_size) > A->nrows ?
                                 (A->nrows - slice_index * A->slice_size) : A->slice_size;
        int max_columns_in_this_slice = max_elements_in_this_slice / rows_in_this_slice;
        int slice_base_index = slice_ptr[slice_index] + row_in_slice;

        for (int i = 0; i < max_columns_in_this_slice; ++i) {
            int index = slice_base_index + i * rows_in_this_slice;
            int col = col_ind[index];
            sum += nz[index] * x[col];
        }
        // 'row' is a position in sorted (slice) order, not the original row
        // index, so the result must be scattered back via row_map.
        y[row_map[row]] = sum;
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

void run_test(size_t N) {
    const size_t block_size = 256;
    const size_t grid_size = (N + block_size - 1) / block_size;
    const size_t slice_size = 256;

    std::vector<size_t> h_row_vec, h_col_vec;
    std::vector<double> h_nz_vec;
    banded_matrix_fill(N, N, h_row_vec, h_col_vec, h_nz_vec);
    int64_t nnz = h_nz_vec.size();

    Csr h_csr;
    csr_host_fill(h_row_vec, h_col_vec, h_nz_vec, N, N, h_csr);
    Ellpack8 h_ell8;
    ellpack8_host_fill(h_row_vec, h_col_vec, h_nz_vec, N, N, h_ell8);
    Ellpack7 h_ell7;
    ellpack7_host_fill(h_row_vec, h_col_vec, h_nz_vec, N, N, h_ell7);

    SlicedEllpack h_sell;
    sliced_ellpack_host_fill(h_row_vec, h_col_vec, h_nz_vec, N, N, h_sell, slice_size);

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

    SlicedEllpack *d_sell;
    CHECK_CUDA(cudaMalloc(&d_sell, sizeof(SlicedEllpack)));
    size_t num_slices = (N + slice_size - 1) / slice_size;
    int total_padded_nnz = h_sell.slice_ptr[num_slices];
    int *d_sell_slice_ptr;
    int *d_sell_col_ind;
    double *d_sell_nz;
    int *d_sell_row_map;
    CHECK_CUDA(cudaMalloc(&d_sell_slice_ptr, (num_slices + 1) * sizeof(int)));
    CHECK_CUDA(cudaMalloc(&d_sell_col_ind, total_padded_nnz * sizeof(int)));
    CHECK_CUDA(cudaMalloc(&d_sell_nz, total_padded_nnz * sizeof(double)));
    CHECK_CUDA(cudaMalloc(&d_sell_row_map, N * sizeof(int)));

    double *d_x, *d_y_csr, *d_y_ell8, *d_y_ell7, *d_y_cusparse, *d_y_sell;
    CHECK_CUDA(cudaMalloc(&d_x, N * sizeof(double)));
    CHECK_CUDA(cudaMalloc(&d_y_csr, N * sizeof(double)));
    CHECK_CUDA(cudaMalloc(&d_y_ell8, N * sizeof(double)));
    CHECK_CUDA(cudaMalloc(&d_y_ell7, N * sizeof(double)));
    CHECK_CUDA(cudaMalloc(&d_y_cusparse, N * sizeof(double)));
    CHECK_CUDA(cudaMalloc(&d_y_sell, N * sizeof(double)));
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
    CHECK_CUDA(cudaMemcpy(d_sell_slice_ptr, h_sell.slice_ptr, (num_slices + 1) * sizeof(int), cudaMemcpyHostToDevice));
    CHECK_CUDA(cudaMemcpy(d_sell_col_ind, h_sell.col_ind, total_padded_nnz * sizeof(int), cudaMemcpyHostToDevice));
    CHECK_CUDA(cudaMemcpy(d_sell_nz, h_sell.nz, total_padded_nnz * sizeof(double), cudaMemcpyHostToDevice));
    CHECK_CUDA(cudaMemcpy(d_sell_row_map, h_sell.row_map, N * sizeof(int), cudaMemcpyHostToDevice));

    SlicedEllpack h_d_sell;
    h_d_sell.nrows = h_sell.nrows;
    h_d_sell.ncols = h_sell.ncols;
    h_d_sell.slice_size = h_sell.slice_size;
    h_d_sell.slice_ptr = d_sell_slice_ptr;
    h_d_sell.col_ind = d_sell_col_ind;
    h_d_sell.nz = d_sell_nz;
    h_d_sell.row_map = d_sell_row_map;
    CHECK_CUDA(cudaMemcpy(d_sell, &h_d_sell, sizeof(SlicedEllpack), cudaMemcpyHostToDevice));
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

    float time_sell = time_kernel([&]() {
        sliced_ellpack_spmv_kernel<<<grid_size, block_size>>>(d_sell, d_x, d_y_sell);
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
    check_correctness("SlicedELLPACK", N, d_y_cusparse, d_y_sell);

    printf("%lu,%.6f,%.6f,%.6f,%.6f,%.6f\n", N, time_cusparse, time_csr, time_ell8, time_sell, time_ell7);

    delete[] h_csr.col_ind; delete[] h_csr.row_ptr; delete[] h_csr.nz;
    for (int i = 0; i < 7; ++i) {
        delete[] h_ell7.col_ind[i];
        delete[] h_ell7.nz[i];
    }
    delete[] h_ell8.col_ind; delete[] h_ell8.nz;
    delete[] h_sell.slice_ptr; delete[] h_sell.col_ind; delete[] h_sell.nz; delete[] h_sell.row_map;
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
    CHECK_CUDA(cudaFree(d_sell));
    CHECK_CUDA(cudaFree(d_sell_slice_ptr));
    CHECK_CUDA(cudaFree(d_sell_col_ind));
    CHECK_CUDA(cudaFree(d_sell_nz));
    CHECK_CUDA(cudaFree(d_sell_row_map));

    CHECK_CUDA(cudaFree(d_x));
    CHECK_CUDA(cudaFree(d_y_csr));
    CHECK_CUDA(cudaFree(d_y_ell7));
    CHECK_CUDA(cudaFree(d_y_ell8));
    CHECK_CUDA(cudaFree(d_y_cusparse));
    CHECK_CUDA(cudaFree(d_y_sell));
    CHECK_CUDA(cudaFree(d_buffer));

    CHECK_CUSPARSE(cusparseDestroySpMat(matA_desc));
    CHECK_CUSPARSE(cusparseDestroyDnVec(vecX_desc));
    CHECK_CUSPARSE(cusparseDestroyDnVec(vecY_desc));
    CHECK_CUSPARSE(cusparseDestroy(cusparse_handle));
}

int main(int argc, char** argv) {
    std::cout << "N,cusparse,csr,ell8,sell,ell7" << std::endl;
    std::vector<size_t> sizes = {100, 1000, 10000, 100000, 1000000, 10000000};
    for (size_t size : sizes) {
        run_test(size);
    }
    return 0;
}
