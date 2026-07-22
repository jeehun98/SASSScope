#!/usr/bin/env python3
"""Minimal structural validator for cuobjdump --dump-sass output."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

FUNCTION_RE = re.compile(r"^\s*Function\s*:\s*(\S+)", re.MULTILINE)
INSTRUCTION_RE = re.compile(
    r"/\*([0-9a-fA-F]+)\*/\s+"
    r"(?:@!?[A-Za-z0-9_.]+\s+)?"
    r"([A-Z][A-Z0-9_.]*)\s*(.*?)\s*;"
)
REGISTER_RE = re.compile(r"\bR(\d+)(?:\.reuse)?\b")
CLOCK_REGISTER_RE = re.compile(r"\bSR_CLOCK(?:LO|HI|64)?\b", re.IGNORECASE)

EXPECTED_FUNCTIONS = (
    "probe_timer_only",
    "probe_dependent_ffma",
    "probe_independent_ffma_8",
)

FLOAT_OPCODES = {
    "FADD", "FMUL", "FFMA", "FMNMX", "FSEL", "MUFU",
    "DADD", "DMUL", "DFMA", "HADD2", "HMUL2", "HFMA2",
}


@dataclass(frozen=True)
class Instruction:
    address: str
    opcode: str
    operands: str
    text: str


def base_opcode(opcode: str) -> str:
    return opcode.split(".", 1)[0]


def split_functions(text: str) -> dict[str, str]:
    matches = list(FUNCTION_RE.finditer(text))
    return {
        match.group(1): text[
            match.start(): matches[index + 1].start()
            if index + 1 < len(matches)
            else len(text)
        ]
        for index, match in enumerate(matches)
    }


def parse_instructions(block: str) -> list[Instruction]:
    return [
        Instruction(
            address=match.group(1).lower(),
            opcode=match.group(2),
            operands=match.group(3).strip(),
            text=match.group(0).strip(),
        )
        for match in INSTRUCTION_RE.finditer(block)
    ]


def split_operands(operands: str) -> list[str]:
    return [part.strip() for part in operands.split(",") if part.strip()]


def normalize_register(token: str) -> str | None:
    match = REGISTER_RE.search(token)
    return f"R{match.group(1)}" if match else None


def destination_register(instruction: Instruction) -> str | None:
    operands = split_operands(instruction.operands)
    return normalize_register(operands[0]) if operands else None


def source_registers(instruction: Instruction) -> list[str]:
    operands = split_operands(instruction.operands)
    return [
        register
        for operand in operands[1:]
        if (register := normalize_register(operand)) is not None
    ]


def is_clock_read(instruction: Instruction) -> bool:
    return (
        base_opcode(instruction.opcode) == "CS2R"
        and CLOCK_REGISTER_RE.search(instruction.operands) is not None
    )


def classify_memory_operation(instruction: Instruction) -> str | None:
    opcode = base_opcode(instruction.opcode)

    if opcode in {"LDG", "STG"}:
        return "global"
    if opcode in {"LDL", "STL"}:
        return "local"
    if opcode in {"LDS", "STS"}:
        return "shared"
    if opcode in {"LDC", "ULDC"}:
        return "constant"
    if opcode.startswith(("LD", "ST", "ATOM", "RED")):
        return "other"
    return None


def first_seen_unique(values: list[str]) -> list[str]:
    return list(dict.fromkeys(values))


def normalize_pattern(registers: list[str]) -> list[int]:
    mapping: dict[str, int] = {}
    result: list[int] = []
    for register in registers:
        mapping.setdefault(register, len(mapping))
        result.append(mapping[register])
    return result


def reuse_distances(registers: list[str]) -> dict[str, list[int]]:
    positions: dict[str, list[int]] = {}
    for index, register in enumerate(registers):
        positions.setdefault(register, []).append(index)
    return {
        register: [right - left for left, right in zip(indices, indices[1:])]
        for register, indices in positions.items()
    }


def status_for(errors: list[str], warnings: list[str]) -> str:
    return "FAIL" if errors else "WARN" if warnings else "PASS"


def analyze_function(
    name: str,
    block: str,
    expected_ffma: int,
    expected_accumulators: int,
) -> dict[str, object]:
    instructions = parse_instructions(block)
    errors: list[str] = []
    warnings: list[str] = []

    clock_indices = [
        index for index, instruction in enumerate(instructions)
        if is_clock_read(instruction)
    ]

    measured_region: list[Instruction] = []
    start_address: str | None = None
    end_address: str | None = None

    if len(clock_indices) != 2:
        errors.append(
            f"Expected exactly 2 clock-register CS2R instructions, found {len(clock_indices)}."
        )
    else:
        start_index, end_index = clock_indices
        if start_index >= end_index:
            errors.append("The starting clock instruction does not precede the ending clock instruction.")
        else:
            measured_region = instructions[start_index + 1:end_index]
            start_address = instructions[start_index].address
            end_address = instructions[end_index].address

    function_ffma = [
        instruction for instruction in instructions
        if base_opcode(instruction.opcode) == "FFMA"
    ]
    measured_ffma = [
        instruction for instruction in measured_region
        if base_opcode(instruction.opcode) == "FFMA"
    ]

    accumulators: list[str] = []
    self_dependent_count = 0

    for instruction in measured_ffma:
        destination = destination_register(instruction)
        sources = source_registers(instruction)
        if destination is None or not sources:
            errors.append(f"Unable to parse measured FFMA at 0x{instruction.address}.")
            continue
        accumulators.append(destination)
        if destination in sources:
            self_dependent_count += 1

    accumulator_registers = first_seen_unique(accumulators)
    counts = Counter(accumulators)
    chain_lengths = [counts[register] for register in accumulator_registers]
    normalized = normalize_pattern(accumulators)
    distances = reuse_distances(accumulators)
    unique_reuse_distances = sorted({
        distance for values in distances.values() for distance in values
    })

    accumulator_set = set(accumulator_registers)
    cross_chain_count = 0
    for instruction in measured_ffma:
        destination = destination_register(instruction)
        if destination is None:
            continue
        if any(
            source in accumulator_set and source != destination
            for source in source_registers(instruction)
        ):
            cross_chain_count += 1

    first_ffma_index = next(
        (
            index for index, instruction in enumerate(measured_region)
            if base_opcode(instruction.opcode) == "FFMA"
        ),
        None,
    )
    last_ffma_index = next(
        (
            index for index in range(len(measured_region) - 1, -1, -1)
            if base_opcode(measured_region[index].opcode) == "FFMA"
        ),
        None,
    )

    setup = measured_region[:first_ffma_index] if first_ffma_index is not None else []
    setup = [instruction for instruction in setup if base_opcode(instruction.opcode) != "NOP"]
    accumulator_setup_count = sum(
        destination_register(instruction) in accumulator_set
        for instruction in setup
    )

    tail = measured_region[last_ffma_index + 1:] if last_ffma_index is not None else []
    unexpected_tail_count = 0
    for instruction in tail:
        opcode = base_opcode(instruction.opcode)
        destination = destination_register(instruction)
        if (
            classify_memory_operation(instruction) is not None
            or opcode in FLOAT_OPCODES
            or destination in accumulator_set
        ):
            unexpected_tail_count += 1

    memory_counts = Counter(
        memory_class
        for instruction in measured_region
        if (memory_class := classify_memory_operation(instruction)) is not None
    )
    hard_memory_count = sum(
        memory_counts[memory_class]
        for memory_class in ("global", "local", "shared", "other")
    )

    round_robin_valid: bool | None = None
    expected_reuse_distance: int | None = None

    if name == "probe_timer_only":
        if measured_region:
            errors.append(
                f"Timer-only measured region must be empty, found {len(measured_region)} instructions."
            )

    else:
        if len(measured_ffma) != expected_ffma:
            errors.append(
                f"Expected {expected_ffma} measured FFMA instructions, found {len(measured_ffma)}."
            )
        if self_dependent_count != len(measured_ffma):
            errors.append("Not every measured FFMA is self-dependent on its destination accumulator.")
        if len(function_ffma) != len(measured_ffma):
            warnings.append("Additional FFMA instructions exist outside the measured region.")
        if hard_memory_count:
            errors.append("Global, local, shared, atomic, or other data-memory operations exist inside the measured region.")
        if memory_counts["constant"]:
            warnings.append("Constant or uniform loads contribute fixed setup overhead inside the measured region.")
        if accumulator_setup_count:
            errors.append("Accumulator registers are initialized after the starting clock.")
        if setup:
            warnings.append("Non-FFMA setup instructions appear before the first measured FFMA.")
        if unexpected_tail_count:
            warnings.append("Suspicious instructions appear after the final FFMA and before the ending clock.")
        if cross_chain_count:
            errors.append("Cross-chain accumulator dependencies were detected.")

    if name == "probe_dependent_ffma":
        expected_reuse_distance = 1
        if len(accumulator_registers) != 1:
            errors.append(f"Expected 1 accumulator chain, found {len(accumulator_registers)}.")
        if chain_lengths != [expected_ffma]:
            errors.append(f"Expected dependent chain length [{expected_ffma}], found {chain_lengths}.")
        if unique_reuse_distances not in ([], [1]):
            errors.append(f"Expected reuse distance 1, found {unique_reuse_distances}.")

    elif name == "probe_independent_ffma_8":
        expected_reuse_distance = expected_accumulators
        if expected_ffma % expected_accumulators != 0:
            errors.append("Expected FFMA count must be divisible by the accumulator count.")
        else:
            expected_chain_length = expected_ffma // expected_accumulators
            expected_lengths = [expected_chain_length] * expected_accumulators
            if chain_lengths != expected_lengths:
                errors.append(f"Expected chain lengths {expected_lengths}, found {chain_lengths}.")

        if len(accumulator_registers) != expected_accumulators:
            errors.append(
                f"Expected {expected_accumulators} accumulator chains, found {len(accumulator_registers)}."
            )

        expected_pattern = [index % expected_accumulators for index in range(expected_ffma)]
        round_robin_valid = normalized == expected_pattern
        if not round_robin_valid:
            errors.append("Independent accumulators do not follow the required round-robin order.")
        if unique_reuse_distances not in ([], [expected_accumulators]):
            errors.append(
                f"Expected reuse distance {expected_accumulators}, found {unique_reuse_distances}."
            )

    measured_opcode_histogram = dict(sorted(Counter(
        base_opcode(instruction.opcode) for instruction in measured_region
    ).items()))

    return {
        "name": name,
        "status": status_for(errors, warnings),
        "clock_read_count": len(clock_indices),
        "timer_start_address": start_address,
        "timer_end_address": end_address,
        "measured_instruction_count": len(measured_region) if len(clock_indices) == 2 else None,
        "measured_opcode_histogram": measured_opcode_histogram,
        "function_ffma_count": len(function_ffma),
        "measured_ffma_count": len(measured_ffma),
        "self_dependent_ffma_count": self_dependent_count,
        "accumulator_registers": accumulator_registers,
        "dependency_chain_count": len(accumulator_registers),
        "chain_lengths": chain_lengths,
        "expected_reuse_distance": expected_reuse_distance,
        "observed_reuse_distances": unique_reuse_distances,
        "round_robin_valid": round_robin_valid,
        "cross_chain_dependency_count": cross_chain_count,
        "hard_memory_operation_count": hard_memory_count,
        "constant_load_count": memory_counts["constant"],
        "setup_instruction_count": len(setup),
        "accumulator_setup_instruction_count": accumulator_setup_count,
        "unexpected_tail_instruction_count": unexpected_tail_count,
        "errors": errors,
        "warnings": warnings,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate FFMA dependency structure in cuobjdump SASS output."
    )
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--expected-static-ffma", type=int, default=32)
    parser.add_argument("--expected-independent-accumulators", type=int, default=8)
    parser.add_argument("--fail-on-warning", action="store_true")
    args = parser.parse_args()

    if args.expected_static_ffma <= 0:
        parser.error("--expected-static-ffma must be positive")
    if args.expected_independent_accumulators <= 0:
        parser.error("--expected-independent-accumulators must be positive")
    if not args.input.is_file():
        print(f"ERROR: input file was not found: {args.input}", file=sys.stderr)
        return 2

    blocks = split_functions(args.input.read_text(encoding="utf-8", errors="replace"))
    missing = [name for name in EXPECTED_FUNCTIONS if name not in blocks]
    if missing:
        print("ERROR: missing functions in SASS: " + ", ".join(missing), file=sys.stderr)
        return 2

    functions = [
        analyze_function(
            name,
            blocks[name],
            args.expected_static_ffma,
            args.expected_independent_accumulators,
        )
        for name in EXPECTED_FUNCTIONS
    ]

    by_name = {function["name"]: function for function in functions}
    dependent = by_name["probe_dependent_ffma"]
    independent = by_name["probe_independent_ffma_8"]

    comparison_errors: list[str] = []
    if dependent["measured_instruction_count"] != independent["measured_instruction_count"]:
        comparison_errors.append("Measured instruction counts differ between dependent and independent probes.")
    if dependent["measured_opcode_histogram"] != independent["measured_opcode_histogram"]:
        comparison_errors.append("Measured opcode histograms differ between dependent and independent probes.")

    total_errors = sum(len(function["errors"]) for function in functions) + len(comparison_errors)
    total_warnings = sum(len(function["warnings"]) for function in functions)
    overall_status = "FAIL" if total_errors else "WARN" if total_warnings else "PASS"

    document = {
        "schema_version": 3,
        "input_file": str(args.input.resolve()),
        "configuration": {
            "expected_static_ffma": args.expected_static_ffma,
            "expected_independent_accumulators": args.expected_independent_accumulators,
            "fail_on_warning": args.fail_on_warning,
        },
        "overall_status": overall_status,
        "error_count": total_errors,
        "warning_count": total_warnings,
        "probe_comparison": {
            "measured_instruction_count_equal": (
                dependent["measured_instruction_count"]
                == independent["measured_instruction_count"]
            ),
            "measured_opcode_histogram_equal": (
                dependent["measured_opcode_histogram"]
                == independent["measured_opcode_histogram"]
            ),
            "errors": comparison_errors,
        },
        "functions": functions,
    }

    args.output_dir.mkdir(parents=True, exist_ok=True)
    output_path = args.output_dir / "sass_summary.json"
    output_path.write_text(
        json.dumps(document, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    print(f"Wrote: {output_path}")
    print(f"Status: {overall_status}")
    print(f"Errors: {total_errors}")
    print(f"Warnings: {total_warnings}")

    if total_errors:
        return 3
    if args.fail_on_warning and total_warnings:
        return 4
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
