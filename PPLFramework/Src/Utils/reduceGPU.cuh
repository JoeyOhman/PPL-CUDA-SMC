#ifndef REDUCE_GPU
#define REDUCE_GPU

#ifdef GPU
#include <stdio.h>

// Sum
#define INIT_VAL 0
#define OP(a, b) a + b;

// Max
// #define INIT_VAL -INFINITY
// #define OP(a, b) a >= b ? a : b;

// compute the next highest power of 2 of 32-bit n
int nextPowerOfTwo(int n) {
    printf("n: %d\n", n);
    n--;
    n |= n >> 1;
    n |= n >> 2;
    n |= n >> 4;
    n |= n >> 8;
    n |= n >> 16;
    printf("next pow2: %d\n", n+1);
    return n + 1;
}

template <size_t blockSize, typename T>
__device__ void warpReduce(volatile T *sdata, size_t tid) {
    // if (blockSize >= 64) sdata[tid] += sdata[tid + 32];
    if (blockSize >= 64) sdata[tid] = OP(sdata[tid], sdata[tid + 32]);
    if (blockSize >= 32) sdata[tid] = OP(sdata[tid], sdata[tid + 16]);
    if (blockSize >= 16) sdata[tid] = OP(sdata[tid], sdata[tid +  8]);
    if (blockSize >=  8) sdata[tid] = OP(sdata[tid], sdata[tid +  4]);
    if (blockSize >=  4) sdata[tid] = OP(sdata[tid], sdata[tid +  2]);
    if (blockSize >=  2) sdata[tid] = OP(sdata[tid], sdata[tid +  1]);
}

template <size_t blockSize, typename T>
__global__ void reduceCUDA(T* g_idata, T* g_odata, size_t n) {
    __shared__ T sdata[blockSize];

    size_t tid = threadIdx.x;
    //size_t i = blockIdx.x*(blockSize*2) + tid;
    //size_t gridSize = blockSize*2*gridDim.x;
    size_t i = blockIdx.x*(blockSize) + tid;
    size_t gridSize = blockSize*gridDim.x;
    sdata[tid] = INIT_VAL;

    while (i < n) { sdata[tid] = OP(sdata[tid], g_idata[i]); i += gridSize; }
    //while (i < n) { sdata[tid] += g_idata[i] + g_idata[i+blockSize]; i += gridSize; }
    __syncthreads();

    if (blockSize >= 1024) { if (tid < 512) { sdata[tid] = OP(sdata[tid], sdata[tid + 512]); } __syncthreads(); }
    if (blockSize >=  512) { if (tid < 256) { sdata[tid] = OP(sdata[tid], sdata[tid + 256]); } __syncthreads(); }
    if (blockSize >=  256) { if (tid < 128) { sdata[tid] = OP(sdata[tid], sdata[tid + 128]); } __syncthreads(); }
    if (blockSize >=  128) { if (tid <  64) { sdata[tid] = OP(sdata[tid], sdata[tid +  64]); } __syncthreads(); }

    if (tid < 32) warpReduce<blockSize>(sdata, tid);
    if (tid == 0) g_odata[blockIdx.x] = sdata[0];
}


// PRE:
// dA is an array allocated on the GPU
// N <= len(dA) is a power of two (N >= BLOCKSIZE)
// POST: the sum of the first N elements of dA is returned
template<size_t blockSize, typename T>
T GPUReduction(T* dA, size_t N) {
    int nextPow2 = nextPowerOfTwo(N);
    T tot = 0.;
    size_t n = N;
    size_t blocksPerGrid = std::ceil((1.*n) / blockSize);

    T* tmp;
    cudaMalloc(&tmp, sizeof(T) * blocksPerGrid);
    // checkCUDAError("Error allocating tmp [GPUReduction]");

    T* from = dA;

    do {
        blocksPerGrid = std::ceil((1.*n) / blockSize);
        reduceCUDA<blockSize><<<blocksPerGrid, blockSize>>>(from, tmp, n);
        from = tmp;
        n = blocksPerGrid;
    } while (n > blockSize);

    if (n > 1)
        reduceCUDA<blockSize><<<1, blockSize>>>(tmp, tmp, n);

    cudaDeviceSynchronize();
    // checkCUDAError("Error launching kernel [GPUReduction]");

    cudaMemcpy(&tot, tmp, sizeof(T), cudaMemcpyDeviceToHost); 
    // checkCUDAError("Error copying result [GPUReduction]");
    cudaFree(tmp);
    return tot;
}

#endif

#endif

 