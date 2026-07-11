#pragma once

#include <cuda_runtime.h>

namespace sass_probe {

inline constexpr int kOuterIterations = 4096;
inline constexpr int kInstructionsPerIteration = 32;
inline constexpr int kTotalInstructions =
    kOuterIterations * kInstructionsPerIteration;

}  // namespace sass_probe

extern "C" __global__ void probe_timer_only(
    unsigned long long* cycles,
    float* sink,
    float seed,
    float multiplier,
    float addend);

extern "C" __global__ void probe_dependent_ffma(
    unsigned long long* cycles,
    float* sink,
    float seed,
    float multiplier,
    float addend);

extern "C" __global__ void probe_independent_ffma_8(
    unsigned long long* cycles,
    float* sink,
    float seed,
    float multiplier,
    float addend);
