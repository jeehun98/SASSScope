#!/usr/bin/env python3
"""
Validate runtime_raw.csv and summarize the dependent/independent FFMA probes.

Expected CSV schema:

    run,kernel,dynamic_ffma_count,total_cycles,cycles_per_ffma,checksum

Expected kernel names:

    timer_only
    dependent
    independent_8

Interpretation:

- timer_only is summarized using total_cycles.
- dependent and independent_8 are summarized using cycles_per_ffma.
- cycles_per_ffma is elapsed SM cycles divided by dynamic FFMA count.
- It is not a generic cycles-per-instruction metric.
"""

from __future__ import annotations

import argparse
import csv
import math
import statistics
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


REQUIRED_COLUMNS = {
    "run",
    "kernel",
    "dynamic_ffma_count",
    "total_cycles",
    "cycles_per_ffma",
    "checksum",
}

REQUIRED_KERNELS = (
    "timer_only",
    "dependent",
    "independent_8",
)

FFMA_KERNELS = {
    "dependent",
    "independent_8",
}


@dataclass(frozen=True)
class RuntimeSample:
    row_number: int
    row_order: int
    run: int
    kernel: str
    dynamic_ffma_count: int
    total_cycles: float
    cycles_per_ffma: float | None
    checksum: float


@dataclass(frozen=True)
class StatisticsSummary:
    count: int
    minimum: float
    percentile_05: float
    percentile_25: float
    median: float
    percentile_75: float
    percentile_95: float
    maximum: float
    mean: float
    population_stddev: float
    coefficient_of_variation: float
    median_absolute_deviation: float
    robust_outlier_count: int


def parse_integer(
    value: str | None,
    field_name: str,
    row_number: int,
) -> int:
    if value is None or not value.strip():
        raise ValueError(
            f"row {row_number}: missing integer field '{field_name}'"
        )

    try:
        return int(value)
    except ValueError as error:
        raise ValueError(
            f"row {row_number}: invalid integer in "
            f"'{field_name}': {value!r}"
        ) from error


def parse_float(
    value: str | None,
    field_name: str,
    row_number: int,
) -> float:
    if value is None or not value.strip():
        raise ValueError(
            f"row {row_number}: missing floating-point field "
            f"'{field_name}'"
        )

    try:
        return float(value)
    except ValueError as error:
        raise ValueError(
            f"row {row_number}: invalid floating-point value in "
            f"'{field_name}': {value!r}"
        ) from error


def parse_optional_float(
    value: str | None,
    field_name: str,
    row_number: int,
) -> float | None:
    if value is None or not value.strip():
        return None

    try:
        return float(value)
    except ValueError as error:
        raise ValueError(
            f"row {row_number}: invalid floating-point value in "
            f"'{field_name}': {value!r}"
        ) from error


def percentile(
    values: Iterable[float],
    probability: float,
) -> float:
    ordered = sorted(values)

    if not ordered:
        raise ValueError("percentile requires at least one value")

    if not 0.0 <= probability <= 1.0:
        raise ValueError("probability must be between 0 and 1")

    if len(ordered) == 1:
        return ordered[0]

    position = probability * (len(ordered) - 1)
    lower_index = math.floor(position)
    upper_index = math.ceil(position)

    if lower_index == upper_index:
        return ordered[lower_index]

    weight = position - lower_index

    return (
        ordered[lower_index] * (1.0 - weight)
        + ordered[upper_index] * weight
    )


def median_absolute_deviation(
    values: list[float],
) -> float:
    median_value = statistics.median(values)

    deviations = [
        abs(value - median_value)
        for value in values
    ]

    return statistics.median(deviations)


def count_robust_outliers(
    values: list[float],
    threshold: float = 3.5,
) -> int:
    if len(values) < 3:
        return 0

    median_value = statistics.median(values)
    mad = median_absolute_deviation(values)

    if mad == 0.0:
        return 0

    outlier_count = 0

    for value in values:
        modified_z_score = (
            0.6745
            * abs(value - median_value)
            / mad
        )

        if modified_z_score > threshold:
            outlier_count += 1

    return outlier_count


def calculate_statistics(
    values: list[float],
) -> StatisticsSummary:
    if not values:
        raise ValueError(
            "statistics require at least one value"
        )

    mean_value = statistics.fmean(values)
    population_stddev = statistics.pstdev(values)

    coefficient_of_variation = (
        population_stddev / mean_value
        if mean_value != 0.0
        else math.inf
    )

    return StatisticsSummary(
        count=len(values),
        minimum=min(values),
        percentile_05=percentile(values, 0.05),
        percentile_25=percentile(values, 0.25),
        median=statistics.median(values),
        percentile_75=percentile(values, 0.75),
        percentile_95=percentile(values, 0.95),
        maximum=max(values),
        mean=mean_value,
        population_stddev=population_stddev,
        coefficient_of_variation=(
            coefficient_of_variation
        ),
        median_absolute_deviation=(
            median_absolute_deviation(values)
        ),
        robust_outlier_count=(
            count_robust_outliers(values)
        ),
    )


def append_statistics(
    lines: list[str],
    name: str,
    unit: str,
    summary: StatisticsSummary,
) -> None:
    lines.append(f"[{name}]")
    lines.append(f"unit       : {unit}")
    lines.append(f"samples    : {summary.count}")
    lines.append(f"min        : {summary.minimum:.9f}")
    lines.append(
        f"p05        : {summary.percentile_05:.9f}"
    )
    lines.append(
        f"p25        : {summary.percentile_25:.9f}"
    )
    lines.append(f"median     : {summary.median:.9f}")
    lines.append(
        f"p75        : {summary.percentile_75:.9f}"
    )
    lines.append(
        f"p95        : {summary.percentile_95:.9f}"
    )
    lines.append(f"max        : {summary.maximum:.9f}")
    lines.append(f"mean       : {summary.mean:.9f}")
    lines.append(
        f"pstdev     : "
        f"{summary.population_stddev:.9f}"
    )
    lines.append(
        f"cv         : "
        f"{summary.coefficient_of_variation:.9f}"
    )
    lines.append(
        f"MAD        : "
        f"{summary.median_absolute_deviation:.9f}"
    )
    lines.append(
        f"outliers   : "
        f"{summary.robust_outlier_count}"
    )
    lines.append("")


def write_report(
    output_path: Path,
    lines: list[str],
) -> None:
    output_path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    output_path.write_text(
        "\n".join(lines) + "\n",
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Validate FFMA runtime CSV and summarize "
            "dependent versus independent execution."
        )
    )

    parser.add_argument(
        "--input",
        required=True,
        type=Path,
        help="input runtime_raw.csv",
    )

    parser.add_argument(
        "--output",
        required=True,
        type=Path,
        help="output runtime_check.txt",
    )

    parser.add_argument(
        "--expected-samples",
        type=int,
        default=None,
        help=(
            "expected sample count for each kernel; "
            "when omitted, equal group sizes are still required"
        ),
    )

    parser.add_argument(
        "--minimum-ratio",
        type=float,
        default=1.20,
        help=(
            "warning threshold for dependent median divided by "
            "independent median"
        ),
    )

    parser.add_argument(
        "--max-cv",
        type=float,
        default=0.05,
        help=(
            "warning threshold for population coefficient of "
            "variation"
        ),
    )

    parser.add_argument(
        "--fail-on-warning",
        action="store_true",
        help=(
            "return a non-zero exit code when warnings exist"
        ),
    )

    args = parser.parse_args()

    if (
        args.expected_samples is not None
        and args.expected_samples <= 0
    ):
        parser.error(
            "--expected-samples must be positive"
        )

    if args.minimum_ratio <= 0.0:
        parser.error(
            "--minimum-ratio must be positive"
        )

    if args.max_cv < 0.0:
        parser.error(
            "--max-cv must be non-negative"
        )

    errors: list[str] = []
    warnings: list[str] = []

    if not args.input.is_file():
        errors.append(
            f"Input CSV was not found: {args.input}"
        )

        lines = [
            "[overall]",
            "status        : FAIL",
            f"error count   : {len(errors)}",
            "warning count : 0",
            "",
            "[errors]",
            *[f"- {error}" for error in errors],
        ]

        write_report(
            args.output,
            lines,
        )

        print(
            args.output.read_text(
                encoding="utf-8"
            ),
            end="",
        )

        return 3

    samples: list[RuntimeSample] = []

    with args.input.open(
        newline="",
        encoding="utf-8-sig",
    ) as stream:
        reader = csv.DictReader(stream)

        actual_columns = set(
            reader.fieldnames or []
        )

        missing_columns = (
            REQUIRED_COLUMNS - actual_columns
        )

        if missing_columns:
            errors.append(
                "CSV schema is missing required columns: "
                + ", ".join(
                    sorted(missing_columns)
                )
            )
        else:
            for row_order, row in enumerate(
                reader,
                start=0,
            ):
                row_number = row_order + 2

                if not any(
                    value and value.strip()
                    for value in row.values()
                ):
                    continue

                try:
                    kernel = (
                        row["kernel"].strip()
                    )

                    if kernel not in REQUIRED_KERNELS:
                        errors.append(
                            f"row {row_number}: unknown kernel "
                            f"name {kernel!r}"
                        )
                        continue

                    sample = RuntimeSample(
                        row_number=row_number,
                        row_order=row_order,
                        run=parse_integer(
                            row["run"],
                            "run",
                            row_number,
                        ),
                        kernel=kernel,
                        dynamic_ffma_count=parse_integer(
                            row["dynamic_ffma_count"],
                            "dynamic_ffma_count",
                            row_number,
                        ),
                        total_cycles=parse_float(
                            row["total_cycles"],
                            "total_cycles",
                            row_number,
                        ),
                        cycles_per_ffma=(
                            parse_optional_float(
                                row["cycles_per_ffma"],
                                "cycles_per_ffma",
                                row_number,
                            )
                        ),
                        checksum=parse_float(
                            row["checksum"],
                            "checksum",
                            row_number,
                        ),
                    )

                    samples.append(sample)

                except ValueError as error:
                    errors.append(str(error))

    samples_by_kernel: dict[
        str,
        list[RuntimeSample],
    ] = defaultdict(list)

    samples_by_run: dict[
        int,
        list[RuntimeSample],
    ] = defaultdict(list)

    seen_kernel_runs: set[
        tuple[str, int]
    ] = set()

    for sample in samples:
        key = (
            sample.kernel,
            sample.run,
        )

        if key in seen_kernel_runs:
            errors.append(
                f"Duplicate sample for kernel={sample.kernel!r}, "
                f"run={sample.run}."
            )
        else:
            seen_kernel_runs.add(key)

        samples_by_kernel[
            sample.kernel
        ].append(sample)

        samples_by_run[
            sample.run
        ].append(sample)

        if sample.run < 0:
            errors.append(
                f"row {sample.row_number}: run must be "
                f"non-negative."
            )

        if (
            not math.isfinite(
                sample.total_cycles
            )
            or sample.total_cycles <= 0.0
        ):
            errors.append(
                f"row {sample.row_number}: total_cycles "
                f"must be finite and positive."
            )

        if not math.isfinite(sample.checksum):
            errors.append(
                f"row {sample.row_number}: non-finite "
                f"checksum in {sample.kernel}."
            )

        if sample.kernel == "timer_only":
            if sample.dynamic_ffma_count != 0:
                errors.append(
                    f"row {sample.row_number}: timer_only "
                    f"dynamic_ffma_count must be 0, found "
                    f"{sample.dynamic_ffma_count}."
                )

            if sample.cycles_per_ffma is not None:
                warnings.append(
                    f"row {sample.row_number}: timer_only has "
                    "a cycles_per_ffma value; total_cycles is "
                    "used for timer statistics."
                )

        elif sample.kernel in FFMA_KERNELS:
            if sample.dynamic_ffma_count <= 0:
                errors.append(
                    f"row {sample.row_number}: "
                    f"{sample.kernel} dynamic_ffma_count "
                    "must be positive."
                )

            if sample.cycles_per_ffma is None:
                errors.append(
                    f"row {sample.row_number}: "
                    f"{sample.kernel} is missing "
                    "cycles_per_ffma."
                )
            elif (
                not math.isfinite(
                    sample.cycles_per_ffma
                )
                or sample.cycles_per_ffma <= 0.0
            ):
                errors.append(
                    f"row {sample.row_number}: "
                    "cycles_per_ffma must be finite and "
                    "positive."
                )
            elif sample.dynamic_ffma_count > 0:
                expected_cycles_per_ffma = (
                    sample.total_cycles
                    / sample.dynamic_ffma_count
                )

                if not math.isclose(
                    sample.cycles_per_ffma,
                    expected_cycles_per_ffma,
                    rel_tol=1.0e-6,
                    abs_tol=1.0e-9,
                ):
                    errors.append(
                        f"row {sample.row_number}: "
                        f"cycles_per_ffma does not match "
                        f"total_cycles / dynamic_ffma_count "
                        f"for {sample.kernel}. "
                        f"CSV={sample.cycles_per_ffma:.12g}, "
                        f"computed="
                        f"{expected_cycles_per_ffma:.12g}."
                    )

    missing_kernels = [
        kernel
        for kernel in REQUIRED_KERNELS
        if not samples_by_kernel[kernel]
    ]

    if missing_kernels:
        errors.append(
            "Missing runtime groups: "
            + ", ".join(missing_kernels)
        )

    sample_counts = {
        kernel: len(
            samples_by_kernel[kernel]
        )
        for kernel in REQUIRED_KERNELS
    }

    nonzero_sample_counts = {
        count
        for count in sample_counts.values()
        if count > 0
    }

    if len(nonzero_sample_counts) > 1:
        errors.append(
            "Kernel sample counts differ: "
            + ", ".join(
                f"{kernel}={count}"
                for kernel, count
                in sample_counts.items()
            )
        )

    if args.expected_samples is not None:
        for kernel in REQUIRED_KERNELS:
            actual_count = sample_counts[kernel]

            if actual_count != args.expected_samples:
                errors.append(
                    f"{kernel} sample count is "
                    f"{actual_count}; expected "
                    f"{args.expected_samples}."
                )

    dependent_counts = {
        sample.dynamic_ffma_count
        for sample in samples_by_kernel[
            "dependent"
        ]
    }

    independent_counts = {
        sample.dynamic_ffma_count
        for sample in samples_by_kernel[
            "independent_8"
        ]
    }

    if len(dependent_counts) > 1:
        errors.append(
            "dependent dynamic_ffma_count changes "
            "between samples: "
            + ", ".join(
                str(value)
                for value in sorted(
                    dependent_counts
                )
            )
        )

    if len(independent_counts) > 1:
        errors.append(
            "independent_8 dynamic_ffma_count changes "
            "between samples: "
            + ", ".join(
                str(value)
                for value in sorted(
                    independent_counts
                )
            )
        )

    if (
        len(dependent_counts) == 1
        and len(independent_counts) == 1
        and dependent_counts != independent_counts
    ):
        errors.append(
            "dependent and independent_8 use different "
            "dynamic FFMA counts: "
            f"dependent={next(iter(dependent_counts))}, "
            f"independent_8="
            f"{next(iter(independent_counts))}."
        )

    # Each run should contain one row for every kernel.
    for run, run_samples in sorted(
        samples_by_run.items()
    ):
        run_kernels = {
            sample.kernel
            for sample in run_samples
        }

        missing_in_run = (
            set(REQUIRED_KERNELS)
            - run_kernels
        )

        if missing_in_run:
            errors.append(
                f"run {run} is missing kernels: "
                + ", ".join(
                    sorted(missing_in_run)
                )
            )

    timer_values = [
        sample.total_cycles
        for sample in samples_by_kernel[
            "timer_only"
        ]
        if (
            math.isfinite(sample.total_cycles)
            and sample.total_cycles > 0.0
        )
    ]

    dependent_values = [
        sample.cycles_per_ffma
        for sample in samples_by_kernel[
            "dependent"
        ]
        if (
            sample.cycles_per_ffma is not None
            and math.isfinite(
                sample.cycles_per_ffma
            )
            and sample.cycles_per_ffma > 0.0
        )
    ]

    independent_values = [
        sample.cycles_per_ffma
        for sample in samples_by_kernel[
            "independent_8"
        ]
        if (
            sample.cycles_per_ffma is not None
            and math.isfinite(
                sample.cycles_per_ffma
            )
            and sample.cycles_per_ffma > 0.0
        )
    ]

    statistics_by_kernel: dict[
        str,
        StatisticsSummary,
    ] = {}

    if timer_values:
        statistics_by_kernel[
            "timer_only"
        ] = calculate_statistics(
            timer_values
        )

    if dependent_values:
        statistics_by_kernel[
            "dependent"
        ] = calculate_statistics(
            dependent_values
        )

    if independent_values:
        statistics_by_kernel[
            "independent_8"
        ] = calculate_statistics(
            independent_values
        )

    for kernel, summary in (
        statistics_by_kernel.items()
    ):
        if (
            summary.coefficient_of_variation
            > args.max_cv
        ):
            warnings.append(
                f"{kernel} coefficient of variation "
                f"{summary.coefficient_of_variation:.6f} "
                f"exceeds threshold {args.max_cv:.6f}."
            )

        if summary.robust_outlier_count > 0:
            warnings.append(
                f"{kernel} contains "
                f"{summary.robust_outlier_count} "
                "robust statistical outlier(s)."
            )

    median_ratio: float | None = None
    paired_ratios: list[float] = []

    if dependent_values and independent_values:
        dependent_median = statistics.median(
            dependent_values
        )

        independent_median = statistics.median(
            independent_values
        )

        median_ratio = (
            dependent_median
            / independent_median
        )

        if dependent_median <= independent_median:
            warnings.append(
                "Dependent median cycles/FFMA is not "
                "greater than independent-8 median "
                "cycles/FFMA. Check SASS dependencies, "
                "clock placement, GPU clocks, and "
                "measurement stability."
            )

        if median_ratio < args.minimum_ratio:
            warnings.append(
                "Dependent/independent median ratio "
                f"{median_ratio:.6f} is below the "
                f"configured threshold "
                f"{args.minimum_ratio:.6f}."
            )

    dependent_by_run = {
        sample.run: sample
        for sample in samples_by_kernel[
            "dependent"
        ]
        if sample.cycles_per_ffma is not None
    }

    independent_by_run = {
        sample.run: sample
        for sample in samples_by_kernel[
            "independent_8"
        ]
        if sample.cycles_per_ffma is not None
    }

    common_runs = sorted(
        dependent_by_run.keys()
        & independent_by_run.keys()
    )

    for run in common_runs:
        dependent_value = (
            dependent_by_run[
                run
            ].cycles_per_ffma
        )

        independent_value = (
            independent_by_run[
                run
            ].cycles_per_ffma
        )

        if (
            dependent_value is not None
            and independent_value is not None
            and independent_value > 0.0
        ):
            paired_ratios.append(
                dependent_value
                / independent_value
            )

    dependent_first_count = 0
    independent_first_count = 0

    for run_samples in samples_by_run.values():
        ordered = sorted(
            run_samples,
            key=lambda sample: sample.row_order,
        )

        ordered_ffma_kernels = [
            sample.kernel
            for sample in ordered
            if sample.kernel in FFMA_KERNELS
        ]

        if len(ordered_ffma_kernels) >= 2:
            if (
                ordered_ffma_kernels[0]
                == "dependent"
            ):
                dependent_first_count += 1
            elif (
                ordered_ffma_kernels[0]
                == "independent_8"
            ):
                independent_first_count += 1

    if (
        abs(
            dependent_first_count
            - independent_first_count
        )
        > 1
    ):
        warnings.append(
            "Dependent/independent execution order is "
            "unbalanced: "
            f"dependent-first={dependent_first_count}, "
            f"independent-first={independent_first_count}."
        )

    overall_status = (
        "FAIL"
        if errors
        else "WARN"
        if warnings
        else "PASS"
    )

    lines: list[str] = []

    lines.append("[overall]")
    lines.append(
        f"status        : {overall_status}"
    )
    lines.append(
        f"error count   : {len(errors)}"
    )
    lines.append(
        f"warning count : {len(warnings)}"
    )
    lines.append("")

    lines.append("[configuration]")
    lines.append(
        f"input file       : "
        f"{args.input.resolve()}"
    )
    lines.append(
        f"expected samples : "
        f"{args.expected_samples if args.expected_samples is not None else 'not specified'}"
    )
    lines.append(
        f"minimum ratio    : "
        f"{args.minimum_ratio:.6f}"
    )
    lines.append(
        f"maximum CV       : "
        f"{args.max_cv:.6f}"
    )
    lines.append("")

    if "timer_only" in statistics_by_kernel:
        append_statistics(
            lines,
            "timer_only",
            "total cycles",
            statistics_by_kernel[
                "timer_only"
            ],
        )

    if "dependent" in statistics_by_kernel:
        append_statistics(
            lines,
            "dependent",
            "cycles/FFMA",
            statistics_by_kernel[
                "dependent"
            ],
        )

    if (
        "independent_8"
        in statistics_by_kernel
    ):
        append_statistics(
            lines,
            "independent_8",
            "cycles/FFMA",
            statistics_by_kernel[
                "independent_8"
            ],
        )

    lines.append("[sample counts]")

    for kernel in REQUIRED_KERNELS:
        lines.append(
            f"{kernel:<14}: "
            f"{sample_counts[kernel]}"
        )

    lines.append("")

    lines.append("[dynamic FFMA count]")
    lines.append(
        "dependent    : "
        + (
            ", ".join(
                str(value)
                for value in sorted(
                    dependent_counts
                )
            )
            if dependent_counts
            else "unavailable"
        )
    )
    lines.append(
        "independent_8: "
        + (
            ", ".join(
                str(value)
                for value in sorted(
                    independent_counts
                )
            )
            if independent_counts
            else "unavailable"
        )
    )
    lines.append("")

    lines.append("[comparison]")

    if (
        "dependent" in statistics_by_kernel
        and "independent_8"
        in statistics_by_kernel
        and median_ratio is not None
    ):
        dependent_summary = (
            statistics_by_kernel[
                "dependent"
            ]
        )

        independent_summary = (
            statistics_by_kernel[
                "independent_8"
            ]
        )

        lines.append(
            "dependent median      : "
            f"{dependent_summary.median:.9f} "
            "cycles/FFMA"
        )

        lines.append(
            "independent median    : "
            f"{independent_summary.median:.9f} "
            "cycles/FFMA"
        )

        lines.append(
            "median ratio dep/ind  : "
            f"{median_ratio:.9f}"
        )

        lines.append(
            "relation dep > indep  : "
            f"{dependent_summary.median > independent_summary.median}"
        )
    else:
        lines.append(
            "comparison unavailable"
        )

    if paired_ratios:
        paired_summary = calculate_statistics(
            paired_ratios
        )

        lines.append(
            "paired ratio median   : "
            f"{paired_summary.median:.9f}"
        )
        lines.append(
            "paired ratio p05      : "
            f"{paired_summary.percentile_05:.9f}"
        )
        lines.append(
            "paired ratio p95      : "
            f"{paired_summary.percentile_95:.9f}"
        )

    lines.append(
        "dependent first runs   : "
        f"{dependent_first_count}"
    )

    lines.append(
        "independent first runs : "
        f"{independent_first_count}"
    )

    lines.append("")

    lines.append("[errors]")

    if errors:
        lines.extend(
            f"- {error}"
            for error in errors
        )
    else:
        lines.append("none")

    lines.append("")
    lines.append("[warnings]")

    if warnings:
        lines.extend(
            f"- {warning}"
            for warning in warnings
        )
    else:
        lines.append("none")

    write_report(
        args.output,
        lines,
    )

    print(
        args.output.read_text(
            encoding="utf-8"
        ),
        end="",
    )

    if errors:
        return 3

    if args.fail_on_warning and warnings:
        return 4

    return 0


if __name__ == "__main__":
    raise SystemExit(main())