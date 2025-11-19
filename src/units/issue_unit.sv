`timescale 1ns/1ps

import rv32i_pkg::*;

// Issue unit for the Stage-3 dual-issue pipeline.
//
// Decides, per cycle, whether slot0 and slot1 instructions may issue based on:
//   - Inter-slot dependencies (RAW / WAR / WAW between ID0 and ID1)
//   - Scoreboard state (older in-flight producers and pending loads)
//   - Simple structural constraints (memory/branch usage)
//
// Slot0 is always considered for issue, but may stall the pipeline when
// a load-use hazard is detected against an older load in the scoreboard.
// Slot1 issues only when it is independent of slot0, does not conflict
// with older producers in the scoreboard, and does not violate structural
// rules. In this step, slot1 may be marked as issued but EX1 still carries
// a bubble for non-ALU ops.
module issue_unit (
    // Slot 0 (older) decode metadata
    input  control_t   ctrl0,
    input  logic [4:0] rs1_0,
    input  logic [4:0] rs2_0,
    input  logic [4:0] rd_0,
    input  logic       use_rs1_0,
    input  logic       use_rs2_0,

    // Slot 1 (younger) decode metadata
    input  control_t   ctrl1,
    input  logic [4:0] rs1_1,
    input  logic [4:0] rs2_1,
    input  logic [4:0] rd_1,
    input  logic       use_rs1_1,
    input  logic       use_rs2_1,

    // Scoreboard view
    input  logic [31:0] busy_vec,
    input  logic [31:0] load_pending_vec,

    // Issue decisions
    output logic       issue_slot0,
    output logic       issue_slot1,
    output logic       stall_if
);

  // Helper functions
  function automatic logic is_busy(input logic [31:0] v, input logic [4:0] idx);
    return v[idx];
  endfunction

  function automatic logic is_load_pending(input logic [31:0] v, input logic [4:0] idx);
    return v[idx];
  endfunction

  // Local signals for hazard computation
  logic mem0, mem1;
  logic branch0, branch1;
  logic write0, write1;
  logic rs1_0_valid, rs2_0_valid;
  logic rs1_1_valid, rs2_1_valid;
  logic load0;
  logic load_use0;
  logic raw10, waw10, war10, load_use_same_cycle;
  logic sb_raw1, sb_waw1, sb_load_use1;
  logic mem_conflict, branch1_conflict;
  logic hazard1;

  always_comb begin
    // Defaults
    issue_slot0 = 1'b1;
    issue_slot1 = 1'b0;
    stall_if    = 1'b0;

    mem0    = ctrl0.mem_read  || ctrl0.mem_write;
    mem1    = ctrl1.mem_read  || ctrl1.mem_write;
    branch0 = ctrl0.branch    || ctrl0.jump;
    branch1 = ctrl1.branch    || ctrl1.jump;

    write0 = ctrl0.reg_write && (rd_0 != 5'd0);
    write1 = ctrl1.reg_write && (rd_1 != 5'd0);

    rs1_0_valid = use_rs1_0 && (rs1_0 != 5'd0);
    rs2_0_valid = use_rs2_0 && (rs2_0 != 5'd0);
    rs1_1_valid = use_rs1_1 && (rs1_1 != 5'd0);
    rs2_1_valid = use_rs2_1 && (rs2_1 != 5'd0);

    load0 = ctrl0.mem_read && ctrl0.reg_write && (rd_0 != 5'd0);

    // Scoreboard-based load-use hazard for slot0 (older)
    load_use0 = 1'b0;
    if (rs1_0_valid && is_busy(busy_vec, rs1_0) &&
        is_load_pending(load_pending_vec, rs1_0)) begin
      load_use0 = 1'b1;
    end
    if (rs2_0_valid && is_busy(busy_vec, rs2_0) &&
        is_load_pending(load_pending_vec, rs2_0)) begin
      load_use0 = 1'b1;
    end

    // Stall pipeline only for slot0 load-use hazards vs older loads
    stall_if = load_use0;

    // RAW: slot1 reads a value written by slot0 (same-cycle pair)
    raw10 = 1'b0;
    if (write0) begin
      if (rs1_1_valid && (rs1_1 == rd_0)) raw10 = 1'b1;
      if (rs2_1_valid && (rs2_1 == rd_0)) raw10 = 1'b1;
    end

    // WAW: both write same destination (same-cycle pair)
    waw10 = write0 && write1 && (rd_1 == rd_0);

    // WAR: slot1 writes a register read by slot0 (same-cycle pair)
    war10 = write1 &&
            ((use_rs1_0 && (rd_1 == rs1_0)) ||
             (use_rs2_0 && (rd_1 == rs2_0)));

    // Load-use within the same cycle: slot0 is load, slot1 uses rd_0
    load_use_same_cycle = 1'b0;
    if (load0) begin
      if (rs1_1_valid && (rs1_1 == rd_0)) load_use_same_cycle = 1'b1;
      if (rs2_1_valid && (rs2_1 == rd_0)) load_use_same_cycle = 1'b1;
    end

    // Scoreboard hazards for slot1 vs older instructions (includes EX0 + EX1)
    sb_raw1 = 1'b0;
    if (rs1_1_valid && is_busy(busy_vec, rs1_1)) sb_raw1 = 1'b1;
    if (rs2_1_valid && is_busy(busy_vec, rs2_1)) sb_raw1 = 1'b1;

    sb_waw1 = write1 && is_busy(busy_vec, rd_1);

    sb_load_use1 = 1'b0;
    if (rs1_1_valid && is_busy(busy_vec, rs1_1) &&
        is_load_pending(load_pending_vec, rs1_1)) begin
      sb_load_use1 = 1'b1;
    end
    if (rs2_1_valid && is_busy(busy_vec, rs2_1) &&
        is_load_pending(load_pending_vec, rs2_1)) begin
      sb_load_use1 = 1'b1;
    end

    // Structural hazards:
    // - Only one memory op per cycle (slot0 has priority)
    // - Only slot0 may be branch/jump
    mem_conflict     = mem0 && mem1;
    branch1_conflict = branch1; // younger slot cannot be a branch

    // SYSTEM in slot1 must never be blocked; allow it to issue regardless of
    // other hazards (so it can reach execute and halt).
    if (ctrl1.system) begin
      hazard1     = 1'b0;
      issue_slot1 = 1'b1;
    end else begin
      // Combined hazard view for slot1
      hazard1 = raw10 || waw10 || war10 ||
                load_use_same_cycle ||
                sb_raw1 || sb_waw1 || sb_load_use1 ||
                mem_conflict || branch1_conflict;

      // Restrict slot1: allow ALU, LOAD, STORE; forbid branch/jump/LUI/AUIPC.
      // Stores are allowed only when no conflicts/hazards remain.
      if (write1 &&
          (branch1 ||
           ctrl1.jump ||
           ctrl1.is_lui ||
           ctrl1.is_auipc)) begin
        hazard1 = 1'b1;
      end

      // If slot1 is a load, ensure slot0 is not a memory op (mem_conflict already caught)
      // and all hazards are clear.
      issue_slot1 = !hazard1;
    end
  end

endmodule
