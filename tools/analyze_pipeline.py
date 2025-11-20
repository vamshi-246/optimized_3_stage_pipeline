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
    fetch0: int
    fetch1: int
    decode0: int
    decode1: int
    issue0: bool
    issue1: bool
    exec0: int
    exec1: int
    result0: int
    result1: int
    branch_taken0: bool
    branch_taken1: bool
    jump_taken0: bool
    jump_taken1: bool
    branch_target0: int
    branch_target1: int
    jump_target0: int
    jump_target1: int
    mem0_re: bool
    mem0_we: bool
    mem1_re: bool
    mem1_we: bool
    mem_addr0: int
    mem_addr1: int
    fwd_rs1_0_en: bool
    fwd_rs2_0_en: bool
    fwd_rs1_1_src: int
    fwd_rs2_1_src: int
    stall_if: bool
    raw1: bool
    waw1: bool
    load_use0: bool
    load_use1: bool
    busy_vec: int
    load_pending_vec: int


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

    def safe_int_field(s: Optional[str], default: int = 0) -> int:
        if s is None:
            return default
        s = s.strip()
        if not s:
            return default
        lower = s.lower()
        if any(c in lower for c in ("x", "z", "?")):
            return default
        try:
            return int(s, 0)
        except ValueError:
            return default

    def parse_bool(s: Optional[str]) -> bool:
        """Strict boolean parser: only explicit '1'/'true' mean True."""
        if s is None:
            return False
        s = s.strip().lower()
        if s in ("1", "true", "yes", "y"):
            return True
        return False

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

            entries.append(
                TraceEntry(
                    cycle=int(row["cycle"]),
                    pc_f=safe_hex(row["pc_f"], 0),
                    fetch0=safe_hex(row.get("fetch0", "0"), 0),
                    fetch1=safe_hex(row.get("fetch1", "0"), 0),
                    decode0=safe_hex(row.get("decode0", "0"), 0),
                    decode1=safe_hex(row.get("decode1", "0"), 0),
                    issue0=parse_bool(row.get("issue0", "0")),
                    issue1=parse_bool(row.get("issue1", "0")),
                    exec0=safe_hex(row.get("exec0", "0"), 0),
                    exec1=safe_hex(row.get("exec1", "0"), 0),
                    result0=safe_hex(row.get("result0", "0"), 0),
                    result1=safe_hex(row.get("result1", "0"), 0),
                    branch_taken0=parse_bool(row.get("branch_taken0", "0")),
                    branch_taken1=parse_bool(row.get("branch_taken1", "0")),
                    jump_taken0=parse_bool(row.get("jump_taken0", "0")),
                    jump_taken1=parse_bool(row.get("jump_taken1", "0")),
                    branch_target0=safe_hex(row.get("branch_target0", "0"), 0),
                    branch_target1=safe_hex(row.get("branch_target1", "0"), 0),
                    jump_target0=safe_hex(row.get("jump_target0", "0"), 0),
                    jump_target1=safe_hex(row.get("jump_target1", "0"), 0),
                    mem0_re=parse_bool(row.get("mem0_re", "0")),
                    mem0_we=parse_bool(row.get("mem0_we", "0")),
                    mem1_re=parse_bool(row.get("mem1_re", "0")),
                    mem1_we=parse_bool(row.get("mem1_we", "0")),
                    mem_addr0=safe_hex(row.get("mem_addr0", "0"), 0),
                    mem_addr1=safe_hex(row.get("mem_addr1", "0"), 0),
                    fwd_rs1_0_en=parse_bool(row.get("fwd_rs1_0_en", "0")),
                    fwd_rs2_0_en=parse_bool(row.get("fwd_rs2_0_en", "0")),
                    fwd_rs1_1_src=safe_int_field(row.get("fwd_rs1_1_src", "0"), 0),
                    fwd_rs2_1_src=safe_int_field(row.get("fwd_rs2_1_src", "0"), 0),
                    stall_if=parse_bool(row.get("stall_if_id", "0")),
                    raw1=parse_bool(row.get("raw1", "0")),
                    waw1=parse_bool(row.get("waw1", "0")),
                    load_use0=parse_bool(row.get("load_use0", "0")),
                    load_use1=parse_bool(row.get("load_use1", "0")),
                    busy_vec=safe_hex(row.get("busy_vec", "0"), 0),
                    load_pending_vec=safe_hex(row.get("load_pending_vec", "0"), 0),
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
        dec = decode_fields(entries[i].decode0)
        prev = decode_fields(entries[i - 1].exec0)
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


RS1_USERS = {
    "add",
    "sub",
    "sll",
    "slt",
    "sltu",
    "xor",
    "srl",
    "sra",
    "or",
    "and",
    "addi",
    "slti",
    "sltiu",
    "xori",
    "ori",
    "andi",
    "slli",
    "srli",
    "srai",
    "lb",
    "lh",
    "lw",
    "lbu",
    "lhu",
    "sb",
    "sh",
    "sw",
    "beq",
    "bne",
    "blt",
    "bge",
    "bltu",
    "bgeu",
    "jalr",
}

RS2_USERS = {
    "add",
    "sub",
    "sll",
    "slt",
    "sltu",
    "xor",
    "srl",
    "sra",
    "or",
    "and",
    "sb",
    "sh",
    "sw",
    "beq",
    "bne",
    "blt",
    "bge",
    "bltu",
    "bgeu",
}

WRITES_RD = {
    "add",
    "sub",
    "sll",
    "slt",
    "sltu",
    "xor",
    "srl",
    "sra",
    "or",
    "and",
    "addi",
    "slti",
    "sltiu",
    "xori",
    "ori",
    "andi",
    "slli",
    "srli",
    "srai",
    "lb",
    "lh",
    "lw",
    "lbu",
    "lhu",
    "jal",
    "jalr",
    "lui",
    "auipc",
}


def uses_rs1(mnemonic: str) -> bool:
    return mnemonic in RS1_USERS


def uses_rs2(mnemonic: str) -> bool:
    return mnemonic in RS2_USERS


def writes_rd(mnemonic: str) -> bool:
    return mnemonic in WRITES_RD


def format_fwd_src(src: int) -> str:
    return {1: "EX1", 2: "EX0"}.get(src, "REG")


def print_timeline(entries: List[TraceEntry], prog: Dict[int, int], emit) -> None:
    header = (
        f"{'Cycle':>5} | {'PC_F':>8} | "
        f"{'F0':<18} | {'F1':<18} | "
        f"{'D0[i0]':<22} | {'D1[i1]':<22} | "
        f"{'E0/R0':<26} | {'E1/R1':<26} | Notes"
    )
    emit(header)
    emit("-" * len(header))
    prev_exec1_fields: Optional[Dict[str, Optional[int]]] = None
    prev_exec1_writes = False
    prev_rd1: Optional[int] = None

    for disp_cycle, e in enumerate(entries):
        note_parts: List[str] = []

        dec0_fields = decode_fields(e.decode0)
        dec1_fields = decode_fields(e.decode1)
        exec0_fields = decode_fields(e.exec0)
        exec1_fields = decode_fields(e.exec1)
        exec1_writes_now = writes_rd(exec1_fields["mnemonic"]) and exec1_fields["rd"] not in (None, 0)

        # Control-flow events
        if e.branch_taken0:
            note_parts.append(f"BR0->0x{e.branch_target0:08x}")
        if e.branch_taken1:
            note_parts.append(f"BR1->0x{e.branch_target1:08x}")
        if e.jump_taken0:
            note_parts.append(f"J0->0x{e.jump_target0:08x}")
        if e.jump_taken1:
            note_parts.append(f"J1->0x{e.jump_target1:08x}")

        # Memory usage
        if e.mem0_re or e.mem0_we:
            mode = ("R" if e.mem0_re else "") + ("W" if e.mem0_we else "")
            note_parts.append(f"MEM0({mode})@0x{e.mem_addr0:08x}")
        if e.mem1_re or e.mem1_we:
            mode = ("R" if e.mem1_re else "") + ("W" if e.mem1_we else "")
            note_parts.append(f"MEM1({mode})@0x{e.mem_addr1:08x}")

        # Forwarding tags
        if e.fwd_rs1_0_en:
            note_parts.append("F0_RS1=EX0")
        if e.fwd_rs2_0_en:
            note_parts.append("F0_RS2=EX0")
        note_parts.append(f"F1_RS1={format_fwd_src(e.fwd_rs1_1_src)}")
        note_parts.append(f"F1_RS2={format_fwd_src(e.fwd_rs2_1_src)}")
        if e.fwd_rs1_1_src == 1 or e.fwd_rs2_1_src == 1:
            note_parts.append("EX1->ID1_OK")

        # Scoreboard hazards
        if e.raw1 and (uses_rs1(dec1_fields["mnemonic"]) or uses_rs2(dec1_fields["mnemonic"])):
            note_parts.append("RAW1(scoreboard)")
        if e.waw1:
            note_parts.append("WAW1(scoreboard)")
        if e.load_use0:
            note_parts.append("LDUSE0")
        if e.load_use1:
            note_parts.append("LDUSE1")
        if e.stall_if:
            note_parts.append("STALL(load-use0)")

        # Cross-cycle EX1 producer/consumer analysis:
        # If previous cycle's EX1 wrote rd1, check how the next cycle consumes it.
        consumer_not_in_slot1 = False
        expected_ex1_fwd_missing = False
        if prev_exec1_writes and prev_rd1 is not None:
            rd1_prev = prev_rd1
            # Does decode0 use this register?
            uses0 = False
            if uses_rs1(dec0_fields["mnemonic"]) and dec0_fields["rs1"] == rd1_prev:
                uses0 = True
            if uses_rs2(dec0_fields["mnemonic"]) and dec0_fields["rs2"] == rd1_prev:
                uses0 = True
            # Does decode1 use this register?
            uses1 = False
            rs1_uses1 = uses_rs1(dec1_fields["mnemonic"]) and dec1_fields["rs1"] == rd1_prev
            rs2_uses1 = uses_rs2(dec1_fields["mnemonic"]) and dec1_fields["rs2"] == rd1_prev
            uses1 = rs1_uses1 or rs2_uses1

            # If slot0 consumes the EX1 result but slot1 does not, the consumer
            # is in the wrong slot for EX1->ID1 style tests.
            if uses0 and not uses1:
                consumer_not_in_slot1 = True

            # If slot1 consumes the EX1 result, we expect forwarding from EX1.
            if uses1:
                if rs1_uses1 and e.fwd_rs1_1_src != 1:
                    expected_ex1_fwd_missing = True
                if rs2_uses1 and e.fwd_rs2_1_src != 1:
                    expected_ex1_fwd_missing = True

        if consumer_not_in_slot1:
            note_parts.append("WARNING:CONSUMER_NOT_IN_SLOT1")
        if expected_ex1_fwd_missing:
            note_parts.append("EXPECTED_EX1_FWD_NOT_FOUND")

        # Scoreboard state
        if e.busy_vec:
            note_parts.append(f"busy=0x{e.busy_vec:08x}")
        if e.load_pending_vec:
            note_parts.append(f"ldpend=0x{e.load_pending_vec:08x}")

        # Halt markers when a SYSTEM retires
        if exec0_fields["mnemonic"] == "system":
            note_parts.append("HALT0")
        if exec1_fields["mnemonic"] == "system":
            note_parts.append("HALT1")

        note = ";".join(note_parts)
        emit(
            f"{disp_cycle:5d} | {e.pc_f:08x} | "
            f"{disasm(e.fetch0):<18} | {disasm(e.fetch1):<18} | "
            f"{disasm(e.decode0):<18} i0={int(e.issue0)} | "
            f"{disasm(e.decode1):<18} i1={int(e.issue1)} | "
            f"{disasm(e.exec0):<12} {e.result0:08x} | "
            f"{disasm(e.exec1):<12} {e.result1:08x} | "
            f"{note}"
        )

        # Update previous-cycle EX1 producer view.
        prev_exec1_fields = exec1_fields
        prev_exec1_writes = exec1_writes_now
        prev_rd1 = exec1_fields["rd"] if exec1_writes_now else None


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
    retired0 = sum(1 for e in trace_entries if e.exec0 not in (0, NOP))
    retired1 = sum(1 for e in trace_entries if e.exec1 not in (0, NOP))
    retired = retired0 + retired1
    cpi = float("inf") if retired == 0 else total_cycles / retired
    ipc = 0.0 if total_cycles == 0 else retired / total_cycles
    branches_taken = sum(1 for e in trace_entries if e.branch_taken0 or e.branch_taken1)
    potential_raw = compute_hazards(trace_entries)
    stall_cycles = sum(1 for e in trace_entries if e.stall_if)
    forwarding_cycles = sum(
        1
        for e in trace_entries
        if e.fwd_rs1_0_en
        or e.fwd_rs2_0_en
        or e.fwd_rs1_1_src in (1, 2)
        or e.fwd_rs2_1_src in (1, 2)
    )
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
