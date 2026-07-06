#pragma once
#include <cuda_runtime.h>

extern "C" __global__
void linear_4_2_relu_f32(const float* x, const float* w1, const float* b1,
                         float* h, int batch);

extern "C" __global__
void linear_2_4_f32(const float* h, const float* w2, const float* b2,
                    float* y, int batch);

extern "C" __global__
void linear_4_2_4_fused_f32(const float* x, const float* w1, const float* b1,
                            const float* w2, const float* b2,
                            float* y, int batch);
