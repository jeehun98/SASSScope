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

Statistics calculate_statistics(
    std::vector<double> values) {
    if (values.empty()) {
        throw std::invalid_argument(
            "cannot calculate statistics of empty data");
    }

    std::sort(
        values.begin(),
        values.end());

    Statistics result{};

    result.minimum = values.front();
    result.maximum = values.back();

    result.mean =
        std::accumulate(
            values.begin(),
            values.end(),
            0.0) /
        static_cast<double>(values.size());

    const std::size_t middle =
        values.size() / 2;

    if (values.size() % 2 == 0) {
        result.median =
            (
                values[middle - 1]
                + values[middle]
            ) /
            2.0;
    } else {
        result.median =
            values[middle];
    }

    double squared_sum = 0.0;

    for (const double value : values) {
        const double difference =
            value - result.mean;

        squared_sum +=
            difference * difference;
    }

    result.standard_deviation =
        std::sqrt(
            squared_sum /
            static_cast<double>(
                values.size()));

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

    // Detect launch-configuration and argument errors.
    CUDA_CHECK(cudaGetLastError());

    // Detect asynchronous kernel execution errors.
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
        warmup
            ? "warmup"
            : "measurement";

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
    output
        << '['
        << name
        << "]\n";

    output
        << "Minimum            : "
        << statistics.minimum
        << ' '
        << unit
        << '\n';

    output
        << "Median             : "
        << statistics.median
        << ' '
        << unit
        << '\n';

    output
        << "Mean               : "
        << statistics.mean
        << ' '
        << unit
        << '\n';

    output
        << "Maximum            : "
        << statistics.maximum
        << ' '
        << unit
        << '\n';

    output
        << "Standard deviation : "
        << statistics.standard_deviation
        << ' '
        << unit
        << "\n\n";
}

int parse_positive_int(
    const char* text,
    const char* name) {
    try {
        std::size_t parsed_length = 0;

        const int value =
            std::stoi(
                text,
                &parsed_length);

        if (
            parsed_length
            != std::string(text).size()
        ) {
            throw std::invalid_argument(
                "trailing characters");
        }

        if (value <= 0) {
            throw std::invalid_argument(
                "not positive");
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
        std::size_t parsed_length = 0;

        const int value =
            std::stoi(
                text,
                &parsed_length);

        if (
            parsed_length
            != std::string(text).size()
        ) {
            throw std::invalid_argument(
                "trailing characters");
        }

        if (value < 0) {
            throw std::invalid_argument(
                "negative");
        }

        return value;
    } catch (...) {
        throw std::invalid_argument(
            std::string(name) +
            " must be a non-negative integer");
    }
}

}  // namespace

int main(
    int argc,
    char** argv) {
    unsigned long long* device_cycles =
        nullptr;

    float* device_sink =
        nullptr;

    try {
        const std::filesystem::path
            output_directory =
                argc >= 2
                    ? argv[1]
                    : "results/runtime";

        const int samples =
            argc >= 3
                ? parse_positive_int(
                      argv[2],
                      "samples")
                : 100;

        const int warmups =
            argc >= 4
                ? parse_nonnegative_int(
                      argv[3],
                      "warmups")
                : 10;

        std::filesystem::create_directories(
            output_directory);

        constexpr float kSeed =
            1.0001f;

        constexpr float kMultiplier =
            1.0000001f;

        constexpr float kAddend =
            0.0000001f;

        constexpr auto kDynamicFfmaCount =
            sass_probe::kDynamicFfmaCount;

        static_assert(
            kDynamicFfmaCount > 0,
            "dynamic FFMA count must be positive");

        constexpr int kGridSize =
            1;

        constexpr int kBlockSize =
            1;

        constexpr int kActiveThreads =
            1;

        constexpr int kActiveLanes =
            1;

        constexpr int kDevice =
            0;

        CUDA_CHECK(cudaSetDevice(
            kDevice));

        cudaDeviceProp property{};

        CUDA_CHECK(cudaGetDeviceProperties(
            &property,
            kDevice));

        int reported_clock_khz = 0;

        CUDA_CHECK(cudaDeviceGetAttribute(
            &reported_clock_khz,
            cudaDevAttrClockRate,
            kDevice));

        int driver_version = 0;
        int runtime_version = 0;

        CUDA_CHECK(cudaDriverGetVersion(
            &driver_version));

        CUDA_CHECK(cudaRuntimeGetVersion(
            &runtime_version));

        CUDA_CHECK(cudaMalloc(
            reinterpret_cast<void**>(
                &device_cycles),
            sizeof(unsigned long long)));

        CUDA_CHECK(cudaMalloc(
            reinterpret_cast<void**>(
                &device_sink),
            sizeof(float)));

        auto launch_timer = [&]() {
            probe_timer_only
                <<<kGridSize, kBlockSize>>>(
                    device_cycles,
                    device_sink,
                    kSeed,
                    kMultiplier,
                    kAddend);
        };

        auto launch_dependent = [&]() {
            probe_dependent_ffma
                <<<kGridSize, kBlockSize>>>(
                    device_cycles,
                    device_sink,
                    kSeed,
                    kMultiplier,
                    kAddend);
        };

        auto launch_independent = [&]() {
            probe_independent_ffma_8
                <<<kGridSize, kBlockSize>>>(
                    device_cycles,
                    device_sink,
                    kSeed,
                    kMultiplier,
                    kAddend);
        };

        auto collect_validated =
            [&](
                auto& launch,
                const char* kernel_name,
                int run_index,
                bool warmup) {
                const ProbeResult result =
                    launch_and_collect(
                        launch,
                        device_cycles,
                        device_sink);

                validate_probe_result(
                    result,
                    kernel_name,
                    run_index,
                    warmup);

                return result;
            };

        // Warm every measured kernel and alternate the FFMA-kernel order.
        for (
            int index = 0;
            index < warmups;
            ++index
        ) {
            (void)collect_validated(
                launch_timer,
                "timer_only",
                index,
                true);

            if ((index & 1) == 0) {
                (void)collect_validated(
                    launch_dependent,
                    "dependent",
                    index,
                    true);

                (void)collect_validated(
                    launch_independent,
                    "independent_8",
                    index,
                    true);
            } else {
                (void)collect_validated(
                    launch_independent,
                    "independent_8",
                    index,
                    true);

                (void)collect_validated(
                    launch_dependent,
                    "dependent",
                    index,
                    true);
            }
        }

        const std::filesystem::path
            raw_output_path =
                output_directory /
                "runtime_raw.csv";

        std::ofstream raw_output(
            raw_output_path,
            std::ios::out |
                std::ios::trunc);

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

        raw_output
            << std::setprecision(12);

        std::vector<double>
            timer_cycle_samples;

        std::vector<double>
            dependent_cycles_per_ffma_samples;

        std::vector<double>
            independent_cycles_per_ffma_samples;

        timer_cycle_samples.reserve(
            samples);

        dependent_cycles_per_ffma_samples.reserve(
            samples);

        independent_cycles_per_ffma_samples.reserve(
            samples);

        float dependent_checksum =
            0.0f;

        float independent_checksum =
            0.0f;

        int dependent_first_runs =
            0;

        int independent_first_runs =
            0;

        auto record_timer_sample =
            [&](
                int run,
                const ProbeResult& result) {
                timer_cycle_samples.push_back(
                    static_cast<double>(
                        result.cycles));

                raw_output
                    << run
                    << ",timer_only,0,"
                    << result.cycles
                    << ",,"
                    << result.checksum
                    << '\n';
            };

        auto record_ffma_sample =
            [&](
                int run,
                const char* kernel_name,
                const ProbeResult& result,
                std::vector<double>& samples_output,
                float& last_checksum) {
                const double cycles_per_ffma =
                    static_cast<double>(
                        result.cycles) /
                    static_cast<double>(
                        kDynamicFfmaCount);

                samples_output.push_back(
                    cycles_per_ffma);

                last_checksum =
                    result.checksum;

                raw_output
                    << run
                    << ','
                    << kernel_name
                    << ','
                    << kDynamicFfmaCount
                    << ','
                    << result.cycles
                    << ','
                    << cycles_per_ffma
                    << ','
                    << result.checksum
                    << '\n';
            };

        for (
            int run = 0;
            run < samples;
            ++run
        ) {
            const ProbeResult timer =
                collect_validated(
                    launch_timer,
                    "timer_only",
                    run,
                    false);

            record_timer_sample(
                run,
                timer);

            // The CSV row order intentionally matches the real launch order.
            if ((run & 1) == 0) {
                ++dependent_first_runs;

                const ProbeResult dependent =
                    collect_validated(
                        launch_dependent,
                        "dependent",
                        run,
                        false);

                record_ffma_sample(
                    run,
                    "dependent",
                    dependent,
                    dependent_cycles_per_ffma_samples,
                    dependent_checksum);

                const ProbeResult independent =
                    collect_validated(
                        launch_independent,
                        "independent_8",
                        run,
                        false);

                record_ffma_sample(
                    run,
                    "independent_8",
                    independent,
                    independent_cycles_per_ffma_samples,
                    independent_checksum);
            } else {
                ++independent_first_runs;

                const ProbeResult independent =
                    collect_validated(
                        launch_independent,
                        "independent_8",
                        run,
                        false);

                record_ffma_sample(
                    run,
                    "independent_8",
                    independent,
                    independent_cycles_per_ffma_samples,
                    independent_checksum);

                const ProbeResult dependent =
                    collect_validated(
                        launch_dependent,
                        "dependent",
                        run,
                        false);

                record_ffma_sample(
                    run,
                    "dependent",
                    dependent,
                    dependent_cycles_per_ffma_samples,
                    dependent_checksum);
            }
        }

        raw_output.flush();

        if (!raw_output) {
            throw std::runtime_error(
                "failed while writing runtime_raw.csv");
        }

        raw_output.close();

        const Statistics timer_statistics =
            calculate_statistics(
                timer_cycle_samples);

        const Statistics dependent_statistics =
            calculate_statistics(
                dependent_cycles_per_ffma_samples);

        const Statistics independent_statistics =
            calculate_statistics(
                independent_cycles_per_ffma_samples);

        const std::filesystem::path
            summary_output_path =
                output_directory /
                "runtime_summary.txt";

        std::ofstream summary_output(
            summary_output_path,
            std::ios::out |
                std::ios::trunc);

        if (!summary_output) {
            throw std::runtime_error(
                "failed to open runtime_summary.txt");
        }

        summary_output
            << std::fixed
            << std::setprecision(6);

        summary_output
            << "GPU                  : "
            << property.name
            << '\n';

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
            << "Active lanes         : "
            << kActiveLanes
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
            << '\n';

        summary_output
            << "Execution policy     : "
               "timer first, FFMA order alternates by run parity\n";

        summary_output
            << "CSV row order        : "
               "actual kernel launch order\n";

        summary_output
            << "Dependent first      : "
            << dependent_first_runs
            << " runs\n";

        summary_output
            << "Independent first    : "
            << independent_first_runs
            << " runs\n\n";

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

        summary_output
            << "[Comparison]\n";

        summary_output
            << "Dependent/independent median ratio : "
            << median_ratio
            << '\n';

        summary_output
            << "Dependent median > independent     : "
            << (
                dependent_statistics.median
                > independent_statistics.median
                    ? "true"
                    : "false"
            )
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
            << (
                std::isfinite(
                    dependent_checksum) &&
                std::isfinite(
                    independent_checksum)
                    ? "true"
                    : "false"
            )
            << '\n';

        summary_output.flush();

        if (!summary_output) {
            throw std::runtime_error(
                "failed while writing runtime_summary.txt");
        }

        summary_output.close();

        const std::filesystem::path
            metadata_output_path =
                output_directory /
                "metadata.json";

        std::ofstream metadata_output(
            metadata_output_path,
            std::ios::out |
                std::ios::trunc);

        if (!metadata_output) {
            throw std::runtime_error(
                "failed to open metadata.json");
        }

        metadata_output << "{\n";

        metadata_output
            << "  \"schema_version\": 2,\n";

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
            << "  \"active_lanes\": "
            << kActiveLanes
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

        // Temporary compatibility key. This value represents the number
        // of dynamic FFMA instructions, not all executed SASS instructions.
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
            << "  \"execution_order_policy\": "
               "\"timer_first_then_alternating_ffma_by_run_parity\",\n";

        metadata_output
            << "  \"csv_row_order\": "
               "\"actual_kernel_launch_order\",\n";

        metadata_output
            << "  \"dependent_first_runs\": "
            << dependent_first_runs
            << ",\n";

        metadata_output
            << "  \"independent_first_runs\": "
            << independent_first_runs
            << ",\n";

        metadata_output
            << "  \"samples\": "
            << samples
            << ",\n";

        metadata_output
            << "  \"warmups\": "
            << warmups
            << '\n';

        metadata_output << "}\n";

        metadata_output.flush();

        if (!metadata_output) {
            throw std::runtime_error(
                "failed while writing metadata.json");
        }

        metadata_output.close();

        std::ifstream summary_input(
            summary_output_path);

        if (!summary_input) {
            throw std::runtime_error(
                "failed to reopen runtime_summary.txt");
        }

        std::cout
            << summary_input.rdbuf();

        std::cout
            << "\nResults written to: "
            << output_directory.string()
            << '\n';

        CUDA_CHECK(cudaFree(
            device_cycles));

        device_cycles =
            nullptr;

        CUDA_CHECK(cudaFree(
            device_sink));

        device_sink =
            nullptr;

        return EXIT_SUCCESS;
    } catch (const std::exception& error) {
        if (device_cycles != nullptr) {
            (void)cudaFree(
                device_cycles);
        }

        if (device_sink != nullptr) {
            (void)cudaFree(
                device_sink);
        }

        std::cerr
            << "ERROR: "
            << error.what()
            << '\n';

        return EXIT_FAILURE;
    }
}