# ICARUS: Dual-Issue 3-Stage RV32I Pipeline CPU

A high-performance, dual-issue RISC-V RV32I CPU implementation featuring scoreboard-based hazard detection, selective operand forwarding, and comprehensive verification infrastructure. This project demonstrates advanced pipeline design techniques including non-overlapping dual-fetch decode, inter-slot dependency resolution, and single-cycle memory arbitration.

## Table of Contents

- [Project Overview](#project-overview)
- [Key Features](#key-features)
- [Architecture](#architecture)
- [Pipeline Stages](#pipeline-stages)
- [Hazard Detection & Forwarding](#hazard-detection--forwarding)
- [Testbench & Verification](#testbench--verification)
- [Running Simulations](#running-simulations)
- [Repository Structure](#repository-structure)
- [Performance Metrics](#performance-metrics)
- [Limitations & Future Work](#limitations--future-work)

---

## Project Overview

**ICARUS** is a 3-stage, dual-issue in-order RISC-V RV32I CPU core designed for educational and research purposes. The implementation supports the complete RV32I base instruction set, including:

- **Arithmetic/Logic**: ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND (R-type and I-type variants)
- **Memory**: LB, LH, LW, LBU, LHU (loads); SB, SH, SW (stores)
- **Control Flow**: BEQ, BNE, BLT, BGE, BLTU, BGEU (branches); JAL, JALR (jumps)
- **System**: LUI, AUIPC, ECALL, EBREAK

### Pipeline Structure

The CPU implements a **3-stage pipeline** with dual-issue capability:

```
┌─────────┐     ┌─────────┐     ┌─────────┐
│   IF    │ --> │   ID    │ --> │ EX/WB   │
│ (Fetch) │     │(Decode) │     │(Execute)│
└─────────┘     └─────────┘     └─────────┘
     │               │               │
  [PC, PC+4]    [Slot0, Slot1]   [EX0, EX1]
```

**Stage Breakdown:**
- **IF (Fetch)**: Dual-port instruction fetch at PC and PC+4
- **ID (Decode)**: Non-overlapping decode of two instructions with hazard detection
- **EX/WB (Execute/Writeback)**: Dual ALU execution with same-cycle register writeback

### Dual-Issue Design Philosophy

The core employs a **non-overlapping fetch/decode** architecture where:
- Two instructions are fetched simultaneously (at PC and PC+4)
- Both instructions are decoded in parallel
- Issue decisions are made based on scoreboard state and structural constraints
- Slot0 (older instruction) has priority; Slot1 (younger) issues only when safe

---

## Key Features

### 1. Dual-Issue Rules & Constraints

**Slot0 (Older Instruction):**
- Always considered for issue (unless pipeline is stalled)
- Can execute any RV32I instruction type
- Has priority for memory port access
- Controls branch/jump redirects

**Slot1 (Younger Instruction):**
- Issues only when independent of Slot0 and older in-flight instructions
- **Restrictions:**
  - Cannot issue if Slot0 is a branch/jump (control-flow ordering)
  - Cannot issue if both slots need memory (single-port constraint)
  - Cannot issue if Slot1 is LUI/AUIPC (architectural simplification)
  - Cannot issue if Slot1 is a branch/jump and also needs memory
  - Must pass scoreboard checks (RAW, WAW, load-use hazards)

### 2. Scoreboard-Based Hazard Detection

The **Register Status Table** (`reg_status_table.sv`) maintains per-register state:

| State | Description |
|-------|-------------|
| `busy[rd]` | Register has a pending write from an in-flight instruction |
| `load_pending[rd]` | Register has a pending write from a load instruction |

**Hazard Types Detected:**
- **RAW (Read-After-Write)**: Slot1 reads a register that Slot0 or an older instruction will write
- **WAW (Write-After-Write)**: Slot1 writes a register that is already busy
- **Load-Use**: An instruction uses a register that has a pending load (cannot forward)

The scoreboard considers same-cycle writeback clears, ensuring accurate hazard detection even when instructions complete in the same cycle they issue.

### 3. Selective Operand Forwarding

The **Forward Unit** (`forward_unit.sv`) implements three forwarding paths:

| Path | Source | Destination | Condition |
|------|--------|-------------|-----------|
| **EX0 → ID0** | Slot0 execute result | Slot0 decode operands | ALU result (not load) |
| **EX1 → ID1** | Slot1 execute result | Slot1 decode operands | ALU result (not load) |
| **EX0 → ID1** | Slot0 execute result | Slot1 decode operands | ALU result, EX1 doesn't match |

**Forwarding Rules:**
- Only ALU results are forwarded (loads cause stalls)
- EX1 has priority over EX0 for Slot1 forwarding
- Register x0 (zero) is never forwarded

### 4. Branch & Jump Handling

- **Branch Resolution**: Computed in execute stage; taken branches redirect PC
- **Jump Handling**: JAL/JALR computed in execute stage; immediate redirect
- **Redirect Priority**: Slot0 branch/jump takes precedence over Slot1
- **Flush Behavior**: Both fetch slots are flushed (NOP inserted) on redirect

### 5. Single-Port Memory Arbitration

The data memory interface uses a single read/write port with arbitration:
- Slot0 has priority for memory access
- Slot1 can use memory only when Slot0 is not accessing it
- Byte/halfword/word accesses supported with proper byte-enable generation

### 6. Comprehensive Verification Infrastructure

- **Universal Testbench**: Cycle-accurate simulation with full pipeline visibility
- **Pipeline Analyzer**: Python-based tool that reconstructs instruction timelines
- **Trace Format**: CSV-based logging of all pipeline stages and control signals
- **Hazard Tagging**: Automatic detection and annotation of forwarding, stalls, and hazards

---

## Architecture

### High-Level Block Diagram

```
                    ┌─────────────────┐
                    │  Instruction    │
                    │  Memory (Dual)  │
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │   Fetch Stage   │
                    │  PC, PC+4       │
                    └────────┬────────┘
                             │
        ┌────────────────────┴────────────────────┐
        │                                          │
┌───────▼────────┐                      ┌─────────▼────────┐
│  Decoder 0     │                      │  Decoder 1       │
│  Imm Gen 0     │                      │  Imm Gen 1        │
└───────┬────────┘                      └─────────┬────────┘
        │                                          │
        └──────────────┬──────────────────────────┘
                       │
        ┌──────────────▼──────────────┐
        │   Register File (4R/2W)     │
        └──────────────┬───────────────┘
                       │
        ┌──────────────▼──────────────┐
        │   Forward Unit              │
        │   Scoreboard                │
        │   Issue Unit                │
        └──────────────┬──────────────┘
                       │
        ┌──────────────▼──────────────┐
        │   Execute Stage             │
        │   ALU0, ALU1                │
        │   Branch Unit 0, 1          │
        │   Memory Interface          │
        └──────────────┬──────────────┘
                       │
                    ┌──▼──┐
                    │ WB  │
                    └─────┘
```

### Module Hierarchy

```
rv32i_cpu (top-level)
├── regfile (4R/2W register file)
├── decoder × 2 (instruction decoding)
├── imm_gen × 2 (immediate generation)
├── forward_unit (operand forwarding)
├── reg_status_table (scoreboard)
├── issue_unit (issue decisions)
├── alu × 2 (arithmetic/logic units)
└── branch_unit × 2 (branch condition evaluation)
```

---

## Pipeline Stages

### Stage 1: Fetch (IF)

**Functionality:**
- Maintains program counter (`pc_f`)
- Fetches two instructions: `instr_addr = pc_fetch`, `instr_addr1 = pc_fetch + 4`
- Handles PC updates: sequential (+4 or +8) or redirect (branch/jump target)

**Key Signals:**
- `pc_f`: Current program counter
- `pc_fetch`: Next fetch address (accounts for stalls)
- `instr0_f`, `instr1_f`: Fetched instructions

**Pipeline Registers:**
- `fd_pc`: Base PC for the instruction pair
- `fd_instr`, `fd_instr1`: Instructions entering decode

### Stage 2: Decode (ID)

**Functionality:**
- Decodes both instructions in parallel
- Extracts register operands (rs1, rs2, rd)
- Generates immediate values
- Reads register file (4 read ports: 2 per slot)
- Applies forwarding to operands
- Checks scoreboard for hazards
- Makes issue decisions

**Key Components:**
- **Decoder**: Converts instruction bits to control signals
- **Immediate Generator**: Extracts and sign-extends immediates (I, S, B, U, J, Z types)
- **Register File**: 32 registers, 4 read ports, 2 write ports
- **Forward Unit**: Selects between register file and forwarded values
- **Scoreboard**: Tracks in-flight writes and load dependencies
- **Issue Unit**: Decides if Slot0/Slot1 can issue

**Pipeline Registers (to Execute):**
- `de_pc`, `de_instr`, `de_ctrl`, `de_rs1`, `de_rs2`, `de_rd`, `de_rs1_val`, `de_rs2_val`, `de_imm` (Slot0)
- `de1_pc`, `de1_instr`, `de1_ctrl`, `de1_rs1`, `de1_rs2`, `de1_rd`, `de1_rs1_val`, `de1_rs2_val`, `de1_imm` (Slot1)

### Stage 3: Execute/Writeback (EX/WB)

**Functionality:**
- Performs ALU operations (two independent ALUs)
- Evaluates branch conditions
- Computes jump targets
- Accesses data memory (single port, arbitrated)
- Writes results back to register file

**Key Components:**
- **ALU**: 10 operations (ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND)
- **Branch Unit**: Compares operands for 6 branch types
- **Memory Interface**: Handles loads/stores with byte-enable generation
- **Writeback Mux**: Selects ALU result, memory data, PC+4, or immediate

**Writeback Sources:**
- `WB_ALU`: ALU result
- `WB_MEM`: Load data (sign/zero extended)
- `WB_PC4`: PC + 4 (for JAL/JALR)
- `WB_IMM`: Immediate value (for LUI)

---

## Hazard Detection & Forwarding

### Scoreboard Algorithm

The scoreboard maintains two bit-vectors:
- `busy[31:0]`: One bit per register indicating pending write
- `load_pending[31:0]`: One bit per register indicating pending load

**Update Rules:**
1. On issue: Set `busy[rd]` and `load_pending[rd]` (if load)
2. On writeback: Clear `busy[rd]` and `load_pending[rd]`
3. Same-cycle clears: Writeback clears are applied before hazard checking

**Hazard Detection:**
```systemverilog
// RAW hazard for Slot1
raw_hazard1 = (use_rs1_1 && busy_view_with_slot0[rs1_1]) ||
              (use_rs2_1 && busy_view_with_slot0[rs2_1]);

// WAW hazard for Slot1
waw_hazard1 = reg_write1_issue && (rd1_issue != 5'd0) && 
              busy_view_with_slot0[rd1_issue];

// Load-use hazard
load_use0 = (use_rs1_0 && busy_view[rs1_0] && load_view[rs1_0]) ||
            (use_rs2_0 && busy_view[rs2_0] && load_view[rs2_0]);
```

### Forwarding Paths

**Path 1: EX0 → ID0**
- Forwards Slot0's ALU result to Slot0's decode operands
- Resolves back-to-back ALU dependencies within Slot0

**Path 2: EX1 → ID1**
- Forwards Slot1's ALU result to Slot1's decode operands
- Resolves back-to-back ALU dependencies within Slot1

**Path 3: EX0 → ID1**
- Forwards Slot0's ALU result to Slot1's decode operands
- Resolves cross-slot dependencies when Slot1 depends on Slot0
- EX1 has priority: if both EX0 and EX1 match, EX1 wins

**Load-Use Handling:**
- Loads cannot be forwarded (data arrives after execute stage)
- Load-use hazards cause pipeline stalls
- Scoreboard tracks `load_pending` to detect these cases

---

## Testbench & Verification

### Universal Testbench

The `universal_tb.sv` testbench provides:
- Clock generation (10ns period)
- Reset sequence
- Memory model (`simple_memory.sv`) with dual instruction ports
- Cycle-accurate pipeline tracing
- Debug signal visibility

### Trace Format

The testbench generates `sim/pipeline_trace.log` with the following CSV columns:

| Column | Description |
|--------|-------------|
| `cycle` | Simulation cycle number |
| `pc_f`, `pc_e` | Program counters (fetch, execute) |
| `fetch0`, `fetch1` | Fetched instructions (hex) |
| `decode0`, `decode1` | Decoded instructions (hex) |
| `issue_valid0`, `issue_valid1` | Issue decisions (0/1) |
| `exec0`, `exec1` | Executing instructions (hex) |
| `result0`, `result1` | Execution results (hex) |
| `opA_e`, `opB_e` | Execute stage operands |
| `branch_taken0/1`, `jump_taken0/1` | Control flow decisions |
| `redirect` | Pipeline redirect signal |
| `fwd_rs1_en`, `fwd_rs2_en` | Forwarding enable signals |
| `stall_if_id` | Pipeline stall signal |
| `raw1`, `waw1` | Hazard flags |
| `load_use0`, `load_use1` | Load-use hazard flags |

### Pipeline Analyzer

The `tools/analyze_pipeline.py` script:
- Parses trace logs and hex program files
- Disassembles instructions
- Reconstructs pipeline timeline
- Computes performance metrics (IPC, CPI, dual-issue rate)
- Tags forwarding events and hazards
- Generates human-readable reports

**Example Timeline Output:**
```
Cycle | PC_F     | F0                 | F1                 | D0[i0]              | D1[i1]              | E0/R0                    | E1/R1                    | Notes
------|----------|--------------------|--------------------|---------------------|---------------------|--------------------------|--------------------------|------------------
    0 | 00000000 | addi x1, x0, 1     | addi x2, x0, 2     | nop            i0=0 | nop            i1=0 | nop              00000000 | nop              00000000 |
    1 | 00000004 | addi x3, x1, 3     | addi x4, x2, 4     | addi x1, x0, 1 i0=1 | addi x2, x0, 2 i1=1 | nop              00000000 | nop              00000000 |
    2 | 00000008 | add  x5, x1, x2    | add  x6, x3, x4    | addi x3, x1, 3 i0=1 | addi x4, x2, 4 i1=1 | addi x1, x0, 1   00000001 | addi x2, x0, 2   00000002 | F0_RS1=EX0;F1_RS1=EX0
```

**Tag Interpretation:**
- `F0_RS1=EX0`: Slot0's RS1 forwarded from Slot0's execute result
- `F1_RS1=EX1`: Slot1's RS1 forwarded from Slot1's execute result
- `F1_RS1=EX0`: Slot1's RS1 forwarded from Slot0's execute result
- `RAW1(scoreboard)`: Slot1 blocked by RAW hazard
- `WAW1(scoreboard)`: Slot1 blocked by WAW hazard
- `LDUSE0`, `LDUSE1`: Load-use hazard detected
- `STALL(load-use0)`: Pipeline stalled due to load-use

---

## Running Simulations

### Prerequisites

- **Icarus Verilog** (`iverilog`, `vvp`) - SystemVerilog simulation
- **Python 3** - For pipeline analysis
- **PowerShell** (Windows) or **Bash** (Linux/Mac) - Build script execution

### Build & Run

**Using PowerShell (Windows):**
```powershell
# Basic run with default test
.\build.ps1

# Run specific test program
.\build.ps1 -Hex "tests/dual_issue_showcase.hex"

# Custom cycle limit and output
.\build.ps1 -Hex "tests/loop_unrolling_A.hex" -MaxCycles 500 -Vcd "sim/custom.vcd"

# Generate report without showing timeline
.\build.ps1 -Hex "tests/arithmetic_mix.hex" -NoShow -Out "reports/my_report.txt"
```

**Using Icarus Verilog directly:**
```bash
# Compile
iverilog -g2012 -o sim/run.vvp \
  src/core/rv32i_pkg.sv \
  sim/universal_tb.sv \
  sim/simple_memory.sv \
  src/core/rv32i_cpu.sv \
  src/units/*.sv

# Run simulation
vvp sim/run.vvp +HEX=tests/sample_program.hex +MAX_CYCLES=200 +DUMPFILE=sim/out.vcd

# Analyze trace
python tools/analyze_pipeline.py --trace sim/pipeline_trace.log --hex tests/sample_program.hex --show
```

### Available Test Programs

**Main Tests:**
- `tests/arithmetic_mix.hex` - Mixed ALU operations
- `tests/branch_stress.hex` - Branch-heavy workload
- `tests/dual_issue_showcase.hex` - Demonstrates dual-issue capability
- `tests/load_store_stress.hex` - Memory access patterns
- `tests/loop_unrolling_A.hex` - Loop unrolling benefits

**Extra Tests** (`tests/extra/`):
- Scoreboard tests: `scoreboard_raw_A.hex`, `scoreboard_waw_A.hex`, `scoreboard_loaduse_A.hex`
- Forwarding tests: `ex1_id1_fwd_A.hex`, `dual_issue_fwd_A.hex`
- Slot1 constraint tests: `slot1_branch_A.hex`, `slot1_load_A.hex`, `slot1_store_A.hex`

### Generating Waveforms

Waveform dumps (VCD files) are automatically generated in `sim/`. View with:
- **GTKWave** (open source)
- **ModelSim/QuestaSim**
- **Vivado Simulator**

### Report Generation

Reports are written to `sim/analyze_report.log` by default. They include:
- Program listing (disassembly)
- Pipeline metrics (IPC, CPI, dual-issue rate)
- Hazard statistics
- Forwarding counts
- Complete pipeline timeline

---

## Repository Structure

```
ICARUS/
├── src/
│   ├── core/
│   │   ├── rv32i_cpu.sv          # Top-level CPU module
│   │   └── rv32i_pkg.sv          # Type definitions and enums
│   └── units/
│       ├── alu.sv                 # Arithmetic/logic unit
│       ├── branch_unit.sv         # Branch condition evaluation
│       ├── decoder.sv             # Instruction decoder
│       ├── forward_unit.sv        # Operand forwarding logic
│       ├── imm_gen.sv             # Immediate generator
│       ├── issue_unit.sv          # Issue decision logic
│       ├── regfile.sv             # Register file (4R/2W)
│       └── reg_status_table.sv    # Scoreboard
├── sim/
│   ├── universal_tb.sv            # Main testbench
│   ├── simple_memory.sv           # Memory model
│   ├── pipeline_trace.log         # Generated trace (CSV)
│   └── *.vcd                      # Waveform dumps
├── tests/
│   ├── *.hex                      # Main test programs
│   └── extra/                     # Additional test cases
├── tools/
│   └── analyze_pipeline.py        # Pipeline analyzer script
├── reports/                       # Generated analysis reports
├── Figures/                       # Performance visualizations
├── build.ps1                      # Build script (PowerShell)
└── README.md                       # This file
```

### Key Files

**RTL (`src/`):**
- `rv32i_cpu.sv`: Top-level CPU integrating all units
- `reg_status_table.sv`: Scoreboard implementation
- `forward_unit.sv`: Three-path forwarding logic
- `issue_unit.sv`: Dual-issue decision making

**Verification (`sim/`, `tools/`):**
- `universal_tb.sv`: Comprehensive testbench with tracing
- `analyze_pipeline.py`: Post-simulation analysis tool

**Tests (`tests/`):**
- Hex files contain instruction encodings (one per line, big-endian)
- Programs test specific features (dual-issue, forwarding, hazards)

---

## Performance Metrics

### Typical IPC Results

| Test Program | IPC | Dual-Issue Rate | Notes |
|--------------|-----|-----------------|-------|
| `arithmetic_mix.hex` | ~1.4-1.6 | 40-50% | Good ALU parallelism |
| `dual_issue_showcase.hex` | ~1.7-1.9 | 60-70% | Optimized for dual-issue |
| `loop_unrolling_A.hex` | ~1.5-1.7 | 50-60% | Benefits from unrolling |
| `branch_stress.hex` | ~1.0-1.2 | 10-20% | Branch mispredictions |
| `load_store_stress.hex` | ~1.1-1.3 | 20-30% | Memory port conflicts |

### Forwarding Effectiveness

Typical forwarding rates:
- **F0_RS1(EX0)**: 20-30% of cycles (Slot0 self-dependencies)
- **F1_RS1(EX1)**: 10-15% of cycles (Slot1 self-dependencies)
- **F1_RS1(EX0)**: 15-25% of cycles (Cross-slot dependencies)

### Hazard Rates

Typical hazard detection:
- **RAW1**: 10-20% of cycles (Slot1 blocked by dependencies)
- **WAW1**: 5-10% of cycles (Slot1 blocked by write conflicts)
- **Load-Use**: 5-15% of cycles (Pipeline stalls)

---

## Limitations & Future Work

### Current Limitations

1. **Slot1 Restrictions:**
   - No LUI/AUIPC in Slot1 (architectural simplification)
   - No branch/jump + memory in Slot1 (structural constraint)
   - Limited to ALU operations for writeback (no Slot1 loads in current design)

2. **Structural Constraints:**
   - Single data memory port (Slot0 has priority)
   - No EX1→ID0 forwarding (not needed for correctness, but could improve IPC)

3. **Pipeline Depth:**
   - 3-stage design limits instruction-level parallelism
   - Branch resolution in execute stage causes 1-cycle penalty

4. **Critical Path:**
   - Combinational forwarding paths add to decode stage delay
   - Scoreboard lookup is combinational (could be pipelined)

### Future Enhancements

1. **Stage 4 Pipeline:**
   - Add separate writeback stage
   - Enable dual-retire (both slots writeback simultaneously)
   - Reduce critical path in execute stage

2. **Enhanced Slot1 Support:**
   - Allow Slot1 loads with proper hazard handling
   - Support LUI/AUIPC in Slot1
   - Relax branch/memory restrictions

3. **Memory System:**
   - Dual-port data memory
   - Instruction/data cache integration
   - Memory-mapped I/O support

4. **Performance Optimizations:**
   - Branch prediction (static or dynamic)
   - Instruction prefetching
   - Register renaming for WAW elimination

5. **Verification:**
   - Formal verification of hazard detection
   - RISC-V compliance tests (RISCV-DV)
   - Coverage-driven test generation

6. **Synthesis & Implementation:**
   - FPGA synthesis (Xilinx, Intel)
   - ASIC design flow integration
   - Power and area analysis

---

## Academic Context

This project was developed as part of a Computer Organization and Architecture course, demonstrating:

- **Pipeline Design**: Understanding of instruction-level parallelism
- **Hazard Resolution**: Data, control, and structural hazard handling
- **Forwarding**: Operand bypassing for performance
- **Scoreboarding**: In-order execution with dependency tracking
- **Verification**: Comprehensive testbench and analysis infrastructure

The design follows RISC-V principles and can serve as a foundation for more advanced CPU implementations.

---

## License

This project is provided for educational and research purposes. Please refer to the RISC-V Foundation's licensing terms for instruction set architecture usage.

---

## Acknowledgments

- **RISC-V Foundation** for the open instruction set architecture
- **Icarus Verilog** for the simulation infrastructure
- Course instructors and teaching assistants for guidance

---

## Contact & Contributions

For questions, suggestions, or contributions, please open an issue or submit a pull request.

**Author**: Developed as part of IIT Mandi Computer Organization and Architecture coursework

**Version**: 1.0 (Dual-Issue 3-Stage Pipeline)

---

*Last Updated: 2024*

