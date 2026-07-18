#include "probe_kernels.cuh"

#include <cuda_runtime.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <numeric>
#include <stdexcept>
#include <string>
#include <vector>

#define CUDA_CHECK(call)                                                     \
    do {                                                                     \
        const cudaError_t error__ = (call);                                  \
        if (error__ != cudaSuccess) {                                        \
            throw std::runtime_error(                                        \
                std::string("CUDA error: ") + cudaGetErrorString(error__) + \
                " at " + __FILE__ + ":" + std::to_string(__LINE__));       \
        }                                                                    \
    } while (false)

namespace {

struct Statistics {
    double minimum{};
    double median{};
    double mean{};
    double maximum{};
    double standard_deviation{};
};

Statistics calculate_statistics(std::vector<double> values) {
    if (values.empty()) {
        throw std::invalid_argument(
            "cannot calculate statistics of empty data");
    }

    std::sort(values.begin(), values.end());

    Statistics result{};
    result.minimum = values.front();
    result.maximum = values.back();

    result.mean =
        std::accumulate(values.begin(), values.end(), 0.0) /
        static_cast<double>(values.size());

    const std::size_t middle = values.size() / 2;

    if (values.size() % 2 == 0) {
        result.median =
            (values[middle - 1] + values[middle]) / 2.0;
    } else {
        result.median = values[middle];
    }

    double squared_sum = 0.0;

    for (const double value : values) {
        const double difference = value - result.mean;
        squared_sum += difference * difference;
    }

    result.standard_deviation =
        std::sqrt(
            squared_sum /
            static_cast<double>(values.size()));

    return result;
}

struct ProbeResult {
    unsigned long long cycles{};
    float checksum{};
};

template <typename LaunchFunction>
ProbeResult launch_and_collect(
    LaunchFunction&& launch,
    unsigned long long* device_cycles,
    float* device_sink) {
    launch();

    // Check launch configuration and argument errors separately from
    // asynchronous execution errors.
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaDeviceSynchronize());

    ProbeResult result{};

    CUDA_CHECK(cudaMemcpy(
        &result.cycles,
        device_cycles,
        sizeof(result.cycles),
        cudaMemcpyDeviceToHost));

    CUDA_CHECK(cudaMemcpy(
        &result.checksum,
        device_sink,
        sizeof(result.checksum),
        cudaMemcpyDeviceToHost));

    return result;
}

void validate_probe_result(
    const ProbeResult& result,
    const std::string& kernel_name,
    int run_index,
    bool warmup) {
    const std::string phase =
        warmup ? "warmup" : "measurement";

    if (result.cycles == 0) {
        throw std::runtime_error(
            kernel_name +
            " returned zero cycles during " +
            phase +
            " run " +
            std::to_string(run_index));
    }

    if (!std::isfinite(result.checksum)) {
        throw std::runtime_error(
            kernel_name +
            " returned a non-finite checksum during " +
            phase +
            " run " +
            std::to_string(run_index));
    }
}

void write_statistics(
    std::ostream& output,
    const std::string& name,
    const Statistics& statistics,
    const std::string& unit) {
    output << '[' << name << "]\n";
    output << "Minimum            : "
           << statistics.minimum << ' ' << unit << '\n';
    output << "Median             : "
           << statistics.median << ' ' << unit << '\n';
    output << "Mean               : "
           << statistics.mean << ' ' << unit << '\n';
    output << "Maximum            : "
           << statistics.maximum << ' ' << unit << '\n';
    output << "Standard deviation : "
           << statistics.standard_deviation
           << ' ' << unit << "\n\n";
}

int parse_positive_int(
    const char* text,
    const char* name) {
    try {
        const int value = std::stoi(text);

        if (value <= 0) {
            throw std::invalid_argument("not positive");
        }

        return value;
    } catch (...) {
        throw std::invalid_argument(
            std::string(name) +
            " must be a positive integer");
    }
}

int parse_nonnegative_int(
    const char* text,
    const char* name) {
    try {
        const int value = std::stoi(text);

        if (value < 0) {
            throw std::invalid_argument("negative");
        }

        return value;
    } catch (...) {
        throw std::invalid_argument(
            std::string(name) +
            " must be a non-negative integer");
    }
}

}  // namespace

int main(int argc, char** argv) {
    try {
        const std::filesystem::path output_directory =
            argc >= 2
                ? argv[1]
                : "results/runtime";

        const int samples =
            argc >= 3
                ? parse_positive_int(argv[2], "samples")
                : 100;

        const int warmups =
            argc >= 4
                ? parse_nonnegative_int(argv[3], "warmups")
                : 10;

        std::filesystem::create_directories(
            output_directory);

        constexpr float kSeed = 1.0001f;
        constexpr float kMultiplier = 1.0000001f;
        constexpr float kAddend = 0.0000001f;

        // kTotalInstructions currently denotes the number of dynamically
        // executed FFMA instructions, not every SASS instruction executed
        // inside the timed interval.
        constexpr auto kDynamicFfmaCount =
            sass_probe::kDynamicFfmaCount;

        constexpr int kGridSize = 1;
        constexpr int kBlockSize = 1;
        constexpr int kActiveThreads = 1;

        int device = 0;
        CUDA_CHECK(cudaSetDevice(device));

        cudaDeviceProp property{};
        CUDA_CHECK(cudaGetDeviceProperties(
            &property,
            device));

        int reported_clock_khz = 0;
        CUDA_CHECK(cudaDeviceGetAttribute(
            &reported_clock_khz,
            cudaDevAttrClockRate,
            device));

        int driver_version = 0;
        int runtime_version = 0;

        CUDA_CHECK(cudaDriverGetVersion(
            &driver_version));

        CUDA_CHECK(cudaRuntimeGetVersion(
            &runtime_version));

        unsigned long long* device_cycles = nullptr;
        float* device_sink = nullptr;

        CUDA_CHECK(cudaMalloc(
            reinterpret_cast<void**>(&device_cycles),
            sizeof(unsigned long long)));

        CUDA_CHECK(cudaMalloc(
            reinterpret_cast<void**>(&device_sink),
            sizeof(float)));

        auto launch_timer = [&]() {
            probe_timer_only<<<kGridSize, kBlockSize>>>(
                device_cycles,
                device_sink,
                kSeed,
                kMultiplier,
                kAddend);
        };

        auto launch_dependent = [&]() {
            probe_dependent_ffma<<<kGridSize, kBlockSize>>>(
                device_cycles,
                device_sink,
                kSeed,
                kMultiplier,
                kAddend);
        };

        auto launch_independent = [&]() {
            probe_independent_ffma_8<<<kGridSize, kBlockSize>>>(
                device_cycles,
                device_sink,
                kSeed,
                kMultiplier,
                kAddend);
        };

        // Warm up every kernel that will participate in the measured run.
        for (int index = 0; index < warmups; ++index) {
            const ProbeResult timer = launch_and_collect(
                launch_timer,
                device_cycles,
                device_sink);

            validate_probe_result(
                timer,
                "timer_only",
                index,
                true);

            const ProbeResult dependent = launch_and_collect(
                launch_dependent,
                device_cycles,
                device_sink);

            validate_probe_result(
                dependent,
                "dependent",
                index,
                true);

            const ProbeResult independent = launch_and_collect(
                launch_independent,
                device_cycles,
                device_sink);

            validate_probe_result(
                independent,
                "independent_8",
                index,
                true);
        }

        std::ofstream raw_output(
            output_directory / "runtime_raw.csv");

        if (!raw_output) {
            throw std::runtime_error(
                "failed to open runtime_raw.csv");
        }

        raw_output
            << "run,"
               "kernel,"
               "dynamic_ffma_count,"
               "total_cycles,"
               "cycles_per_ffma,"
               "checksum\n";

        raw_output << std::setprecision(12);

        std::vector<double> timer_cycle_samples;
        std::vector<double> dependent_cycles_per_ffma_samples;
        std::vector<double> independent_cycles_per_ffma_samples;

        timer_cycle_samples.reserve(samples);
        dependent_cycles_per_ffma_samples.reserve(samples);
        independent_cycles_per_ffma_samples.reserve(samples);

        float dependent_checksum = 0.0f;
        float independent_checksum = 0.0f;

        for (int run = 0; run < samples; ++run) {
            const ProbeResult timer = launch_and_collect(
                launch_timer,
                device_cycles,
                device_sink);

            validate_probe_result(
                timer,
                "timer_only",
                run,
                false);

            ProbeResult dependent{};
            ProbeResult independent{};

            // Alternate dependent and independent execution order to reduce
            // monotonic thermal or clock-drift bias.
            if (run % 2 == 0) {
                dependent = launch_and_collect(
                    launch_dependent,
                    device_cycles,
                    device_sink);

                validate_probe_result(
                    dependent,
                    "dependent",
                    run,
                    false);

                independent = launch_and_collect(
                    launch_independent,
                    device_cycles,
                    device_sink);

                validate_probe_result(
                    independent,
                    "independent_8",
                    run,
                    false);
            } else {
                independent = launch_and_collect(
                    launch_independent,
                    device_cycles,
                    device_sink);

                validate_probe_result(
                    independent,
                    "independent_8",
                    run,
                    false);

                dependent = launch_and_collect(
                    launch_dependent,
                    device_cycles,
                    device_sink);

                validate_probe_result(
                    dependent,
                    "dependent",
                    run,
                    false);
            }

            dependent_checksum = dependent.checksum;
            independent_checksum = independent.checksum;

            const double dependent_cycles_per_ffma =
                static_cast<double>(dependent.cycles) /
                static_cast<double>(kDynamicFfmaCount);

            const double independent_cycles_per_ffma =
                static_cast<double>(independent.cycles) /
                static_cast<double>(kDynamicFfmaCount);

            timer_cycle_samples.push_back(
                static_cast<double>(timer.cycles));

            dependent_cycles_per_ffma_samples.push_back(
                dependent_cycles_per_ffma);

            independent_cycles_per_ffma_samples.push_back(
                independent_cycles_per_ffma);

            raw_output
                << run
                << ",timer_only,0,"
                << timer.cycles
                << ",,"
                << timer.checksum
                << '\n';

            raw_output
                << run
                << ",dependent,"
                << kDynamicFfmaCount
                << ','
                << dependent.cycles
                << ','
                << dependent_cycles_per_ffma
                << ','
                << dependent.checksum
                << '\n';

            raw_output
                << run
                << ",independent_8,"
                << kDynamicFfmaCount
                << ','
                << independent.cycles
                << ','
                << independent_cycles_per_ffma
                << ','
                << independent.checksum
                << '\n';
        }

        const Statistics timer_statistics =
            calculate_statistics(
                timer_cycle_samples);

        const Statistics dependent_statistics =
            calculate_statistics(
                dependent_cycles_per_ffma_samples);

        const Statistics independent_statistics =
            calculate_statistics(
                independent_cycles_per_ffma_samples);

        std::ofstream summary_output(
            output_directory / "runtime_summary.txt");

        if (!summary_output) {
            throw std::runtime_error(
                "failed to open runtime_summary.txt");
        }

        summary_output
            << std::fixed
            << std::setprecision(6);

        summary_output
            << "GPU                  : "
            << property.name << '\n';

        summary_output
            << "Compute capability   : sm_"
            << property.major
            << property.minor
            << '\n';

        summary_output
            << "SM count             : "
            << property.multiProcessorCount
            << '\n';

        summary_output
            << "Warp size            : "
            << property.warpSize
            << '\n';

        summary_output
            << "Launch configuration : <<<"
            << kGridSize
            << ", "
            << kBlockSize
            << ">>>\n";

        summary_output
            << "Active threads       : "
            << kActiveThreads
            << '\n';

        summary_output
            << "Reported clock rate  : "
            << reported_clock_khz
            << " kHz\n";

        summary_output
            << "CUDA driver version  : "
            << driver_version
            << '\n';

        summary_output
            << "CUDA runtime version : "
            << runtime_version
            << '\n';

        summary_output
            << "Samples              : "
            << samples
            << '\n';

        summary_output
            << "Warmups              : "
            << warmups
            << '\n';

        summary_output
            << "Dynamic FFMA/probe   : "
            << kDynamicFfmaCount
            << "\n\n";

        summary_output
            << "Timer-only is a diagnostic measurement and is not\n"
               "subtracted from dependent or independent cycle results.\n\n";

        write_statistics(
            summary_output,
            "Timer-only",
            timer_statistics,
            "cycles");

        write_statistics(
            summary_output,
            "Dependent FFMA",
            dependent_statistics,
            "cycles/FFMA");

        write_statistics(
            summary_output,
            "Independent FFMA (8 accumulators)",
            independent_statistics,
            "cycles/FFMA");

        const double median_ratio =
            dependent_statistics.median /
            independent_statistics.median;

        summary_output << "[Comparison]\n";

        summary_output
            << "Dependent/independent median ratio : "
            << median_ratio
            << '\n';

        summary_output
            << "Dependent checksum                 : "
            << dependent_checksum
            << '\n';

        summary_output
            << "Independent checksum               : "
            << independent_checksum
            << '\n';

        summary_output
            << "Checksums finite                   : "
            << (std::isfinite(dependent_checksum) &&
                        std::isfinite(independent_checksum)
                    ? "true"
                    : "false")
            << '\n';

        std::ofstream metadata_output(
            output_directory / "metadata.json");

        if (!metadata_output) {
            throw std::runtime_error(
                "failed to open metadata.json");
        }

        metadata_output << "{\n";

        metadata_output
            << "  \"gpu_name\": \""
            << property.name
            << "\",\n";

        metadata_output
            << "  \"compute_capability\": \"sm_"
            << property.major
            << property.minor
            << "\",\n";

        metadata_output
            << "  \"sm_count\": "
            << property.multiProcessorCount
            << ",\n";

        metadata_output
            << "  \"warp_size\": "
            << property.warpSize
            << ",\n";

        metadata_output
            << "  \"grid_dim_x\": "
            << kGridSize
            << ",\n";

        metadata_output
            << "  \"block_dim_x\": "
            << kBlockSize
            << ",\n";

        metadata_output
            << "  \"active_threads\": "
            << kActiveThreads
            << ",\n";

        metadata_output
            << "  \"reported_clock_khz\": "
            << reported_clock_khz
            << ",\n";

        metadata_output
            << "  \"cuda_driver_version\": "
            << driver_version
            << ",\n";

        metadata_output
            << "  \"cuda_runtime_version\": "
            << runtime_version
            << ",\n";

        metadata_output
            << "  \"outer_iterations\": "
            << sass_probe::kOuterIterations
            << ",\n";

        metadata_output
            << "  \"ffma_per_outer_iteration\": "
            << sass_probe::kFfmaPerOuterIteration
            << ",\n";

        metadata_output
            << "  \"independent_accumulator_count\": "
            << sass_probe::kIndependentAccumulatorCount
            << ",\n";

        metadata_output
            << "  \"independent_groups_per_outer_iteration\": "
            << sass_probe::kIndependentGroupsPerOuterIteration
            << ",\n";

        // Keep the old key temporarily for compatibility with existing
        // analysis scripts.
        metadata_output
            << "  \"total_instructions\": "
            << kDynamicFfmaCount
            << ",\n";

        metadata_output
            << "  \"dynamic_ffma_count\": "
            << kDynamicFfmaCount
            << ",\n";

        metadata_output
            << "  \"timer_baseline\": "
               "\"three_value_keep_live_diagnostic_only\",\n";

        metadata_output
            << "  \"samples\": "
            << samples
            << ",\n";

        metadata_output
            << "  \"warmups\": "
            << warmups
            << "\n";

        metadata_output << "}\n";

        summary_output.flush();
        summary_output.close();
        metadata_output.flush();
        metadata_output.close();
        raw_output.flush();
        raw_output.close();

        // Re-open the summary for console output.
        std::ifstream summary_input(
            output_directory / "runtime_summary.txt");

        if (!summary_input) {
            throw std::runtime_error(
                "failed to reopen runtime_summary.txt");
        }

        std::cout << summary_input.rdbuf();

        std::cout
            << "\nResults written to: "
            << output_directory.string()
            << '\n';

        CUDA_CHECK(cudaFree(device_cycles));
        CUDA_CHECK(cudaFree(device_sink));

        return EXIT_SUCCESS;
    } catch (const std::exception& error) {
        std::cerr
            << "ERROR: "
            << error.what()
            << '\n';

        return EXIT_FAILURE;
    }
}