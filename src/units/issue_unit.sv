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

    // Scoreboard-derived hazards
    input  logic       raw_hazard0,
    input  logic       raw_hazard1,
    input  logic       waw_hazard0,
    input  logic       waw_hazard1,
    input  logic       war_hazard0,
    input  logic       war_hazard1,
    input  logic       load_use0,
    input  logic       load_use1,

    // Issue decisions
    output logic       issue_slot0,
    output logic       issue_slot1,
    output logic       stall_if
);

  // Local signals for hazard computation
  logic mem0, mem1;
  logic branch0, branch1;
  logic jump0, jump1;
  logic slot0_ctrl_flow;
  logic mem_conflict;
  logic hazard1;

  always_comb begin
    // Defaults
    issue_slot0 = 1'b1;
    issue_slot1 = 1'b0;
    stall_if    = 1'b0;

    mem0    = ctrl0.mem_read  || ctrl0.mem_write;
    mem1    = ctrl1.mem_read  || ctrl1.mem_write;
    branch0 = ctrl0.branch;
    branch1 = ctrl1.branch;
    jump0   = ctrl0.jump;
    jump1   = ctrl1.jump;

    // Structural: single data port
    mem_conflict = mem0 && mem1;

    // Stall pipeline only for load-use hazard on slot0
    stall_if = load_use0;

    // SYSTEM in slot1 must never be blocked; allow it to issue regardless of
    // other hazards (so it can reach execute and halt).
    if (ctrl1.system) begin
      hazard1     = 1'b0;
      issue_slot1 = 1'b1;
    end else begin
      slot0_ctrl_flow = branch0 || jump0;

      hazard1 = raw_hazard1 || waw_hazard1 || war_hazard1 ||
                load_use1   || mem_conflict;

      // Control flow ordering: slot1 branch/jump blocked if slot0 is branch/jump
      if ((branch1 || jump1) && slot0_ctrl_flow) hazard1 = 1'b1;

      // Slot1 still forbids LUI/AUIPC as per prior stage rules.
      if (ctrl1.is_lui || ctrl1.is_auipc) hazard1 = 1'b1;

      // Branch/jump may not coexist with memory in slot1
      if ((branch1 || jump1) && mem1) hazard1 = 1'b1;

      issue_slot1 = !hazard1;
    end
  end

endmodule
