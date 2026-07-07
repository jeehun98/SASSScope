#include "kernels.cuh"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
void cuda_check(cudaError_t status, const char* expr, const char* file, int line)
{
    if (status != cudaSuccess) {
        throw std::runtime_error(
            std::string("CUDA error: ") + cudaGetErrorString(status) +
            " | expr=" + expr + " | file=" + file +
            " | line=" + std::to_string(line));
    }
}
#define CUDA_CHECK(expr) cuda_check((expr), #expr, __FILE__, __LINE__)

std::vector<float> cpu_reference(
    const std::vector<float>& x,
    const std::vector<float>& w1,
    const std::vector<float>& b1,
    const std::vector<float>& w2,
    const std::vector<float>& b2,
    int batch)
{
    std::vector<float> y(static_cast<size_t>(batch) * 4);
    for (int n = 0; n < batch; ++n) {
        const float* xn = x.data() + static_cast<size_t>(n) * 4;
        float h0 = b1[0];
        float h1 = b1[1];

        for (int k = 0; k < 4; ++k) {
            h0 = std::fma(w1[0 * 4 + k], xn[k], h0);
            h1 = std::fma(w1[1 * 4 + k], xn[k], h1);
        }

        h0 = std::max(h0, 0.0f);
        h1 = std::max(h1, 0.0f);

        for (int j = 0; j < 4; ++j) {
            float out = b2[j];
            out = std::fma(w2[j * 2 + 0], h0, out);
            out = std::fma(w2[j * 2 + 1], h1, out);
            y[static_cast<size_t>(n) * 4 + j] = out;
        }
    }
    return y;
}

float max_abs_diff(const std::vector<float>& a, const std::vector<float>& b)
{
    float result = 0.0f;
    for (size_t i = 0; i < a.size(); ++i) {
        result = std::max(result, std::fabs(a[i] - b[i]));
    }
    return result;
}

void print_device()
{
    int device = 0;
    CUDA_CHECK(cudaGetDevice(&device));
    cudaDeviceProp prop{};
    CUDA_CHECK(cudaGetDeviceProperties(&prop, device));

    std::cout << "GPU: " << prop.name << '\n'
              << "Compute capability: " << prop.major << '.' << prop.minor << '\n'
              << "SM count: " << prop.multiProcessorCount << '\n'
              << "Warp size: " << prop.warpSize << "\n\n";
}
}

int main(int argc, char** argv)
{
    try {
        const int batch = (argc >= 2) ? std::max(1, std::atoi(argv[1])) : 32;
        print_device();

        std::vector<float> x(static_cast<size_t>(batch) * 4);
        for (size_t i = 0; i < x.size(); ++i) {
            x[i] = static_cast<float>((static_cast<int>(i) % 11) - 5) * 0.125f;
        }

        const std::vector<float> w1 = {
             0.25f, -0.50f,  0.75f,  0.10f,
            -0.20f,  0.40f, -0.60f,  0.80f
        };
        const std::vector<float> b1 = {0.15f, -0.05f};
        const std::vector<float> w2 = {
             0.30f, -0.20f,
            -0.40f,  0.50f,
             0.60f,  0.70f,
            -0.80f,  0.90f
        };
        const std::vector<float> b2 = {0.01f, 0.02f, 0.03f, 0.04f};
        const auto y_ref = cpu_reference(x, w1, b1, w2, b2, batch);

        float *d_x=nullptr, *d_w1=nullptr, *d_b1=nullptr, *d_w2=nullptr;
        float *d_b2=nullptr, *d_h=nullptr, *d_y_split=nullptr, *d_y_fused=nullptr;

        CUDA_CHECK(cudaMalloc(&d_x, x.size() * sizeof(float)));
        CUDA_CHECK(cudaMalloc(&d_w1, w1.size() * sizeof(float)));
        CUDA_CHECK(cudaMalloc(&d_b1, b1.size() * sizeof(float)));
        CUDA_CHECK(cudaMalloc(&d_w2, w2.size() * sizeof(float)));
        CUDA_CHECK(cudaMalloc(&d_b2, b2.size() * sizeof(float)));
        CUDA_CHECK(cudaMalloc(&d_h, static_cast<size_t>(batch) * 2 * sizeof(float)));
        CUDA_CHECK(cudaMalloc(&d_y_split, static_cast<size_t>(batch) * 4 * sizeof(float)));
        CUDA_CHECK(cudaMalloc(&d_y_fused, static_cast<size_t>(batch) * 4 * sizeof(float)));

        CUDA_CHECK(cudaMemcpy(d_x, x.data(), x.size()*sizeof(float), cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemcpy(d_w1, w1.data(), w1.size()*sizeof(float), cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemcpy(d_b1, b1.data(), b1.size()*sizeof(float), cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemcpy(d_w2, w2.data(), w2.size()*sizeof(float), cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemcpy(d_b2, b2.data(), b2.size()*sizeof(float), cudaMemcpyHostToDevice));

        constexpr int threads = 128;
        const int blocks = (batch + threads - 1) / threads;

        linear_4_2_relu_f32<<<blocks, threads>>>(d_x, d_w1, d_b1, d_h, batch);
        CUDA_CHECK(cudaGetLastError());
        linear_2_4_f32<<<blocks, threads>>>(d_h, d_w2, d_b2, d_y_split, batch);
        CUDA_CHECK(cudaGetLastError());
        linear_4_2_4_fused_f32<<<blocks, threads>>>(
            d_x, d_w1, d_b1, d_w2, d_b2, d_y_fused, batch);
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaDeviceSynchronize());

        std::vector<float> y_split(static_cast<size_t>(batch) * 4);
        std::vector<float> y_fused(static_cast<size_t>(batch) * 4);
        CUDA_CHECK(cudaMemcpy(y_split.data(), d_y_split,
                              y_split.size()*sizeof(float), cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaMemcpy(y_fused.data(), d_y_fused,
                              y_fused.size()*sizeof(float), cudaMemcpyDeviceToHost));

        std::cout << std::fixed << std::setprecision(8)
                  << "batch = " << batch << '\n'
                  << "split max abs diff = " << max_abs_diff(y_ref, y_split) << '\n'
                  << "fused max abs diff = " << max_abs_diff(y_ref, y_fused) << "\n\n"
                  << "first sample\n";

        for (int j = 0; j < 4; ++j) {
            std::cout << "y[" << j << "] ref=" << y_ref[j]
                      << " split=" << y_split[j]
                      << " fused=" << y_fused[j] << '\n';
        }

        cudaFree(d_y_fused); cudaFree(d_y_split); cudaFree(d_h);
        cudaFree(d_b2); cudaFree(d_w2); cudaFree(d_b1); cudaFree(d_w1); cudaFree(d_x);
        return 0;
    } catch (const std::exception& e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
}
