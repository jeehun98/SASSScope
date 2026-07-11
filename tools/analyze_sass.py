#!/usr/bin/env python3
"""Minimal static checker for cuobjdump --dump-sass output."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from dataclasses import dataclass, asdict
from pathlib import Path

FUNCTION_RE = re.compile(r"^\s*Function\s*:\s*(\S+)", re.MULTILINE)
INSTRUCTION_RE = re.compile(
    r"/\*([0-9a-fA-F]+)\*/\s+(?:@!?[A-Za-z0-9_.]+\s+)?"
    r"([A-Z][A-Z0-9_.]*)\s*(.*?)\s*;"
)
REGISTER_RE = re.compile(r"\bR(\d+)(?:\.reuse)?\b")


@dataclass
class Instruction:
    address: str
    opcode: str
    operands: str
    text: str


@dataclass
class FunctionSummary:
    name: str
    instruction_count: int
    opcode_histogram: dict[str, int]
    ffma_count: int
    cs2r_count: int
    accumulator_registers: list[str]
    measured_region_instruction_count: int | None
    measured_region_memory_ops: list[str]
    setup_ops_after_start_clock: list[str]
    warnings: list[str]
    timer_start_window: list[str]
    timer_end_window: list[str]


def split_functions(text: str) -> dict[str, str]:
    matches = list(FUNCTION_RE.finditer(text))
    result: dict[str, str] = {}
    for index, match in enumerate(matches):
        start = match.start()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        result[match.group(1)] = text[start:end]
    return result


def parse_instructions(block: str) -> list[Instruction]:
    instructions: list[Instruction] = []
    for match in INSTRUCTION_RE.finditer(block):
        instructions.append(
            Instruction(
                address=match.group(1),
                opcode=match.group(2),
                operands=match.group(3).strip(),
                text=match.group(0).strip(),
            )
        )
    return instructions


def normalize_register(token: str) -> str | None:
    match = REGISTER_RE.search(token)
    return f"R{match.group(1)}" if match else None


def get_accumulators(instructions: list[Instruction]) -> list[str]:
    accumulators: set[str] = set()
    for instruction in instructions:
        if instruction.opcode != "FFMA":
            continue
        operands = [part.strip() for part in instruction.operands.split(",")]
        if len(operands) < 2:
            continue
        destination = normalize_register(operands[0])
        first_source = normalize_register(operands[1])
        if destination is not None and destination == first_source:
            accumulators.add(destination)
    return sorted(accumulators, key=lambda value: int(value[1:]))


def window(instructions: list[Instruction], center: int, radius: int = 5) -> list[str]:
    begin = max(0, center - radius)
    end = min(len(instructions), center + radius + 1)
    return [instruction.text for instruction in instructions[begin:end]]


def summarize_function(name: str, block: str) -> FunctionSummary:
    instructions = parse_instructions(block)
    histogram = Counter(instruction.opcode for instruction in instructions)
    clocks = [index for index, inst in enumerate(instructions) if inst.opcode == "CS2R"]
    warnings: list[str] = []

    measured_region: list[Instruction] = []
    start_window: list[str] = []
    end_window: list[str] = []
    setup_ops: list[str] = []

    if len(clocks) >= 2:
        start_index, end_index = clocks[0], clocks[-1]
        measured_region = instructions[start_index + 1 : end_index]
        start_window = window(instructions, start_index)
        end_window = window(instructions, end_index)

        first_ffma = next(
            (index for index in range(start_index + 1, end_index)
             if instructions[index].opcode == "FFMA"),
            None,
        )
        if first_ffma is not None:
            suspicious_prefixes = ("MOV", "FADD", "FMUL", "LDC", "ULDC", "LDG", "LDL")
            setup_ops = [
                instructions[index].text
                for index in range(start_index + 1, first_ffma)
                if instructions[index].opcode.startswith(suspicious_prefixes)
            ]
            if setup_ops:
                warnings.append(
                    "Possible setup instructions appear after the starting clock read. "
                    "Inspect timer_start_window; initialization may be inside the measurement."
                )
    else:
        warnings.append(f"Expected at least 2 CS2R timer reads, found {len(clocks)}.")

    accumulators = get_accumulators(instructions)
    ffma_count = histogram.get("FFMA", 0)

    if name == "probe_dependent_ffma":
        if ffma_count != 32:
            warnings.append(f"Expected 32 static FFMA instructions, found {ffma_count}.")
        if len(accumulators) != 1:
            warnings.append(
                f"Expected 1 accumulator register, found {len(accumulators)}: {accumulators}"
            )
    elif name == "probe_independent_ffma_8":
        if ffma_count != 32:
            warnings.append(f"Expected 32 static FFMA instructions, found {ffma_count}.")
        if len(accumulators) != 8:
            warnings.append(
                f"Expected 8 accumulator registers, found {len(accumulators)}: {accumulators}"
            )

    memory_ops = [
        instruction.text
        for instruction in measured_region
        if instruction.opcode.startswith(("LD", "ST"))
    ]
    if memory_ops and name in {"probe_dependent_ffma", "probe_independent_ffma_8"}:
        warnings.append(
            "Load/store instruction found inside the measured region; check for spills or setup traffic."
        )

    return FunctionSummary(
        name=name,
        instruction_count=len(instructions),
        opcode_histogram=dict(sorted(histogram.items())),
        ffma_count=ffma_count,
        cs2r_count=histogram.get("CS2R", 0),
        accumulator_registers=accumulators,
        measured_region_instruction_count=len(measured_region) if measured_region else None,
        measured_region_memory_ops=memory_ops,
        setup_ops_after_start_clock=setup_ops,
        warnings=warnings,
        timer_start_window=start_window,
        timer_end_window=end_window,
    )


def render_text(summaries: list[FunctionSummary]) -> str:
    lines: list[str] = []
    overall_warnings = 0
    for summary in summaries:
        lines.append(f"[{summary.name}]")
        lines.append(f"Instruction count        : {summary.instruction_count}")
        lines.append(f"Static FFMA count        : {summary.ffma_count}")
        lines.append(f"CS2R count               : {summary.cs2r_count}")
        lines.append(
            "Accumulator registers     : "
            + (", ".join(summary.accumulator_registers) or "none")
        )
        lines.append(
            f"Measured-region insns    : {summary.measured_region_instruction_count}"
        )
        lines.append(
            f"Measured-region LD/ST    : {len(summary.measured_region_memory_ops)}"
        )
        lines.append("Opcode histogram         :")
        for opcode, count in summary.opcode_histogram.items():
            lines.append(f"  {opcode:<18} {count}")

        lines.append("Timer start window:")
        lines.extend(f"  {line}" for line in summary.timer_start_window)
        lines.append("Timer end window:")
        lines.extend(f"  {line}" for line in summary.timer_end_window)

        if summary.warnings:
            lines.append("Warnings:")
            for warning in summary.warnings:
                lines.append(f"  - {warning}")
                overall_warnings += 1
        else:
            lines.append("Warnings                : none")
        lines.append("")

    lines.append(f"Overall warning count: {overall_warnings}")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()

    text = args.input.read_text(encoding="utf-8", errors="replace")
    blocks = split_functions(text)

    expected = [
        "probe_timer_only",
        "probe_dependent_ffma",
        "probe_independent_ffma_8",
    ]
    missing = [name for name in expected if name not in blocks]
    if missing:
        print(f"ERROR: missing functions in SASS: {', '.join(missing)}", file=sys.stderr)
        print(f"Detected functions: {', '.join(blocks) or 'none'}", file=sys.stderr)
        return 2

    summaries = [summarize_function(name, blocks[name]) for name in expected]

    args.output_dir.mkdir(parents=True, exist_ok=True)
    text_path = args.output_dir / "sass_summary.txt"
    json_path = args.output_dir / "sass_summary.json"
    filtered_path = args.output_dir / "probe_ffma_filtered.sass.txt"

    text_path.write_text(render_text(summaries), encoding="utf-8")
    json_path.write_text(
        json.dumps([asdict(summary) for summary in summaries], indent=2),
        encoding="utf-8",
    )

    selected_blocks = "\n".join(blocks[name] for name in expected)
    filtered_lines = [
        line
        for line in selected_blocks.splitlines()
        if re.search(
            r"Function\s*:|\b(?:FFMA|CS2R|IADD3|ISETP|BRA|MOV|FADD|FMUL|LD\w*|ST\w*)\b",
            line,
        )
    ]
    filtered_path.write_text("\n".join(filtered_lines) + "\n", encoding="utf-8")

    warning_count = sum(len(summary.warnings) for summary in summaries)
    print(f"Wrote: {text_path}")
    print(f"Wrote: {json_path}")
    print(f"Wrote: {filtered_path}")
    print(f"Warnings: {warning_count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
