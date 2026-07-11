#!/usr/bin/env python3
"""Validate raw runtime CSV and summarize the dependent/independent relation."""

from __future__ import annotations

import argparse
import csv
import math
import statistics
from collections import defaultdict
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    groups: dict[str, list[float]] = defaultdict(list)
    checksums: dict[str, list[float]] = defaultdict(list)

    with args.input.open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            kernel = row["kernel"]
            checksums[kernel].append(float(row["checksum"]))
            if row["cycles_per_instruction"]:
                groups[kernel].append(float(row["cycles_per_instruction"]))
            else:
                groups[kernel].append(float(row["total_cycles"]))

    required = {"timer_only", "dependent", "independent_8"}
    missing = required - groups.keys()
    if missing:
        raise SystemExit(f"Missing runtime groups: {sorted(missing)}")

    lines: list[str] = []
    for name in ["timer_only", "dependent", "independent_8"]:
        values = groups[name]
        lines.append(f"[{name}]")
        lines.append(f"samples : {len(values)}")
        lines.append(f"min     : {min(values):.9f}")
        lines.append(f"median  : {statistics.median(values):.9f}")
        lines.append(f"mean    : {statistics.fmean(values):.9f}")
        lines.append(f"max     : {max(values):.9f}")
        lines.append(f"pstdev  : {statistics.pstdev(values):.9f}")
        lines.append("")

    dependent = statistics.median(groups["dependent"])
    independent = statistics.median(groups["independent_8"])
    ratio = dependent / independent

    warnings: list[str] = []
    if not dependent > independent:
        warnings.append(
            "Dependent median is not greater than independent median. "
            "Check SASS dependencies, clock placement, and GPU clock stability."
        )
    if ratio < 1.20:
        warnings.append(
            "Dependent/independent ratio is below 1.20; the probe did not expose a strong dependency effect."
        )
    for kernel, values in checksums.items():
        if not all(math.isfinite(value) for value in values):
            warnings.append(f"Non-finite checksum detected in {kernel}.")

    lines.append("[comparison]")
    lines.append(f"dependent median      : {dependent:.9f} cycles/instruction")
    lines.append(f"independent median    : {independent:.9f} cycles/instruction")
    lines.append(f"median ratio          : {ratio:.9f}")
    lines.append(f"relation dep > indep  : {dependent > independent}")
    lines.append("")

    if warnings:
        lines.append("[warnings]")
        lines.extend(f"- {warning}" for warning in warnings)
    else:
        lines.append("[warnings]")
        lines.append("none")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(args.output.read_text(encoding="utf-8"), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
