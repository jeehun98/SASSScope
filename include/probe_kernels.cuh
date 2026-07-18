#pragma once

#include <cuda_runtime.h>

namespace sass_probe {

// Number of FFMA instructions statically emitted inside one outer-loop body.
inline constexpr int kFfmaPerOuterIteration = 32;

// Number of independent accumulator chains used by the ILP probe.
inline constexpr int kIndependentAccumulatorCount = 8;

// Each independent accumulator receives this many FFMA instructions
// during one outer-loop iteration.
//
// 32 total FFMA / 8 accumulators = 4 FFMA per accumulator.
static_assert(
    kFfmaPerOuterIteration % kIndependentAccumulatorCount == 0,
    "FFMA count must be divisible by the independent accumulator count");

inline constexpr int kIndependentGroupsPerOuterIteration =
    kFfmaPerOuterIteration / kIndependentAccumulatorCount;

// The outer loop remains rolled so that the measured interval contains
// repeated execution of the same static FFMA instruction block.
inline constexpr int kOuterIterations = 4096;

// Total number of FFMA instructions dynamically executed by each probe.
//
// Dependent:
//   4096 outer iterations * 32 FFMA = 131072 FFMA
//
// Independent-8:
//   4096 outer iterations * 4 groups * 8 FFMA = 131072 FFMA
inline constexpr int kDynamicFfmaCount =
    kOuterIterations * kFfmaPerOuterIteration;

// Temporary aliases for existing scripts and source files.
// Remove these after every consumer has migrated to the new names.
inline constexpr int kInstructionsPerIteration =
    kFfmaPerOuterIteration;

inline constexpr int kTotalInstructions =
    kDynamicFfmaCount;

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