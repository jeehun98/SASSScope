#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from collections import Counter
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Optional


SECTION_PATTERN = re.compile(
    r'^\s*\.section\s+\.text\.([^\s,"]+)',
    re.IGNORECASE,
)

FUNCTION_COMMENT_PATTERN = re.compile(
    r'^\s*//-+\s*\.text\.([^\s]+)',
    re.IGNORECASE,
)

SOURCE_PATTERN = re.compile(
    r'^\s*//##\s+File\s+"([^"]+)"\s*,\s*line\s+([0-9]+)(.*)$',
    re.IGNORECASE,
)

INSTRUCTION_PATTERN = re.compile(
    r'^\s*/\*([0-9a-fA-F]+)\*/\s*(.*?)\s*;\s*(?:/\*.*)?$'
)

PREDICATE_PATTERN = re.compile(
    r'^(@!?P[0-9]+)\s+(.*)$',
    re.IGNORECASE,
)

OPCODE_PATTERN = re.compile(
    r'^([A-Za-z][A-Za-z0-9_.]*)'
    r'(?:\s+(.*))?$'
)


@dataclass
class SassInstruction:
    index: int
    kernel: str
    address_hex: str
    address_decimal: int
    source_file: str
    source_line: Optional[int]
    source_text: str
    source_annotation: str
    predicate: str
    opcode: str
    operands: str
    instruction: str


def read_text(path: Path) -> str:
    return path.read_text(
        encoding="utf-8-sig",
        errors="replace",
    )


def normalize_function_name(name: str) -> str:
    return name.strip().rstrip(":")


def select_function_name(
    available_names: list[str],
    requested_name: str,
) -> str:
    exact = [
        name
        for name in available_names
        if normalize_function_name(name) == requested_name
    ]

    if len(exact) == 1:
        return exact[0]

    partial = [
        name
        for name in available_names
        if requested_name in normalize_function_name(name)
    ]

    if len(partial) == 1:
        return partial[0]

    if not exact and not partial:
        raise ValueError(
            f"Kernel '{requested_name}' was not found. "
            f"Available functions: {available_names}"
        )

    matches = exact if exact else partial

    raise ValueError(
        f"Kernel name '{requested_name}' is ambiguous. "
        f"Matches: {matches}"
    )


def find_available_functions(text: str) -> list[str]:
    names: list[str] = []

    for line in text.splitlines():
        section_match = SECTION_PATTERN.match(line)

        if section_match:
            name = normalize_function_name(
                section_match.group(1)
            )

            if name not in names:
                names.append(name)

            continue

        comment_match = FUNCTION_COMMENT_PATTERN.match(line)

        if comment_match:
            name = normalize_function_name(
                comment_match.group(1)
            )

            if name not in names:
                names.append(name)

    return names


def resolve_source_file(
    recorded_path: str,
    source_roots: list[Path],
) -> Optional[Path]:
    normalized = recorded_path.replace("\\", "/")
    direct = Path(recorded_path)

    if direct.is_file():
        return direct.resolve()

    basename = Path(normalized).name

    direct_candidates: list[Path] = []

    for root in source_roots:
        direct_candidates.extend(
            [
                root / basename,
                root / "src" / basename,
                root / "include" / basename,
            ]
        )

    for candidate in direct_candidates:
        if candidate.is_file():
            return candidate.resolve()

    recursive_matches: list[Path] = []

    for root in source_roots:
        if not root.is_dir():
            continue

        try:
            recursive_matches.extend(
                path.resolve()
                for path in root.rglob(basename)
                if path.is_file()
            )
        except OSError:
            continue

    unique_matches = sorted(
        set(recursive_matches),
        key=lambda path: str(path).lower(),
    )

    if len(unique_matches) == 1:
        return unique_matches[0]

    return None


class SourceCache:
    def __init__(self, source_roots: list[Path]) -> None:
        self.source_roots = source_roots
        self.resolved_paths: dict[str, Optional[Path]] = {}
        self.lines: dict[Path, list[str]] = {}

    def get_source_text(
        self,
        recorded_path: str,
        line_number: Optional[int],
    ) -> str:
        if not recorded_path or line_number is None:
            return ""

        if recorded_path not in self.resolved_paths:
            self.resolved_paths[recorded_path] = (
                resolve_source_file(
                    recorded_path,
                    self.source_roots,
                )
            )

        resolved = self.resolved_paths[recorded_path]

        if resolved is None:
            return ""

        if resolved not in self.lines:
            try:
                self.lines[resolved] = read_text(
                    resolved
                ).splitlines()
            except OSError:
                self.lines[resolved] = []

        source_lines = self.lines[resolved]

        if line_number <= 0:
            return ""

        index = line_number - 1

        if index >= len(source_lines):
            return ""

        return source_lines[index].strip()


def parse_instruction_text(
    raw_instruction: str,
) -> tuple[str, str, str]:
    text = raw_instruction.strip()
    predicate = ""

    predicate_match = PREDICATE_PATTERN.match(text)

    if predicate_match:
        predicate = predicate_match.group(1)
        text = predicate_match.group(2).strip()

    opcode_match = OPCODE_PATTERN.match(text)

    if not opcode_match:
        return predicate, "", text

    opcode = opcode_match.group(1).upper()
    operands = (
        opcode_match.group(2) or ""
    ).strip()

    return predicate, opcode, operands


def parse_kernel_instructions(
    text: str,
    requested_kernel: str,
    source_roots: list[Path],
) -> tuple[str, list[SassInstruction]]:
    available_functions = find_available_functions(text)

    selected_function = select_function_name(
        available_functions,
        requested_kernel,
    )

    source_cache = SourceCache(source_roots)

    current_function: Optional[str] = None
    current_source_file = ""
    current_source_line: Optional[int] = None
    current_source_annotation = ""

    instructions: list[SassInstruction] = []

    for line in text.splitlines():
        section_match = SECTION_PATTERN.match(line)

        if section_match:
            current_function = normalize_function_name(
                section_match.group(1)
            )

            current_source_file = ""
            current_source_line = None
            current_source_annotation = ""
            continue

        comment_match = FUNCTION_COMMENT_PATTERN.match(line)

        if comment_match:
            current_function = normalize_function_name(
                comment_match.group(1)
            )

            current_source_file = ""
            current_source_line = None
            current_source_annotation = ""
            continue

        if current_function != selected_function:
            continue

        source_match = SOURCE_PATTERN.match(line)

        if source_match:
            current_source_file = source_match.group(1)
            current_source_line = int(
                source_match.group(2)
            )

            suffix = source_match.group(3).strip()

            current_source_annotation = (
                f'File "{current_source_file}", '
                f"line {current_source_line}"
            )

            if suffix:
                current_source_annotation += f" {suffix}"

            continue

        instruction_match = INSTRUCTION_PATTERN.match(line)

        if not instruction_match:
            continue

        address_hex = instruction_match.group(1).lower()
        raw_instruction = instruction_match.group(2).strip()

        predicate, opcode, operands = (
            parse_instruction_text(
                raw_instruction
            )
        )

        source_text = source_cache.get_source_text(
            current_source_file,
            current_source_line,
        )

        instructions.append(
            SassInstruction(
                index=len(instructions),
                kernel=requested_kernel,
                address_hex=f"0x{address_hex}",
                address_decimal=int(
                    address_hex,
                    16,
                ),
                source_file=current_source_file,
                source_line=current_source_line,
                source_text=source_text,
                source_annotation=current_source_annotation,
                predicate=predicate,
                opcode=opcode,
                operands=operands,
                instruction=raw_instruction,
            )
        )

    if not instructions:
        raise ValueError(
            f"No SASS instructions were extracted for "
            f"kernel '{requested_kernel}'."
        )

    addresses = [
        item.address_decimal
        for item in instructions
    ]

    if len(addresses) != len(set(addresses)):
        raise ValueError(
            "Duplicate instruction addresses were found."
        )

    if addresses != sorted(addresses):
        raise ValueError(
            "Instruction addresses are not monotonically increasing."
        )

    return selected_function, instructions


def write_csv(
    path: Path,
    instructions: list[SassInstruction],
) -> None:
    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    fieldnames = [
        "index",
        "kernel",
        "address_hex",
        "address_decimal",
        "source_file",
        "source_line",
        "source_text",
        "source_annotation",
        "predicate",
        "opcode",
        "operands",
        "instruction",
    ]

    with path.open(
        "w",
        encoding="utf-8",
        newline="",
    ) as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=fieldnames,
        )

        writer.writeheader()

        for instruction in instructions:
            writer.writerow(
                asdict(instruction)
            )


def write_text_report(
    path: Path,
    requested_kernel: str,
    selected_function: str,
    instructions: list[SassInstruction],
) -> None:
    opcode_counts = Counter(
        item.opcode
        for item in instructions
        if item.opcode
    )

    mapped_count = sum(
        1
        for item in instructions
        if item.source_line is not None
    )

    source_text_count = sum(
        1
        for item in instructions
        if item.source_text
    )

    lines: list[str] = []

    lines.append("[summary]")
    lines.append(
        f"requested kernel    : {requested_kernel}"
    )
    lines.append(
        f"selected function   : {selected_function}"
    )
    lines.append(
        f"instruction count   : {len(instructions)}"
    )
    lines.append(
        f"source-mapped count : {mapped_count}"
    )
    lines.append(
        f"source-text count   : {source_text_count}"
    )
    lines.append("")

    lines.append("[opcode counts]")

    for opcode, count in sorted(
        opcode_counts.items(),
        key=lambda item: (-item[1], item[0]),
    ):
        lines.append(
            f"{opcode:<24} {count}"
        )

    lines.append("")
    lines.append("[instructions]")

    current_source_key: tuple[str, Optional[int]] = (
        "",
        None,
    )

    for item in instructions:
        source_key = (
            item.source_file,
            item.source_line,
        )

        if source_key != current_source_key:
            lines.append("")

            if item.source_file and item.source_line:
                lines.append(
                    f'// {item.source_file}:'
                    f"{item.source_line}"
                )

                if item.source_text:
                    lines.append(
                        f"// {item.source_text}"
                    )
            else:
                lines.append(
                    "// source mapping unavailable"
                )

            current_source_key = source_key

        predicate_text = (
            f"{item.predicate} "
            if item.predicate
            else ""
        )

        instruction_text = (
            f"{predicate_text}"
            f"{item.opcode}"
        )

        if item.operands:
            instruction_text += (
                f" {item.operands}"
            )

        lines.append(
            f"{item.index:04d} "
            f"{item.address_hex:>8}  "
            f"{instruction_text}"
        )

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    path.write_text(
        "\n".join(lines) + "\n",
        encoding="utf-8",
    )


def write_json_report(
    path: Path,
    requested_kernel: str,
    selected_function: str,
    input_path: Path,
    instructions: list[SassInstruction],
) -> None:
    opcode_counts = Counter(
        item.opcode
        for item in instructions
        if item.opcode
    )

    payload = {
        "schema_version": 1,
        "requested_kernel": requested_kernel,
        "selected_function": selected_function,
        "input_file": str(input_path.resolve()),
        "instruction_count": len(instructions),
        "source_mapped_count": sum(
            1
            for item in instructions
            if item.source_line is not None
        ),
        "source_text_count": sum(
            1
            for item in instructions
            if item.source_text
        ),
        "opcode_counts": dict(
            sorted(opcode_counts.items())
        ),
        "instructions": [
            asdict(item)
            for item in instructions
        ],
    }

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    path.write_text(
        json.dumps(
            payload,
            indent=2,
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Extract a normalized SASS instruction listing "
            "and CUDA source-line mapping from nvdisasm -gi output."
        )
    )

    parser.add_argument(
        "--input",
        required=True,
        type=Path,
        help="nvdisasm -gi text output",
    )

    parser.add_argument(
        "--kernel",
        required=True,
        help="Requested CUDA kernel name",
    )

    parser.add_argument(
        "--output-csv",
        required=True,
        type=Path,
        help="Normalized instruction CSV",
    )

    parser.add_argument(
        "--output-text",
        required=True,
        type=Path,
        help="Human-readable instruction listing",
    )

    parser.add_argument(
        "--output-json",
        required=True,
        type=Path,
        help="Machine-readable instruction report",
    )

    parser.add_argument(
        "--source-root",
        action="append",
        default=[],
        type=Path,
        help=(
            "Source tree used to resolve source file text. "
            "May be specified multiple times."
        ),
    )

    return parser


def main() -> int:
    parser = build_argument_parser()
    args = parser.parse_args()

    if not args.input.is_file():
        parser.error(
            f"Input file does not exist: {args.input}"
        )

    source_roots = [
        path.resolve()
        for path in args.source_root
        if path.exists()
    ]

    try:
        text = read_text(args.input)

        selected_function, instructions = (
            parse_kernel_instructions(
                text=text,
                requested_kernel=args.kernel,
                source_roots=source_roots,
            )
        )

        write_csv(
            args.output_csv,
            instructions,
        )

        write_text_report(
            args.output_text,
            args.kernel,
            selected_function,
            instructions,
        )

        write_json_report(
            args.output_json,
            args.kernel,
            selected_function,
            args.input,
            instructions,
        )

    except Exception as error:
        print(
            f"ERROR: {error}",
            file=sys.stderr,
        )
        return 2

    print(
        f"Extracted {len(instructions)} SASS instructions "
        f"for {args.kernel}."
    )

    print(
        f"CSV : {args.output_csv}"
    )

    print(
        f"Text: {args.output_text}"
    )

    print(
        f"JSON: {args.output_json}"
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())