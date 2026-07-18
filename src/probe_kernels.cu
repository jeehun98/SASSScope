#include "probe_kernels.cuh"

namespace {

__device__ __forceinline__ float ffma_ptx(
    float accumulator,
    float multiplier,
    float addend) {
    // accumulator is both an input and an output operand.
    // This makes the recurrence relationship explicit at the PTX level.
    asm volatile(
        "fma.rn.f32 %0, %0, %1, %2;"
        : "+f"(accumulator)
        : "f"(multiplier), "f"(addend));

    return accumulator;
}

// Keeps a value visible to the CUDA compiler around a timing boundary
// without intentionally adding an arithmetic SASS instruction.
//
// This is only a compiler-level constraint. It does not create a hardware
// dependency between the value producer and CS2R. The final instruction
// ordering must therefore be checked in the generated SASS.
__device__ __forceinline__ void compiler_keep_live(float value) {
    asm volatile(
        "// compiler_keep_live %0\n"
        :
        : "f"(value)
        : "memory");
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
    compiler_keep_live(v0);
    compiler_keep_live(v1);
    compiler_keep_live(v2);

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
    compiler_keep_live(v0);
    compiler_keep_live(v1);
    compiler_keep_live(v2);
    compiler_keep_live(v3);
    compiler_keep_live(v4);
    compiler_keep_live(v5);
    compiler_keep_live(v6);
    compiler_keep_live(v7);
    compiler_keep_live(v8);
    compiler_keep_live(v9);

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

    // Keeps x, multiplier, and addend live at the compiler-level timing
    // boundary. The generated SASS must still be checked to ensure that
    // their setup instructions remain before the first CS2R.
    const unsigned long long start =
        read_clock_after_3(x, multiplier, addend);

#pragma unroll 1
    for (int outer = 0;
         outer < sass_probe::kOuterIterations;
         ++outer) {
#pragma unroll
    for (int instruction = 0;
        instruction < sass_probe::kFfmaPerOuterIteration;
        ++instruction) {
        x = ffma_ptx(x, multiplier, addend);
        }   
    }

    // Keeps the final accumulator live at the compiler-level timing boundary.
    // This is not a hardware completion fence. The position of the ending
    // CS2R relative to the final FFMA must be verified in SASS.
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

    // All eight accumulators and the two common operands are kept live at
    // the compiler-level timing boundary. Their initialization must still
    // be verified to occur before the first CS2R in the generated SASS.
    const unsigned long long start = read_clock_after_10(
        x0,
        x1,
        x2,
        x3,
        x4,
        x5,
        x6,
        x7,
        multiplier,
        addend);

#pragma unroll 1
    for (int outer = 0;
         outer < sass_probe::kOuterIterations;
         ++outer) {
#pragma unroll
    for (int group = 0;
        group < sass_probe::kIndependentGroupsPerOuterIteration;
        ++group) {
            // Round-robin ordering creates eight independent recurrence
            // chains with an expected accumulator reuse distance of eight.
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
        x0,
        x1,
        x2,
        x3,
        x4,
        x5,
        x6,
        x7,
        multiplier,
        addend);

    cycles[0] = end - start;

    // The reduction is intentionally placed after the ending clock read.
    // It keeps every accumulator observable without intentionally adding
    // arithmetic instructions to the measured interval.
    sink[0] = x0 + x1 + x2 + x3 + x4 + x5 + x6 + x7;
}