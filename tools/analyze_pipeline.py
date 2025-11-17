#!/usr/bin/env python3
"""
Pipeline trace analyzer for the baseline RV32I core.

Reads the CSV-like pipeline_trace.log and a program hex file, decodes
instructions, and reports high-level metrics plus a simple timeline view.
"""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional


NOP = 0x00000013


@dataclass
class TraceEntry:
    cycle: int
    pc_f: int
    instr_fetch: int
    instr_decode: int
    instr_execute: int
    result_execute: int
    stall: str
    branch_taken: bool


def read_hex_program(path: Path) -> Dict[int, int]:
    prog: Dict[int, int] = {}
    if not path.exists():
        return prog
    with path.open() as f:
        for idx, line in enumerate(f):
            line = line.strip()
            if not line:
                continue
            prog[idx * 4] = int(line, 16)
    return prog


def parse_trace(path: Path) -> List[TraceEntry]:
    entries: List[TraceEntry] = []
    with path.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            entries.append(
                TraceEntry(
                    cycle=int(row["cycle"]),
                    pc_f=int(row["pc_f"], 16),
                    instr_fetch=int(row["instr_fetch"], 16),
                    instr_decode=int(row["instr_decode"], 16),
                    instr_execute=int(row["instr_execute"], 16),
                    result_execute=int(row["result_execute"], 16),
                    stall=row.get("stall", "none"),
                    branch_taken=row.get("branch_taken", "0") not in ("0", "false", "False"),
                )
            )
    return entries


def sign_extend(value: int, bits: int) -> int:
    sign_bit = 1 << (bits - 1)
    return (value & (sign_bit - 1)) - (value & sign_bit)


def decode_fields(instr: int) -> Dict[str, Optional[int]]:
    opcode = instr & 0x7F
    rd = (instr >> 7) & 0x1F
    funct3 = (instr >> 12) & 0x7
    rs1 = (instr >> 15) & 0x1F
    rs2 = (instr >> 20) & 0x1F
    funct7 = (instr >> 25) & 0x7F

    fields: Dict[str, Optional[int]] = {
        "opcode": opcode,
        "rd": rd,
        "rs1": rs1,
        "rs2": rs2,
        "funct3": funct3,
        "funct7": funct7,
        "imm": None,
        "mnemonic": "unknown",
    }

    if instr == 0 or instr == NOP:
        fields["mnemonic"] = "nop"
        return fields

    if opcode == 0x33:  # R-type
        alu_map = {
            (0, 0): "add",
            (0x20, 0): "sub",
            (0, 1): "sll",
            (0, 2): "slt",
            (0, 3): "sltu",
            (0, 4): "xor",
            (0, 5): "srl",
            (0x20, 5): "sra",
            (0, 6): "or",
            (0, 7): "and",
        }
        fields["mnemonic"] = alu_map.get((funct7, funct3), "r-op")
    elif opcode == 0x13:  # I-type ALU
        imm = sign_extend(instr >> 20, 12)
        fields["imm"] = imm
        mapping = {
            0: "addi",
            2: "slti",
            3: "sltiu",
            4: "xori",
            6: "ori",
            7: "andi",
        }
        if funct3 == 1:
          fields["mnemonic"] = "slli"
          fields["imm"] = instr >> 20
        elif funct3 == 5:
          fields["mnemonic"] = "srai" if (funct7 >> 5) & 1 else "srli"
          fields["imm"] = instr >> 20
        else:
          fields["mnemonic"] = mapping.get(funct3, "i-op")
    elif opcode == 0x3:  # Loads
        imm = sign_extend(instr >> 20, 12)
        fields["imm"] = imm
        fields["mnemonic"] = {0: "lb", 1: "lh", 2: "lw", 4: "lbu", 5: "lhu"}.get(funct3, "load")
    elif opcode == 0x23:  # Stores
        imm = sign_extend(((instr >> 25) << 5) | ((instr >> 7) & 0x1F), 12)
        fields["imm"] = imm
        fields["mnemonic"] = {0: "sb", 1: "sh", 2: "sw"}.get(funct3, "store")
    elif opcode == 0x63:  # Branches
        imm = sign_extend(((instr >> 31) << 12) | (((instr >> 7) & 1) << 11) |
                          (((instr >> 25) & 0x3F) << 5) | (((instr >> 8) & 0xF) << 1), 13)
        fields["imm"] = imm
        fields["mnemonic"] = {0: "beq", 1: "bne", 4: "blt", 5: "bge", 6: "bltu", 7: "bgeu"}.get(funct3, "branch")
    elif opcode == 0x6F:  # JAL
        imm = sign_extend(((instr >> 31) << 20) | (((instr >> 12) & 0xFF) << 12) |
                          (((instr >> 20) & 1) << 11) | (((instr >> 21) & 0x3FF) << 1), 21)
        fields["imm"] = imm
        fields["mnemonic"] = "jal"
    elif opcode == 0x67:  # JALR
        imm = sign_extend(instr >> 20, 12)
        fields["imm"] = imm
        fields["mnemonic"] = "jalr"
    elif opcode == 0x37:
        fields["imm"] = instr & 0xFFFFF000
        fields["mnemonic"] = "lui"
    elif opcode == 0x17:
        fields["imm"] = instr & 0xFFFFF000
        fields["mnemonic"] = "auipc"
    elif opcode == 0x73:
        fields["mnemonic"] = "system"
    return fields


def disasm(instr: int) -> str:
    f = decode_fields(instr)
    m = f["mnemonic"]
    if m == "nop":
        return "nop"
    rd, rs1, rs2, imm = f["rd"], f["rs1"], f["rs2"], f["imm"]
    if m in {"add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"}:
        return f"{m} x{rd}, x{rs1}, x{rs2}"
    if m in {"addi", "slti", "sltiu", "xori", "ori", "andi", "slli", "srli", "srai"}:
        return f"{m} x{rd}, x{rs1}, {imm}"
    if m in {"lb", "lh", "lw", "lbu", "lhu"}:
        return f"{m} x{rd}, {imm}(x{rs1})"
    if m in {"sb", "sh", "sw"}:
        return f"{m} x{rs2}, {imm}(x{rs1})"
    if m in {"beq", "bne", "blt", "bge", "bltu", "bgeu"}:
        return f"{m} x{rs1}, x{rs2}, {imm}"
    if m in {"jal"}:
        return f"jal x{rd}, {imm}"
    if m in {"jalr"}:
        return f"jalr x{rd}, {imm}(x{rs1})"
    if m in {"lui", "auipc"}:
        return f"{m} x{rd}, {imm}"
    if m == "system":
        return "system"
    return m


def compute_hazards(entries: List[TraceEntry]) -> int:
    potential_raw = 0
    for i in range(1, len(entries)):
        dec = decode_fields(entries[i].instr_decode)
        prev = decode_fields(entries[i - 1].instr_execute)
        if prev["mnemonic"] == "nop":
            continue
        rd_prev = prev["rd"]
        if rd_prev == 0:
            continue
        if dec["mnemonic"] == "nop":
            continue
        if dec["rs1"] == rd_prev or dec["rs2"] == rd_prev:
            potential_raw += 1
    return potential_raw


def print_timeline(entries: List[TraceEntry], prog: Dict[int, int]) -> None:
    header = f"{'Cycle':>5} | {'PC_F':>8} | {'Fetch':<24} | {'Decode':<24} | {'Execute':<24} | Notes"
    print(header)
    print("-" * len(header))
    for e in entries:
        note_parts = []
        if e.branch_taken:
            note_parts.append("branch_taken")
        if e.stall and e.stall.lower() not in ("", "none"):
            note_parts.append(f"stall:{e.stall}")
        note = ";".join(note_parts)
        print(
            f"{e.cycle:5d} | {e.pc_f:08x} | {disasm(e.instr_fetch):<24} | "
            f"{disasm(e.instr_decode):<24} | {disasm(e.instr_execute):<24} | {note}"
        )


def print_program_listing(program: Dict[int, int]) -> None:
    if not program:
        print("No program contents decoded (hex file missing or empty).")
        return
    print("--- Program (from hex) ---")
    print(f"{'Addr':>8} | {'Instr':>8} | Disassembly")
    print("-" * 40)
    for addr in sorted(program.keys()):
        instr = program[addr]
        print(f"{addr:08x} | {instr:08x} | {disasm(instr)}")
    print()


def main() -> None:
    parser = argparse.ArgumentParser(description="Analyze RV32I pipeline trace")
    parser.add_argument("--trace", type=Path, default=Path("sim/pipeline_trace.log"), help="Path to trace log")
    parser.add_argument("--hex", dest="hexfile", type=Path, default=Path("tests/sample_program.hex"), help="Program hex file")
    parser.add_argument("--show", action="store_true", help="Pretty print pipeline timeline")
    args = parser.parse_args()

    trace_entries = parse_trace(args.trace)
    if not trace_entries:
        print(f"No trace entries found in {args.trace}")
        return

    program = read_hex_program(args.hexfile)

    total_cycles = len(trace_entries)
    retired = sum(1 for e in trace_entries if e.instr_execute not in (0, NOP))
    cpi = float("inf") if retired == 0 else total_cycles / retired
    ipc = 0.0 if total_cycles == 0 else retired / total_cycles
    branches_taken = sum(1 for e in trace_entries if e.branch_taken)
    potential_raw = compute_hazards(trace_entries)

    print_program_listing(program)

    print("=== Pipeline Report ===")
    print(f"Trace file      : {args.trace}")
    print(f"Program hex     : {args.hexfile}")
    print(f"Total cycles    : {total_cycles}")
    print(f"Instructions    : {retired}")
    print(f"CPI / IPC       : {cpi:.3f} / {ipc:.3f}")
    print(f"Branches taken  : {branches_taken}")
    print(f"Potential RAW hazards (decode vs prev execute): {potential_raw}")

    if args.show:
        print("\n--- Timeline ---")
        print_timeline(trace_entries, program)


if __name__ == "__main__":
    main()
