#!/usr/bin/env python3
"""
Static structure checker for cuobjdump --dump-sass output.

The analyzer verifies:

- timer boundaries using CS2R clock-register operands
- FFMA count inside the measured region
- FFMA self-dependency
- dependent-chain structure
- independent accumulator count
- accumulator chain lengths
- independent-8 round-robin ordering
- accumulator reuse distances
- cross-chain dependencies
- memory operations inside the measured region
- accumulator initialization after the starting clock
- suspicious operations before the ending clock

The input should normally be SASS extracted from the actual runtime executable:

    cuobjdump --dump-sass build/probe_ffma.exe

Structural validation errors cause a non-zero exit code.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable


FUNCTION_RE = re.compile(
    r"^\s*Function\s*:\s*(\S+)",
    re.MULTILINE,
)

INSTRUCTION_RE = re.compile(
    r"/\*([0-9a-fA-F]+)\*/\s+"
    r"(?:@!?[A-Za-z0-9_.]+\s+)?"
    r"([A-Z][A-Z0-9_.]*)"
    r"\s*(.*?)\s*;"
)

REGISTER_RE = re.compile(
    r"\bR(\d+)(?:\.reuse)?\b"
)

CLOCK_REGISTER_RE = re.compile(
    r"\bSR_CLOCK(?:LO|HI|64)?\b",
    re.IGNORECASE,
)


EXPECTED_FUNCTIONS = (
    "probe_timer_only",
    "probe_dependent_ffma",
    "probe_independent_ffma_8",
)

MEASURED_PROBE_FUNCTIONS = {
    "probe_dependent_ffma",
    "probe_independent_ffma_8",
}

FLOAT_ARITHMETIC_OPCODES = {
    "FADD",
    "FMUL",
    "FFMA",
    "FMNMX",
    "FSEL",
    "MUFU",
    "DADD",
    "DMUL",
    "DFMA",
    "HADD2",
    "HMUL2",
    "HFMA2",
}


@dataclass(frozen=True)
class Instruction:
    address: str
    opcode: str
    operands: str
    text: str


@dataclass
class FunctionSummary:
    name: str
    status: str

    instruction_count: int
    opcode_histogram: dict[str, int]
    base_opcode_histogram: dict[str, int]

    cs2r_count: int
    clock_read_count: int
    clock_read_addresses: list[str]

    timer_region_found: bool
    timer_start_address: str | None
    timer_end_address: str | None
    measured_region_instruction_count: int | None

    function_ffma_count: int
    measured_region_ffma_count: int
    self_dependent_ffma_count: int

    accumulator_registers: list[str]
    accumulator_use_counts: dict[str, int]
    dependency_chain_count: int
    static_chain_lengths: list[int]

    raw_accumulator_pattern: list[str]
    normalized_accumulator_pattern: list[int]

    reuse_distances: dict[str, list[int]]
    expected_reuse_distance: int | None
    round_robin_valid: bool | None

    cross_chain_dependencies: list[str]

    measured_region_memory_ops: list[str]
    measured_region_global_memory_ops: list[str]
    measured_region_local_memory_ops: list[str]
    measured_region_shared_memory_ops: list[str]
    measured_region_constant_loads: list[str]
    measured_region_other_memory_ops: list[str]

    setup_ops_after_start_clock: list[str]
    accumulator_setup_ops_after_start_clock: list[str]

    instructions_after_last_ffma_before_end_clock: list[str]
    unexpected_tail_ops: list[str]

    timer_start_window: list[str]
    timer_end_window: list[str]

    errors: list[str]
    warnings: list[str]


@dataclass
class FunctionAnalysis:
    summary: FunctionSummary
    instructions: list[Instruction]
    measured_region: list[Instruction]
    start_index: int | None
    end_index: int | None


def base_opcode(opcode: str) -> str:
    """Return an opcode without modifiers such as .FTZ, .E, or .64."""
    return opcode.split(".", 1)[0]


def split_functions(text: str) -> dict[str, str]:
    matches = list(FUNCTION_RE.finditer(text))
    blocks: dict[str, str] = {}

    for index, match in enumerate(matches):
        start = match.start()
        end = (
            matches[index + 1].start()
            if index + 1 < len(matches)
            else len(text)
        )

        blocks[match.group(1)] = text[start:end]

    return blocks


def parse_instructions(block: str) -> list[Instruction]:
    instructions: list[Instruction] = []

    for match in INSTRUCTION_RE.finditer(block):
        instructions.append(
            Instruction(
                address=match.group(1).lower(),
                opcode=match.group(2),
                operands=match.group(3).strip(),
                text=match.group(0).strip(),
            )
        )

    return instructions


def split_operands(operands: str) -> list[str]:
    return [
        part.strip()
        for part in operands.split(",")
        if part.strip()
    ]


def normalize_register(token: str) -> str | None:
    match = REGISTER_RE.search(token)

    if match is None:
        return None

    return f"R{match.group(1)}"


def destination_register(
    instruction: Instruction,
) -> str | None:
    operands = split_operands(instruction.operands)

    if not operands:
        return None

    return normalize_register(operands[0])


def source_registers(
    instruction: Instruction,
) -> list[str]:
    operands = split_operands(instruction.operands)

    if len(operands) < 2:
        return []

    registers: list[str] = []

    for operand in operands[1:]:
        register = normalize_register(operand)

        if register is not None:
            registers.append(register)

    return registers


def is_clock_read(instruction: Instruction) -> bool:
    return (
        base_opcode(instruction.opcode) == "CS2R"
        and CLOCK_REGISTER_RE.search(instruction.operands) is not None
    )


def classify_memory_operation(
    instruction: Instruction,
) -> str | None:
    opcode = base_opcode(instruction.opcode)

    if opcode.startswith(("LDG", "STG")):
        return "global"

    if opcode.startswith(("LDL", "STL")):
        return "local"

    if opcode.startswith(("LDS", "STS")):
        return "shared"

    if opcode.startswith(("LDC", "ULDC")):
        return "constant"

    if opcode.startswith(("LD", "ST", "ATOM", "RED")):
        return "other"

    return None


def instruction_window(
    instructions: list[Instruction],
    center: int,
    radius: int,
) -> list[str]:
    begin = max(0, center - radius)
    end = min(len(instructions), center + radius + 1)

    return [
        instruction.text
        for instruction in instructions[begin:end]
    ]


def first_seen_unique(values: Iterable[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []

    for value in values:
        if value in seen:
            continue

        seen.add(value)
        result.append(value)

    return result


def normalize_accumulator_pattern(
    registers: list[str],
) -> list[int]:
    mapping: dict[str, int] = {}
    normalized: list[int] = []

    for register in registers:
        if register not in mapping:
            mapping[register] = len(mapping)

        normalized.append(mapping[register])

    return normalized


def calculate_reuse_distances(
    registers: list[str],
) -> dict[str, list[int]]:
    positions: dict[str, list[int]] = {}

    for index, register in enumerate(registers):
        positions.setdefault(register, []).append(index)

    distances: dict[str, list[int]] = {}

    for register, indices in positions.items():
        distances[register] = [
            indices[index] - indices[index - 1]
            for index in range(1, len(indices))
        ]

    return distances


def determine_status(
    errors: list[str],
    warnings: list[str],
) -> str:
    if errors:
        return "FAIL"

    if warnings:
        return "WARN"

    return "PASS"


def summarize_function(
    name: str,
    block: str,
    expected_static_ffma: int,
    expected_independent_accumulators: int,
    timer_window_radius: int,
) -> FunctionAnalysis:
    instructions = parse_instructions(block)

    opcode_histogram = Counter(
        instruction.opcode
        for instruction in instructions
    )

    base_opcode_histogram = Counter(
        base_opcode(instruction.opcode)
        for instruction in instructions
    )

    errors: list[str] = []
    warnings: list[str] = []

    clock_indices = [
        index
        for index, instruction in enumerate(instructions)
        if is_clock_read(instruction)
    ]

    timer_region_found = len(clock_indices) >= 2

    start_index: int | None = None
    end_index: int | None = None

    measured_region: list[Instruction] = []
    timer_start_window: list[str] = []
    timer_end_window: list[str] = []

    if len(clock_indices) != 2:
        errors.append(
            "Expected exactly 2 clock-register CS2R instructions, "
            f"found {len(clock_indices)}."
        )

    if timer_region_found:
        start_index = clock_indices[0]
        end_index = clock_indices[-1]

        if start_index >= end_index:
            errors.append(
                "The starting clock instruction does not precede "
                "the ending clock instruction."
            )
        else:
            measured_region = instructions[
                start_index + 1 : end_index
            ]

            timer_start_window = instruction_window(
                instructions,
                start_index,
                timer_window_radius,
            )

            timer_end_window = instruction_window(
                instructions,
                end_index,
                timer_window_radius,
            )
    else:
        errors.append(
            "Unable to identify a complete timer region."
        )

    function_ffma_instructions = [
        instruction
        for instruction in instructions
        if base_opcode(instruction.opcode) == "FFMA"
    ]

    measured_ffma_instructions = [
        instruction
        for instruction in measured_region
        if base_opcode(instruction.opcode) == "FFMA"
    ]

    raw_accumulator_pattern: list[str] = []
    self_dependent_ffma_count = 0
    invalid_ffma_operands: list[str] = []

    for instruction in measured_ffma_instructions:
        operands = split_operands(instruction.operands)

        if len(operands) < 2:
            invalid_ffma_operands.append(instruction.text)
            raw_accumulator_pattern.append(
                f"<invalid:{instruction.address}>"
            )
            continue

        destination = normalize_register(operands[0])
        first_source = normalize_register(operands[1])

        if destination is None or first_source is None:
            invalid_ffma_operands.append(instruction.text)
            raw_accumulator_pattern.append(
                f"<invalid:{instruction.address}>"
            )
            continue

        raw_accumulator_pattern.append(destination)

        if destination == first_source:
            self_dependent_ffma_count += 1

    if invalid_ffma_operands:
        errors.append(
            "Unable to parse destination and first source registers "
            f"for {len(invalid_ffma_operands)} measured FFMA instructions."
        )

    valid_accumulator_pattern = [
        register
        for register in raw_accumulator_pattern
        if not register.startswith("<invalid:")
    ]

    accumulator_registers = first_seen_unique(
        valid_accumulator_pattern
    )

    accumulator_counts = Counter(
        valid_accumulator_pattern
    )

    accumulator_use_counts = {
        register: accumulator_counts[register]
        for register in accumulator_registers
    }

    static_chain_lengths = [
        accumulator_use_counts[register]
        for register in accumulator_registers
    ]

    normalized_accumulator_pattern = (
        normalize_accumulator_pattern(
            valid_accumulator_pattern
        )
    )

    reuse_distances = calculate_reuse_distances(
        valid_accumulator_pattern
    )

    accumulator_set = set(accumulator_registers)

    cross_chain_dependencies: list[str] = []

    for instruction in measured_ffma_instructions:
        destination = destination_register(instruction)

        if destination is None:
            continue

        foreign_accumulator_sources = [
            register
            for register in source_registers(instruction)
            if (
                register in accumulator_set
                and register != destination
            )
        ]

        if foreign_accumulator_sources:
            cross_chain_dependencies.append(
                f"{instruction.text} "
                f"[foreign accumulator sources: "
                f"{', '.join(foreign_accumulator_sources)}]"
            )

    first_ffma_index = next(
        (
            index
            for index, instruction in enumerate(measured_region)
            if base_opcode(instruction.opcode) == "FFMA"
        ),
        None,
    )

    last_ffma_index = next(
        (
            index
            for index in range(
                len(measured_region) - 1,
                -1,
                -1,
            )
            if (
                base_opcode(
                    measured_region[index].opcode
                )
                == "FFMA"
            )
        ),
        None,
    )

    setup_instructions: list[Instruction] = []

    if first_ffma_index is not None:
        setup_instructions = measured_region[
            :first_ffma_index
        ]

    setup_ops_after_start_clock = [
        instruction.text
        for instruction in setup_instructions
        if base_opcode(instruction.opcode) != "NOP"
    ]

    accumulator_setup_ops_after_start_clock = [
        instruction.text
        for instruction in setup_instructions
        if destination_register(instruction) in accumulator_set
    ]

    tail_instructions: list[Instruction] = []

    if last_ffma_index is not None:
        tail_instructions = measured_region[
            last_ffma_index + 1 :
        ]

    instructions_after_last_ffma = [
        instruction.text
        for instruction in tail_instructions
    ]

    unexpected_tail_ops: list[str] = []

    for instruction in tail_instructions:
        opcode = base_opcode(instruction.opcode)
        destination = destination_register(instruction)

        if classify_memory_operation(instruction) is not None:
            unexpected_tail_ops.append(instruction.text)
            continue

        if opcode in FLOAT_ARITHMETIC_OPCODES:
            unexpected_tail_ops.append(instruction.text)
            continue

        if (
            destination is not None
            and destination in accumulator_set
        ):
            unexpected_tail_ops.append(instruction.text)

    memory_groups: dict[str, list[str]] = {
        "global": [],
        "local": [],
        "shared": [],
        "constant": [],
        "other": [],
    }

    for instruction in measured_region:
        memory_class = classify_memory_operation(instruction)

        if memory_class is not None:
            memory_groups[memory_class].append(
                instruction.text
            )

    measured_region_memory_ops = [
        instruction
        for memory_class in (
            "global",
            "local",
            "shared",
            "constant",
            "other",
        )
        for instruction in memory_groups[memory_class]
    ]

    round_robin_valid: bool | None = None
    expected_reuse_distance: int | None = None

    if name == "probe_timer_only":
        if measured_ffma_instructions:
            errors.append(
                "Timer-only kernel contains FFMA instructions "
                "inside the measured region."
            )

    elif name == "probe_dependent_ffma":
        if len(measured_ffma_instructions) != expected_static_ffma:
            errors.append(
                f"Expected {expected_static_ffma} measured-region "
                f"FFMA instructions, found "
                f"{len(measured_ffma_instructions)}."
            )

        if (
            self_dependent_ffma_count
            != len(measured_ffma_instructions)
        ):
            errors.append(
                "Not every measured FFMA reads and writes the same "
                "accumulator register."
            )

        if len(accumulator_registers) != 1:
            errors.append(
                "Expected exactly 1 dependent accumulator register, "
                f"found {len(accumulator_registers)}: "
                f"{accumulator_registers}."
            )

        if (
            len(accumulator_registers) == 1
            and static_chain_lengths != [expected_static_ffma]
        ):
            errors.append(
                "Dependent chain length does not match the expected "
                f"value {expected_static_ffma}: "
                f"{static_chain_lengths}."
            )

        if (
            normalized_accumulator_pattern
            and any(
                value != 0
                for value in normalized_accumulator_pattern
            )
        ):
            errors.append(
                "Dependent FFMA instructions do not form one "
                "continuous accumulator chain."
            )

    elif name == "probe_independent_ffma_8":
        expected_reuse_distance = (
            expected_independent_accumulators
        )

        if (
            expected_static_ffma
            % expected_independent_accumulators
            != 0
        ):
            errors.append(
                "Analyzer configuration is invalid: expected static "
                "FFMA count must be divisible by the expected "
                "independent accumulator count."
            )

        if len(measured_ffma_instructions) != expected_static_ffma:
            errors.append(
                f"Expected {expected_static_ffma} measured-region "
                f"FFMA instructions, found "
                f"{len(measured_ffma_instructions)}."
            )

        if (
            self_dependent_ffma_count
            != len(measured_ffma_instructions)
        ):
            errors.append(
                "Not every independent FFMA reads and writes its own "
                "accumulator register."
            )

        if (
            len(accumulator_registers)
            != expected_independent_accumulators
        ):
            errors.append(
                f"Expected {expected_independent_accumulators} "
                "independent accumulator registers, found "
                f"{len(accumulator_registers)}: "
                f"{accumulator_registers}."
            )

        if (
            expected_static_ffma
            % expected_independent_accumulators
            == 0
        ):
            expected_chain_length = (
                expected_static_ffma
                // expected_independent_accumulators
            )

            expected_chain_lengths = [
                expected_chain_length
            ] * expected_independent_accumulators

            if static_chain_lengths != expected_chain_lengths:
                errors.append(
                    "Independent chain lengths do not match the "
                    f"expected structure {expected_chain_lengths}: "
                    f"{static_chain_lengths}."
                )

        expected_pattern = [
            index % expected_independent_accumulators
            for index in range(expected_static_ffma)
        ]

        round_robin_valid = (
            normalized_accumulator_pattern
            == expected_pattern
        )

        if not round_robin_valid:
            errors.append(
                "Independent accumulator ordering is not the expected "
                f"{expected_independent_accumulators}-way round-robin "
                "pattern."
            )

        invalid_reuse_registers: list[str] = []

        for register, distances in reuse_distances.items():
            if any(
                distance != expected_reuse_distance
                for distance in distances
            ):
                invalid_reuse_registers.append(register)

        if invalid_reuse_registers:
            errors.append(
                "Unexpected accumulator reuse distance for: "
                + ", ".join(invalid_reuse_registers)
            )

    if name in MEASURED_PROBE_FUNCTIONS:
        if len(function_ffma_instructions) != len(
            measured_ffma_instructions
        ):
            warnings.append(
                "Additional FFMA instructions exist outside the "
                "measured timer region."
            )

        if measured_region_memory_ops:
            errors.append(
                "Memory instructions were found inside the measured "
                "region. Check for spills, constant loads, or setup "
                "traffic."
            )

        if accumulator_setup_ops_after_start_clock:
            errors.append(
                "One or more accumulator registers are written after "
                "the starting clock and before the first FFMA."
            )

        if setup_ops_after_start_clock:
            warnings.append(
                "Non-FFMA instructions appear after the starting "
                "clock and before the first FFMA. Inspect the timer "
                "start window."
            )

        if unexpected_tail_ops:
            warnings.append(
                "Suspicious instructions appear after the final FFMA "
                "and before the ending clock."
            )

        if cross_chain_dependencies:
            errors.append(
                "Cross-chain accumulator dependencies were detected "
                "inside measured FFMA instructions."
            )

    status = determine_status(
        errors,
        warnings,
    )

    summary = FunctionSummary(
        name=name,
        status=status,

        instruction_count=len(instructions),
        opcode_histogram=dict(
            sorted(opcode_histogram.items())
        ),
        base_opcode_histogram=dict(
            sorted(base_opcode_histogram.items())
        ),

        cs2r_count=base_opcode_histogram.get(
            "CS2R",
            0,
        ),
        clock_read_count=len(clock_indices),
        clock_read_addresses=[
            instructions[index].address
            for index in clock_indices
        ],

        timer_region_found=timer_region_found,
        timer_start_address=(
            instructions[start_index].address
            if start_index is not None
            else None
        ),
        timer_end_address=(
            instructions[end_index].address
            if end_index is not None
            else None
        ),
        measured_region_instruction_count=(
            len(measured_region)
            if timer_region_found
            else None
        ),

        function_ffma_count=len(
            function_ffma_instructions
        ),
        measured_region_ffma_count=len(
            measured_ffma_instructions
        ),
        self_dependent_ffma_count=(
            self_dependent_ffma_count
        ),

        accumulator_registers=accumulator_registers,
        accumulator_use_counts=accumulator_use_counts,
        dependency_chain_count=len(
            accumulator_registers
        ),
        static_chain_lengths=static_chain_lengths,

        raw_accumulator_pattern=(
            raw_accumulator_pattern
        ),
        normalized_accumulator_pattern=(
            normalized_accumulator_pattern
        ),

        reuse_distances=reuse_distances,
        expected_reuse_distance=(
            expected_reuse_distance
        ),
        round_robin_valid=round_robin_valid,

        cross_chain_dependencies=(
            cross_chain_dependencies
        ),

        measured_region_memory_ops=(
            measured_region_memory_ops
        ),
        measured_region_global_memory_ops=(
            memory_groups["global"]
        ),
        measured_region_local_memory_ops=(
            memory_groups["local"]
        ),
        measured_region_shared_memory_ops=(
            memory_groups["shared"]
        ),
        measured_region_constant_loads=(
            memory_groups["constant"]
        ),
        measured_region_other_memory_ops=(
            memory_groups["other"]
        ),

        setup_ops_after_start_clock=(
            setup_ops_after_start_clock
        ),
        accumulator_setup_ops_after_start_clock=(
            accumulator_setup_ops_after_start_clock
        ),

        instructions_after_last_ffma_before_end_clock=(
            instructions_after_last_ffma
        ),
        unexpected_tail_ops=unexpected_tail_ops,

        timer_start_window=timer_start_window,
        timer_end_window=timer_end_window,

        errors=errors,
        warnings=warnings,
    )

    return FunctionAnalysis(
        summary=summary,
        instructions=instructions,
        measured_region=measured_region,
        start_index=start_index,
        end_index=end_index,
    )


def format_bool(value: bool | None) -> str:
    if value is None:
        return "n/a"

    return "true" if value else "false"


def format_optional_int(
    value: int | None,
) -> str:
    if value is None:
        return "n/a"

    return str(value)


def render_text(
    analyses: list[FunctionAnalysis],
) -> str:
    lines: list[str] = []

    total_errors = sum(
        len(analysis.summary.errors)
        for analysis in analyses
    )

    total_warnings = sum(
        len(analysis.summary.warnings)
        for analysis in analyses
    )

    overall_status = (
        "FAIL"
        if total_errors
        else "WARN"
        if total_warnings
        else "PASS"
    )

    lines.append("[Overall]")
    lines.append(f"Status                    : {overall_status}")
    lines.append(f"Error count               : {total_errors}")
    lines.append(f"Warning count             : {total_warnings}")
    lines.append("")

    for analysis in analyses:
        summary = analysis.summary

        lines.append(f"[{summary.name}]")
        lines.append(
            f"Status                    : {summary.status}"
        )
        lines.append(
            f"Instruction count         : "
            f"{summary.instruction_count}"
        )
        lines.append(
            f"Function FFMA count       : "
            f"{summary.function_ffma_count}"
        )
        lines.append(
            f"Measured-region FFMA      : "
            f"{summary.measured_region_ffma_count}"
        )
        lines.append(
            f"Self-dependent FFMA       : "
            f"{summary.self_dependent_ffma_count}"
        )
        lines.append(
            f"CS2R count                : "
            f"{summary.cs2r_count}"
        )
        lines.append(
            f"Clock-read count          : "
            f"{summary.clock_read_count}"
        )
        lines.append(
            f"Timer region found        : "
            f"{format_bool(summary.timer_region_found)}"
        )
        lines.append(
            f"Timer start address       : "
            f"{summary.timer_start_address or 'n/a'}"
        )
        lines.append(
            f"Timer end address         : "
            f"{summary.timer_end_address or 'n/a'}"
        )
        lines.append(
            f"Measured-region insns     : "
            f"{format_optional_int(summary.measured_region_instruction_count)}"
        )
        lines.append(
            "Accumulator registers     : "
            + (
                ", ".join(summary.accumulator_registers)
                or "none"
            )
        )
        lines.append(
            f"Dependency chains         : "
            f"{summary.dependency_chain_count}"
        )
        lines.append(
            "Static chain lengths      : "
            + (
                ", ".join(
                    str(value)
                    for value in summary.static_chain_lengths
                )
                or "none"
            )
        )
        lines.append(
            "Accumulator use counts    : "
            + (
                ", ".join(
                    f"{register}={count}"
                    for register, count
                    in summary.accumulator_use_counts.items()
                )
                or "none"
            )
        )
        lines.append(
            f"Expected reuse distance   : "
            f"{format_optional_int(summary.expected_reuse_distance)}"
        )
        lines.append(
            f"Round-robin valid         : "
            f"{format_bool(summary.round_robin_valid)}"
        )
        lines.append(
            f"Cross-chain dependencies  : "
            f"{len(summary.cross_chain_dependencies)}"
        )
        lines.append(
            f"Measured-region memory ops: "
            f"{len(summary.measured_region_memory_ops)}"
        )
        lines.append(
            f"  Global                  : "
            f"{len(summary.measured_region_global_memory_ops)}"
        )
        lines.append(
            f"  Local                   : "
            f"{len(summary.measured_region_local_memory_ops)}"
        )
        lines.append(
            f"  Shared                  : "
            f"{len(summary.measured_region_shared_memory_ops)}"
        )
        lines.append(
            f"  Constant                : "
            f"{len(summary.measured_region_constant_loads)}"
        )
        lines.append(
            f"  Other                   : "
            f"{len(summary.measured_region_other_memory_ops)}"
        )
        lines.append(
            f"Setup ops after start     : "
            f"{len(summary.setup_ops_after_start_clock)}"
        )
        lines.append(
            f"Accumulator setup ops     : "
            f"{len(summary.accumulator_setup_ops_after_start_clock)}"
        )
        lines.append(
            f"Tail instructions         : "
            f"{len(summary.instructions_after_last_ffma_before_end_clock)}"
        )
        lines.append(
            f"Unexpected tail ops       : "
            f"{len(summary.unexpected_tail_ops)}"
        )

        lines.append(
            "Normalized accumulator pattern:"
        )

        if summary.normalized_accumulator_pattern:
            pattern = " ".join(
                str(value)
                for value
                in summary.normalized_accumulator_pattern
            )
            lines.append(f"  {pattern}")
        else:
            lines.append("  none")

        lines.append("Reuse distances:")

        if summary.reuse_distances:
            for register, distances in (
                summary.reuse_distances.items()
            ):
                rendered = (
                    ", ".join(
                        str(distance)
                        for distance in distances
                    )
                    or "none"
                )

                lines.append(
                    f"  {register}: {rendered}"
                )
        else:
            lines.append("  none")

        lines.append("Timer start window:")

        if summary.timer_start_window:
            lines.extend(
                f"  {line}"
                for line in summary.timer_start_window
            )
        else:
            lines.append("  unavailable")

        lines.append("Timer end window:")

        if summary.timer_end_window:
            lines.extend(
                f"  {line}"
                for line in summary.timer_end_window
            )
        else:
            lines.append("  unavailable")

        if summary.setup_ops_after_start_clock:
            lines.append(
                "Instructions after start clock "
                "before first FFMA:"
            )

            lines.extend(
                f"  {line}"
                for line
                in summary.setup_ops_after_start_clock
            )

        if (
            summary.instructions_after_last_ffma_before_end_clock
        ):
            lines.append(
                "Instructions after final FFMA "
                "before end clock:"
            )

            lines.extend(
                f"  {line}"
                for line
                in summary.instructions_after_last_ffma_before_end_clock
            )

        if summary.cross_chain_dependencies:
            lines.append("Cross-chain dependencies:")

            lines.extend(
                f"  {line}"
                for line
                in summary.cross_chain_dependencies
            )

        if summary.errors:
            lines.append("Errors:")

            lines.extend(
                f"  - {error}"
                for error in summary.errors
            )
        else:
            lines.append("Errors                    : none")

        if summary.warnings:
            lines.append("Warnings:")

            lines.extend(
                f"  - {warning}"
                for warning in summary.warnings
            )
        else:
            lines.append("Warnings                  : none")

        lines.append("Base opcode histogram:")

        for opcode, count in (
            summary.base_opcode_histogram.items()
        ):
            lines.append(
                f"  {opcode:<20} {count}"
            )

        lines.append("")

    return "\n".join(lines) + "\n"


def render_filtered_sass(
    analyses: list[FunctionAnalysis],
) -> str:
    lines: list[str] = []

    for analysis in analyses:
        summary = analysis.summary

        lines.append(
            "=" * 80
        )
        lines.append(
            f"Function: {summary.name}"
        )
        lines.append(
            f"Status  : {summary.status}"
        )
        lines.append(
            "=" * 80
        )

        lines.append("")
        lines.append("[Timer start window]")

        if summary.timer_start_window:
            lines.extend(summary.timer_start_window)
        else:
            lines.append("<unavailable>")

        lines.append("")
        lines.append("[Measured region]")

        if analysis.measured_region:
            lines.extend(
                instruction.text
                for instruction
                in analysis.measured_region
            )
        else:
            lines.append("<empty or unavailable>")

        lines.append("")
        lines.append("[Timer end window]")

        if summary.timer_end_window:
            lines.extend(summary.timer_end_window)
        else:
            lines.append("<unavailable>")

        lines.append("")
        lines.append("[Normalized accumulator pattern]")

        if summary.normalized_accumulator_pattern:
            lines.append(
                " ".join(
                    str(value)
                    for value
                    in summary.normalized_accumulator_pattern
                )
            )
        else:
            lines.append("<none>")

        lines.append("")

    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Validate timer boundaries and FFMA dependency "
            "structure in cuobjdump SASS output."
        )
    )

    parser.add_argument(
        "--input",
        required=True,
        type=Path,
        help="cuobjdump --dump-sass output file",
    )

    parser.add_argument(
        "--output-dir",
        required=True,
        type=Path,
        help="directory for text, JSON, and filtered SASS output",
    )

    parser.add_argument(
        "--expected-static-ffma",
        type=int,
        default=32,
        help=(
            "expected number of static FFMA instructions "
            "inside each measured region"
        ),
    )

    parser.add_argument(
        "--expected-independent-accumulators",
        type=int,
        default=8,
        help=(
            "expected number of independent accumulator chains"
        ),
    )

    parser.add_argument(
        "--timer-window-radius",
        type=int,
        default=5,
        help=(
            "number of instructions to print before and after "
            "each timer instruction"
        ),
    )

    parser.add_argument(
        "--fail-on-warning",
        action="store_true",
        help="return a non-zero exit code when warnings exist",
    )

    args = parser.parse_args()

    if args.expected_static_ffma <= 0:
        parser.error(
            "--expected-static-ffma must be positive"
        )

    if args.expected_independent_accumulators <= 0:
        parser.error(
            "--expected-independent-accumulators must be positive"
        )

    if args.timer_window_radius < 0:
        parser.error(
            "--timer-window-radius must be non-negative"
        )

    if not args.input.is_file():
        print(
            f"ERROR: input file was not found: {args.input}",
            file=sys.stderr,
        )
        return 2

    text = args.input.read_text(
        encoding="utf-8",
        errors="replace",
    )

    blocks = split_functions(text)

    missing_functions = [
        function_name
        for function_name in EXPECTED_FUNCTIONS
        if function_name not in blocks
    ]

    if missing_functions:
        print(
            "ERROR: missing functions in SASS: "
            + ", ".join(missing_functions),
            file=sys.stderr,
        )

        print(
            "Detected functions: "
            + (
                ", ".join(blocks)
                if blocks
                else "none"
            ),
            file=sys.stderr,
        )

        return 2

    analyses = [
        summarize_function(
            name=function_name,
            block=blocks[function_name],
            expected_static_ffma=(
                args.expected_static_ffma
            ),
            expected_independent_accumulators=(
                args.expected_independent_accumulators
            ),
            timer_window_radius=(
                args.timer_window_radius
            ),
        )
        for function_name in EXPECTED_FUNCTIONS
    ]

    total_errors = sum(
        len(analysis.summary.errors)
        for analysis in analyses
    )

    total_warnings = sum(
        len(analysis.summary.warnings)
        for analysis in analyses
    )

    overall_status = (
        "FAIL"
        if total_errors
        else "WARN"
        if total_warnings
        else "PASS"
    )

    args.output_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    text_path = (
        args.output_dir
        / "sass_summary.txt"
    )

    json_path = (
        args.output_dir
        / "sass_summary.json"
    )

    filtered_path = (
        args.output_dir
        / "probe_ffma_filtered.sass.txt"
    )

    text_path.write_text(
        render_text(analyses),
        encoding="utf-8",
    )

    json_document = {
        "schema_version": 2,
        "input_file": str(args.input.resolve()),
        "configuration": {
            "expected_static_ffma": (
                args.expected_static_ffma
            ),
            "expected_independent_accumulators": (
                args.expected_independent_accumulators
            ),
            "timer_window_radius": (
                args.timer_window_radius
            ),
            "fail_on_warning": (
                args.fail_on_warning
            ),
        },
        "overall_status": overall_status,
        "error_count": total_errors,
        "warning_count": total_warnings,
        "functions": [
            asdict(analysis.summary)
            for analysis in analyses
        ],
    }

    json_path.write_text(
        json.dumps(
            json_document,
            indent=2,
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )

    filtered_path.write_text(
        render_filtered_sass(analyses),
        encoding="utf-8",
    )

    print(f"Wrote: {text_path}")
    print(f"Wrote: {json_path}")
    print(f"Wrote: {filtered_path}")
    print(f"Status: {overall_status}")
    print(f"Errors: {total_errors}")
    print(f"Warnings: {total_warnings}")

    if total_errors > 0:
        return 3

    if args.fail_on_warning and total_warnings > 0:
        return 4

    return 0


if __name__ == "__main__":
    raise SystemExit(main())