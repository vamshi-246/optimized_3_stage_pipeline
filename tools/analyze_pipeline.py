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
    instr_execute1: int
    result_execute: int
    result_execute1: int
    stall: str
    branch_taken: bool
    branch_taken1: bool
    jump_taken: bool
    jump_taken1: bool
    jump_target: int
    jump_target1: int
    stall_flag: bool
    bubble: bool
    fwd_rs1: bool
    fwd_rs2: bool
    busy_vec: int


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

    def safe_hex(s: str, default: int = 0) -> int:
        """
        Convert a Verilog-style hex string to int, tolerating X/Z.

        If the string contains any x/z/? bits (e.g. \"xxxxxxxx\"), return
        the provided default instead of raising. This keeps the analyzer
        robust when the testbench logs unknown values after halt.
        """
        if s is None:
            return default
        s = s.strip()
        if not s:
            return default
        lower = s.lower()
        if any(c in lower for c in ("x", "z", "?")):
            return default
        return int(s, 16)

    with path.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            pc_str = row.get("pc_f", "")
            # If PC itself has gone X/Z, treat this and all following rows
            # as unusable (typically happens after system/halt); stop here.
            if pc_str is None:
                break
            if any(c in pc_str.lower() for c in ("x", "z", "?")):
                break

            stall_str = row.get("stall", "none")
            if stall_str is None:
                stall_str = "none"
            stall_str = stall_str.strip()
            entries.append(
                TraceEntry(
                    cycle=int(row["cycle"]),
                    pc_f=safe_hex(row["pc_f"], 0),
                    instr_fetch=safe_hex(row["instr_fetch"], 0),
                    instr_decode=safe_hex(row["instr_decode"], 0),
                    instr_execute=safe_hex(row["instr_execute"], 0),
                    instr_execute1=safe_hex(row.get("instr_execute1", "0"), 0),
                    result_execute=safe_hex(row["result_execute"], 0),
                    result_execute1=safe_hex(row.get("result_execute1", "0"), 0),
                    stall=stall_str,
                    branch_taken=row.get("branch_taken", "0") not in ("0", "false", "False"),
                    branch_taken1=row.get("branch_taken1", "0") not in ("0", "false", "False"),
                    jump_taken=row.get("jump_taken", "0") not in ("0", "false", "False"),
                    jump_taken1=row.get("jump_taken1", "0") not in ("0", "false", "False"),
                    jump_target=safe_hex(row.get("jump_target", "0"), 0),
                    jump_target1=safe_hex(row.get("jump_target1", "0"), 0),
                    stall_flag=row.get("stall_flag", "0") not in ("0", "false", "False", "", None),
                    bubble=row.get("bubble", "0") not in ("0", "false", "False", "", None),
                    fwd_rs1=row.get("forward_rs1", "0") not in ("0", "false", "False", "", None),
                    fwd_rs2=row.get("forward_rs2", "0") not in ("0", "false", "False", "", None),
                    busy_vec=safe_hex(row.get("busy_vec", "0"), 0),
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


def print_timeline(entries: List[TraceEntry], prog: Dict[int, int], emit) -> None:
    header = f"{'Cycle':>5} | {'PC_F':>8} | {'Fetch':<24} | {'Decode':<24} | {'Execute':<24} | {'Exec1':<24} | Notes"
    emit(header)
    emit("-" * len(header))
    for e in entries:
        note_parts = []
        if e.branch_taken:
            note_parts.append("branch_taken")
        if e.branch_taken1:
            note_parts.append("branch1_taken")
        if e.jump_taken:
            note_parts.append(f"jump0->0x{e.jump_target:08x}")
        if e.jump_taken1:
            note_parts.append(f"jump1->0x{e.jump_target1:08x}")
        if e.stall_flag:
            note_parts.append("STALL(load-use)")
        if e.fwd_rs1:
            note_parts.append("FWD_RS1")
        if e.fwd_rs2:
            note_parts.append("FWD_RS2")
        if e.busy_vec:
            note_parts.append(f"busy=0x{e.busy_vec:08x}")
        note = ";".join(note_parts)
        emit(
            f"{e.cycle:5d} | {e.pc_f:08x} | {disasm(e.instr_fetch):<24} | "
            f"{disasm(e.instr_decode):<24} | {disasm(e.instr_execute):<24} | "
            f"{disasm(e.instr_execute1):<24} | {note}"
        )


def print_program_listing(program: Dict[int, int], emit) -> None:
    if not program:
        emit("No program contents decoded (hex file missing or empty).")
        return
    emit("--- Program (from hex) ---")
    emit(f"{'Addr':>8} | {'Instr':>8} | Disassembly")
    emit("-" * 40)
    for addr in sorted(program.keys()):
        instr = program[addr]
        emit(f"{addr:08x} | {instr:08x} | {disasm(instr)}")
    emit("")


def main() -> None:
    parser = argparse.ArgumentParser(description="Analyze RV32I pipeline trace")
    parser.add_argument("--trace", type=Path, default=Path("sim/pipeline_trace.log"), help="Path to trace log")
    parser.add_argument("--hex", dest="hexfile", type=Path, default=Path("tests/sample_program.hex"), help="Program hex file")
    parser.add_argument("--show", action="store_true", help="Pretty print pipeline timeline")
    parser.add_argument("--out", dest="outfile", type=Path, default=Path("sim/analyze_report.log"), help="Write report to this file")
    args = parser.parse_args()

    out_lines: List[str] = []

    def emit(line: str = "") -> None:
        out_lines.append(line)
        if args.show:
            print(line)

    trace_entries = parse_trace(args.trace)
    if not trace_entries:
        emit(f"No trace entries found in {args.trace}")
        return

    program = read_hex_program(args.hexfile)

    total_cycles = len(trace_entries)
    retired = sum(1 for e in trace_entries if e.instr_execute not in (0, NOP))
    cpi = float("inf") if retired == 0 else total_cycles / retired
    ipc = 0.0 if total_cycles == 0 else retired / total_cycles
    branches_taken = sum(1 for e in trace_entries if e.branch_taken)
    potential_raw = compute_hazards(trace_entries)
    stall_cycles = sum(1 for e in trace_entries if e.stall_flag)
    forwarding_cycles = sum(1 for e in trace_entries if e.fwd_rs1 or e.fwd_rs2)
    avg_busy = 0.0
    if total_cycles:
        avg_busy = sum(bin(e.busy_vec).count("1") for e in trace_entries) / total_cycles

    print_program_listing(program, emit)

    emit("=== Pipeline Report ===")
    emit(f"Trace file      : {args.trace}")
    emit(f"Program hex     : {args.hexfile}")
    emit(f"Total cycles    : {total_cycles}")
    emit(f"Instructions    : {retired}")
    emit(f"CPI / IPC       : {cpi:.3f} / {ipc:.3f}")
    emit(f"Branches taken  : {branches_taken}")
    emit(f"Potential RAW hazards (decode vs prev execute): {potential_raw}")
    emit(f"Stall cycles (load-use)   : {stall_cycles}")
    emit(f"Cycles with forwarding    : {forwarding_cycles}")
    emit(f"Average busy registers    : {avg_busy:.2f}")

    # Always include timeline in the written report; show on stdout only if requested.
    emit("")
    emit("--- Timeline ---")
    print_timeline(trace_entries, program, emit)

    if args.outfile:
        args.outfile.parent.mkdir(parents=True, exist_ok=True)
        args.outfile.write_text("\n".join(out_lines) + "\n")
        emit(f"Report written to {args.outfile}")


if __name__ == "__main__":
    main()
