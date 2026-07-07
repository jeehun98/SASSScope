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
            " | expr=" + expr +
            " | file=" + file +
            " | line=" + std::to_string(line));
    }
}

#define CUDA_CHECK(expr) cuda_check((expr), #expr, __FILE__, __LINE__)

void print_device()
{
    int device = 0;
    CUDA_CHECK(cudaGetDevice(&device));

    cudaDeviceProp prop{};
    CUDA_CHECK(cudaGetDeviceProperties(&prop, device));

    std::cout
        << "GPU: " << prop.name << '\n'
        << "Compute capability: " << prop.major << '.' << prop.minor << '\n'
        << "SM count: " << prop.multiProcessorCount << '\n'
        << "Warp size: " << prop.warpSize << "\n\n";
}

float max_abs_diff(const std::vector<float>& a, const std::vector<float>& b)
{
    if (a.size() != b.size()) {
        throw std::runtime_error("max_abs_diff size mismatch");
    }

    float result = 0.0f;
    for (size_t i = 0; i < a.size(); ++i) {
        result = std::max(result, std::fabs(a[i] - b[i]));
    }
    return result;
}

std::vector<float> ref_4_2_nobias(
    const std::vector<float>& x,
    const std::vector<float>& w1,
    int batch)
{
    std::vector<float> h(static_cast<size_t>(batch) * 2);

    for (int n = 0; n < batch; ++n) {
        const float* xn = x.data() + static_cast<size_t>(n) * 4;

        float h0 = w1[0] * xn[0];
        h0 = std::fma(w1[1], xn[1], h0);
        h0 = std::fma(w1[2], xn[2], h0);
        h0 = std::fma(w1[3], xn[3], h0);

        float h1 = w1[4] * xn[0];
        h1 = std::fma(w1[5], xn[1], h1);
        h1 = std::fma(w1[6], xn[2], h1);
        h1 = std::fma(w1[7], xn[3], h1);

        h[static_cast<size_t>(n) * 2 + 0] = h0;
        h[static_cast<size_t>(n) * 2 + 1] = h1;
    }

    return h;
}

std::vector<float> ref_4_2_bias(
    const std::vector<float>& x,
    const std::vector<float>& w1,
    const std::vector<float>& b1,
    int batch)
{
    std::vector<float> h(static_cast<size_t>(batch) * 2);

    for (int n = 0; n < batch; ++n) {
        const float* xn = x.data() + static_cast<size_t>(n) * 4;

        float h0 = b1[0];
        h0 = std::fma(w1[0], xn[0], h0);
        h0 = std::fma(w1[1], xn[1], h0);
        h0 = std::fma(w1[2], xn[2], h0);
        h0 = std::fma(w1[3], xn[3], h0);

        float h1 = b1[1];
        h1 = std::fma(w1[4], xn[0], h1);
        h1 = std::fma(w1[5], xn[1], h1);
        h1 = std::fma(w1[6], xn[2], h1);
        h1 = std::fma(w1[7], xn[3], h1);

        h[static_cast<size_t>(n) * 2 + 0] = h0;
        h[static_cast<size_t>(n) * 2 + 1] = h1;
    }

    return h;
}

std::vector<float> ref_4_2_relu(
    const std::vector<float>& x,
    const std::vector<float>& w1,
    const std::vector<float>& b1,
    int batch)
{
    auto h = ref_4_2_bias(x, w1, b1, batch);

    for (float& v : h) {
        v = std::max(v, 0.0f);
    }

    return h;
}

std::vector<float> ref_4_2_4(
    const std::vector<float>& x,
    const std::vector<float>& w1,
    const std::vector<float>& b1,
    const std::vector<float>& w2,
    const std::vector<float>& b2,
    int batch)
{
    const auto h = ref_4_2_relu(x, w1, b1, batch);
    std::vector<float> y(static_cast<size_t>(batch) * 4);

    for (int n = 0; n < batch; ++n) {
        const float h0 = h[static_cast<size_t>(n) * 2 + 0];
        const float h1 = h[static_cast<size_t>(n) * 2 + 1];

        for (int j = 0; j < 4; ++j) {
            float out = b2[j];
            out = std::fma(w2[j * 2 + 0], h0, out);
            out = std::fma(w2[j * 2 + 1], h1, out);
            y[static_cast<size_t>(n) * 4 + j] = out;
        }
    }

    return y;
}

template <typename T>
T* device_alloc(size_t count)
{
    T* ptr = nullptr;
    CUDA_CHECK(cudaMalloc(&ptr, count * sizeof(T)));
    return ptr;
}

template <typename T>
void copy_to_device(T* dst, const std::vector<T>& src)
{
    CUDA_CHECK(cudaMemcpy(dst, src.data(), src.size() * sizeof(T), cudaMemcpyHostToDevice));
}

template <typename T>
std::vector<T> copy_to_host(const T* src, size_t count)
{
    std::vector<T> out(count);
    CUDA_CHECK(cudaMemcpy(out.data(), src, count * sizeof(T), cudaMemcpyDeviceToHost));
    return out;
}

void print_h_sample(const char* name, const std::vector<float>& ref, const std::vector<float>& got)
{
    std::cout << name << " max abs diff = " << max_abs_diff(ref, got) << '\n';
    std::cout << "  first sample: "
              << "ref=(" << ref[0] << ", " << ref[1] << ") "
              << "gpu=(" << got[0] << ", " << got[1] << ")\n";
}

}  // namespace

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

        const auto h_ref_nobias = ref_4_2_nobias(x, w1, batch);
        const auto h_ref_bias   = ref_4_2_bias(x, w1, b1, batch);
        const auto h_ref_relu   = ref_4_2_relu(x, w1, b1, batch);
        const auto y_ref        = ref_4_2_4(x, w1, b1, w2, b2, batch);

        float* d_x = device_alloc<float>(x.size());
        float* d_w1 = device_alloc<float>(w1.size());
        float* d_b1 = device_alloc<float>(b1.size());
        float* d_w2 = device_alloc<float>(w2.size());
        float* d_b2 = device_alloc<float>(b2.size());

        float* d_h_nobias = device_alloc<float>(static_cast<size_t>(batch) * 2);
        float* d_h_bias   = device_alloc<float>(static_cast<size_t>(batch) * 2);
        float* d_h_relu   = device_alloc<float>(static_cast<size_t>(batch) * 2);

        float* d_y_split = device_alloc<float>(static_cast<size_t>(batch) * 4);
        float* d_y_fused = device_alloc<float>(static_cast<size_t>(batch) * 4);

        copy_to_device(d_x, x);
        copy_to_device(d_w1, w1);
        copy_to_device(d_b1, b1);
        copy_to_device(d_w2, w2);
        copy_to_device(d_b2, b2);

        constexpr int threads = 128;
        const int blocks = (batch + threads - 1) / threads;

        linear_4_2_nobias_f32<<<blocks, threads>>>(d_x, d_w1, d_h_nobias, batch);
        CUDA_CHECK(cudaGetLastError());

        linear_4_2_bias_f32<<<blocks, threads>>>(d_x, d_w1, d_b1, d_h_bias, batch);
        CUDA_CHECK(cudaGetLastError());

        linear_4_2_relu_f32<<<blocks, threads>>>(d_x, d_w1, d_b1, d_h_relu, batch);
        CUDA_CHECK(cudaGetLastError());

        linear_2_4_f32<<<blocks, threads>>>(d_h_relu, d_w2, d_b2, d_y_split, batch);
        CUDA_CHECK(cudaGetLastError());

        linear_4_2_4_fused_f32<<<blocks, threads>>>(
            d_x, d_w1, d_b1, d_w2, d_b2, d_y_fused, batch);
        CUDA_CHECK(cudaGetLastError());

        CUDA_CHECK(cudaDeviceSynchronize());

        const auto h_nobias = copy_to_host(d_h_nobias, static_cast<size_t>(batch) * 2);
        const auto h_bias   = copy_to_host(d_h_bias, static_cast<size_t>(batch) * 2);
        const auto h_relu   = copy_to_host(d_h_relu, static_cast<size_t>(batch) * 2);
        const auto y_split  = copy_to_host(d_y_split, static_cast<size_t>(batch) * 4);
        const auto y_fused  = copy_to_host(d_y_fused, static_cast<size_t>(batch) * 4);

        std::cout << std::fixed << std::setprecision(8);
        std::cout << "batch = " << batch << "\n\n";

        std::cout << "[Experiment 002: 4 -> 2 variants]\n";
        print_h_sample("linear_4_2_nobias_f32", h_ref_nobias, h_nobias);
        print_h_sample("linear_4_2_bias_f32  ", h_ref_bias, h_bias);
        print_h_sample("linear_4_2_relu_f32  ", h_ref_relu, h_relu);

        std::cout << "\n[Experiment 001 compatibility]\n";
        std::cout << "split max abs diff = " << max_abs_diff(y_ref, y_split) << '\n';
        std::cout << "fused max abs diff = " << max_abs_diff(y_ref, y_fused) << '\n';

        std::cout << "\nfirst output sample\n";
        for (int j = 0; j < 4; ++j) {
            std::cout
                << "y[" << j << "] ref=" << y_ref[j]
                << " split=" << y_split[j]
                << " fused=" << y_fused[j]
                << '\n';
        }

        cudaFree(d_y_fused);
        cudaFree(d_y_split);
        cudaFree(d_h_relu);
        cudaFree(d_h_bias);
        cudaFree(d_h_nobias);
        cudaFree(d_b2);
        cudaFree(d_w2);
        cudaFree(d_b1);
        cudaFree(d_w1);
        cudaFree(d_x);

        return 0;
    } catch (const std::exception& e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
}
