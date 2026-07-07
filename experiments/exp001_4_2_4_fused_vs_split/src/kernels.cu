#include "kernels.cuh"

extern "C" __global__
void linear_4_2_relu_f32(const float* __restrict__ x,
                         const float* __restrict__ w1,
                         const float* __restrict__ b1,
                         float* __restrict__ h,
                         int batch)
{
    const int n = blockIdx.x * blockDim.x + threadIdx.x;
    if (n >= batch) return;

    const float x0 = x[n * 4 + 0];
    const float x1 = x[n * 4 + 1];
    const float x2 = x[n * 4 + 2];
    const float x3 = x[n * 4 + 3];

    float h0 = b1[0];
    h0 = fmaf(w1[0], x0, h0);
    h0 = fmaf(w1[1], x1, h0);
    h0 = fmaf(w1[2], x2, h0);
    h0 = fmaf(w1[3], x3, h0);
    h0 = fmaxf(h0, 0.0f);

    float h1 = b1[1];
    h1 = fmaf(w1[4], x0, h1);
    h1 = fmaf(w1[5], x1, h1);
    h1 = fmaf(w1[6], x2, h1);
    h1 = fmaf(w1[7], x3, h1);
    h1 = fmaxf(h1, 0.0f);

    h[n * 2 + 0] = h0;
    h[n * 2 + 1] = h1;
}

extern "C" __global__
void linear_2_4_f32(const float* __restrict__ h,
                    const float* __restrict__ w2,
                    const float* __restrict__ b2,
                    float* __restrict__ y,
                    int batch)
{
    const int n = blockIdx.x * blockDim.x + threadIdx.x;
    if (n >= batch) return;

    const float h0 = h[n * 2 + 0];
    const float h1 = h[n * 2 + 1];

    #pragma unroll
    for (int j = 0; j < 4; ++j) {
        float out = b2[j];
        out = fmaf(w2[j * 2 + 0], h0, out);
        out = fmaf(w2[j * 2 + 1], h1, out);
        y[n * 4 + j] = out;
    }
}

extern "C" __global__
void linear_4_2_4_fused_f32(const float* __restrict__ x,
                            const float* __restrict__ w1,
                            const float* __restrict__ b1,
                            const float* __restrict__ w2,
                            const float* __restrict__ b2,
                            float* __restrict__ y,
                            int batch)
{
    const int n = blockIdx.x * blockDim.x + threadIdx.x;
    if (n >= batch) return;

    const float x0 = x[n * 4 + 0];
    const float x1 = x[n * 4 + 1];
    const float x2 = x[n * 4 + 2];
    const float x3 = x[n * 4 + 3];

    float h0 = b1[0];
    h0 = fmaf(w1[0], x0, h0);
    h0 = fmaf(w1[1], x1, h0);
    h0 = fmaf(w1[2], x2, h0);
    h0 = fmaf(w1[3], x3, h0);
    h0 = fmaxf(h0, 0.0f);

    float h1 = b1[1];
    h1 = fmaf(w1[4], x0, h1);
    h1 = fmaf(w1[5], x1, h1);
    h1 = fmaf(w1[6], x2, h1);
    h1 = fmaf(w1[7], x3, h1);
    h1 = fmaxf(h1, 0.0f);

    #pragma unroll
    for (int j = 0; j < 4; ++j) {
        float out = b2[j];
        out = fmaf(w2[j * 2 + 0], h0, out);
        out = fmaf(w2[j * 2 + 1], h1, out);
        y[n * 4 + j] = out;
    }
}
