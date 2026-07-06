#pragma once

#include <cuda_runtime.h>

// Experiment 002-A
// 4 -> 2 Linear only, no bias, no activation.
extern "C" __global__
void linear_4_2_nobias_f32(
    const float* x,
    const float* w1,
    float* h,
    int batch);

// Experiment 002-B
// 4 -> 2 Linear + bias, no activation.
extern "C" __global__
void linear_4_2_bias_f32(
    const float* x,
    const float* w1,
    const float* b1,
    float* h,
    int batch);

// Experiment 002-C
// 4 -> 2 Linear + bias + ReLU.
extern "C" __global__
void linear_4_2_relu_f32(
    const float* x,
    const float* w1,
    const float* b1,
    float* h,
    int batch);

// Experiment 001 split second stage.
extern "C" __global__
void linear_2_4_f32(
    const float* h,
    const float* w2,
    const float* b2,
    float* y,
    int batch);

// Experiment 001 fused full path.
extern "C" __global__
void linear_4_2_4_fused_f32(
    const float* x,
    const float* w1,
    const float* b1,
    const float* w2,
    const float* b2,
    float* y,
    int batch);
