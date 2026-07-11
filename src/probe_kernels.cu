#include "probe_kernels.cuh"

namespace {

__device__ __forceinline__ float ffma_ptx(
    float accumulator,
    float multiplier,
    float addend) {
    float result;
    asm volatile(
        "fma.rn.f32 %0, %1, %2, %3;"
        : "=f"(result)
        : "f"(accumulator), "f"(multiplier), "f"(addend));
    return result;
}

// A comment-only volatile PTX block creates a compiler dependency without
// intentionally adding a SASS arithmetic instruction. It prevents the value
// producer from being moved past the timing boundary.
__device__ __forceinline__ void compiler_use(float value) {
    asm volatile("// compiler_use %0\n" : : "f"(value) : "memory");
}

__device__ __forceinline__ unsigned long long read_clock64_raw() {
    unsigned long long value;
    asm volatile(
        "mov.u64 %0, %%clock64;"
        : "=l"(value)
        :
        : "memory");
    return value;
}

__device__ __forceinline__ unsigned long long read_clock_after_3(
    float v0,
    float v1,
    float v2) {
    compiler_use(v0);
    compiler_use(v1);
    compiler_use(v2);
    return read_clock64_raw();
}

__device__ __forceinline__ unsigned long long read_clock_after_10(
    float v0,
    float v1,
    float v2,
    float v3,
    float v4,
    float v5,
    float v6,
    float v7,
    float v8,
    float v9) {
    compiler_use(v0);
    compiler_use(v1);
    compiler_use(v2);
    compiler_use(v3);
    compiler_use(v4);
    compiler_use(v5);
    compiler_use(v6);
    compiler_use(v7);
    compiler_use(v8);
    compiler_use(v9);
    return read_clock64_raw();
}

}  // namespace

extern "C" __global__ void probe_timer_only(
    unsigned long long* cycles,
    float* sink,
    float seed,
    float multiplier,
    float addend) {
    if (blockIdx.x != 0 || threadIdx.x != 0) {
        return;
    }

    const unsigned long long start =
        read_clock_after_3(seed, multiplier, addend);
    const unsigned long long end =
        read_clock_after_3(seed, multiplier, addend);

    cycles[0] = end - start;
    sink[0] = seed;
}

extern "C" __global__ void probe_dependent_ffma(
    unsigned long long* cycles,
    float* sink,
    float seed,
    float multiplier,
    float addend) {
    if (blockIdx.x != 0 || threadIdx.x != 0) {
        return;
    }

    float x = seed;

    // The clock read has explicit compiler dependencies on x, multiplier,
    // and addend. This is intended to keep their setup before the timer.
    const unsigned long long start =
        read_clock_after_3(x, multiplier, addend);

#pragma unroll 1
    for (int outer = 0; outer < sass_probe::kOuterIterations; ++outer) {
#pragma unroll 32
        for (int instruction = 0;
             instruction < sass_probe::kInstructionsPerIteration;
             ++instruction) {
            x = ffma_ptx(x, multiplier, addend);
        }
    }

    // x is an input dependency of the ending clock read, so the clock cannot
    // be moved before the final FFMA at the compiler level.
    const unsigned long long end =
        read_clock_after_3(x, multiplier, addend);

    cycles[0] = end - start;
    sink[0] = x;
}

extern "C" __global__ void probe_independent_ffma_8(
    unsigned long long* cycles,
    float* sink,
    float seed,
    float multiplier,
    float addend) {
    if (blockIdx.x != 0 || threadIdx.x != 0) {
        return;
    }

    float x0 = seed + 0.0001f;
    float x1 = seed + 0.0002f;
    float x2 = seed + 0.0003f;
    float x3 = seed + 0.0004f;
    float x4 = seed + 0.0005f;
    float x5 = seed + 0.0006f;
    float x6 = seed + 0.0007f;
    float x7 = seed + 0.0008f;

    const unsigned long long start = read_clock_after_10(
        x0, x1, x2, x3, x4, x5, x6, x7, multiplier, addend);

#pragma unroll 1
    for (int outer = 0; outer < sass_probe::kOuterIterations; ++outer) {
#pragma unroll 4
        for (int group = 0; group < 4; ++group) {
            x0 = ffma_ptx(x0, multiplier, addend);
            x1 = ffma_ptx(x1, multiplier, addend);
            x2 = ffma_ptx(x2, multiplier, addend);
            x3 = ffma_ptx(x3, multiplier, addend);
            x4 = ffma_ptx(x4, multiplier, addend);
            x5 = ffma_ptx(x5, multiplier, addend);
            x6 = ffma_ptx(x6, multiplier, addend);
            x7 = ffma_ptx(x7, multiplier, addend);
        }
    }

    const unsigned long long end = read_clock_after_10(
        x0, x1, x2, x3, x4, x5, x6, x7, multiplier, addend);

    cycles[0] = end - start;

    // Reduction is intentionally after the ending clock read. It only keeps
    // all accumulators observable and should not enter the measured interval.
    sink[0] = x0 + x1 + x2 + x3 + x4 + x5 + x6 + x7;
}
