`timescale 1ns/1ps

// Register status table ("scoreboard") for the dual-issue RV32I core.
//
// Tracks, per architectural register:
//   - pending write (busy)
//   - pending load (load_pending)
//   - optional writer slot metadata (not surfaced yet)
//
// Behaviour:
//   - A register is marked busy when an instruction issues with reg_write=1.
//   - If that instruction is a load, load_pending is also set.
//   - Busy / load_pending are cleared when the corresponding instruction
//     writes back (wb*_we & rd != 0).
//
// Hazard classification:
//   - RAW/WAW and load-use hazards are derived from the current busy view,
//     after considering same-cycle writeback clears.
//   - For slot1, the busy view also considers slot0's instruction if it
//     issues in the same cycle (so inter-slot hazards are captured without
//     ad-hoc checks in the issue unit).
//
// WAR is not relevant for this in-order pipeline (reads happen before writes
// in program order), so war_hazard* are driven low to keep the interface
// explicit.
module reg_status_table (
    input  logic        clk,
    input  logic        rst,

    // Issue-stage intent (inputs are pre-gated by issue_slot*)
    input  logic        issue0,
    input  logic        issue1,
    input  logic        reg_write0_issue,
    input  logic        reg_write1_issue,
    input  logic [4:0]  rd0_issue,
    input  logic [4:0]  rd1_issue,
    input  logic        is_load0_issue,
    input  logic        is_load1_issue,
    input  logic [4:0]  rs1_0,
    input  logic [4:0]  rs2_0,
    input  logic [4:0]  rs1_1,
    input  logic [4:0]  rs2_1,
    input  logic        use_rs1_0,
    input  logic        use_rs2_0,
    input  logic        use_rs1_1,
    input  logic        use_rs2_1,

    // Writeback information (what completes this cycle)
    input  logic        wb0_we,
    input  logic [4:0]  wb0_rd,
    input  logic        wb1_we,
    input  logic [4:0]  wb1_rd,

    // Hazard outputs toward the issue unit
    output logic        raw_hazard0,
    output logic        raw_hazard1,
    output logic        waw_hazard0,
    output logic        waw_hazard1,
    output logic        war_hazard0,
    output logic        war_hazard1,
    output logic        load_use0,
    output logic        load_use1,

    // Scoreboard snapshots for tracing/analysis
    output logic [31:0] busy_vec,
    output logic [31:0] load_pending_vec
);

  // Per-register status (packed vectors for simulator friendliness)
  logic [31:0] busy;
  logic [31:0] is_load_pending;

  logic [31:0] busy_next;
  logic [31:0] load_pending_next;

  // Combinational views used for hazard checking within the cycle.
  logic [31:0] busy_view;
  logic [31:0] load_view;
  logic [31:0] busy_view_with_slot0;
  logic [31:0] load_view_with_slot0;

  // Effective busy/load after considering same-cycle writeback clears.
  always_comb begin
    busy_view            = busy;
    load_view            = is_load_pending;
    busy_view_with_slot0 = busy;
    load_view_with_slot0 = is_load_pending;
    busy_next            = busy;
    load_pending_next    = is_load_pending;

    // Apply same-cycle writeback clears before hazard evaluation.
    if (wb0_we && (wb0_rd != 5'd0)) begin
      busy_view[wb0_rd]            = 1'b0;
      load_view[wb0_rd]            = 1'b0;
      busy_view_with_slot0[wb0_rd] = 1'b0;
      load_view_with_slot0[wb0_rd] = 1'b0;
    end
    if (wb1_we && (wb1_rd != 5'd0)) begin
      busy_view[wb1_rd]            = 1'b0;
      load_view[wb1_rd]            = 1'b0;
      busy_view_with_slot0[wb1_rd] = 1'b0;
      load_view_with_slot0[wb1_rd] = 1'b0;
    end

    // Assume slot0 will claim its destination for slot1 hazard evaluation.
    if (issue0 && reg_write0_issue && (rd0_issue != 5'd0)) begin
      busy_view_with_slot0[rd0_issue] = 1'b1;
      load_view_with_slot0[rd0_issue] = is_load0_issue;
    end

    // RAW hazards
    raw_hazard0 = (use_rs1_0 && busy_view[rs1_0]) ||
                  (use_rs2_0 && busy_view[rs2_0]);
    raw_hazard1 = (use_rs1_1 && busy_view_with_slot0[rs1_1]) ||
                  (use_rs2_1 && busy_view_with_slot0[rs2_1]);

    // Load-use hazards (scoreboard-driven)
    load_use0 = (use_rs1_0 && busy_view[rs1_0] && load_view[rs1_0]) ||
                (use_rs2_0 && busy_view[rs2_0] && load_view[rs2_0]);
    load_use1 = (use_rs1_1 && busy_view_with_slot0[rs1_1] && load_view_with_slot0[rs1_1]) ||
                (use_rs2_1 && busy_view_with_slot0[rs2_1] && load_view_with_slot0[rs2_1]);

    // WAW hazards against older in-flight writers
    waw_hazard0 = reg_write0_issue && (rd0_issue != 5'd0) && busy_view[rd0_issue];
    waw_hazard1 = reg_write1_issue && (rd1_issue != 5'd0) && busy_view_with_slot0[rd1_issue];

    // WAR not relevant for in-order pipeline; keep explicit zeros.
    war_hazard0 = 1'b0;
    war_hazard1 = 1'b0;

    // Next-state update: start from cleared view, then set new issuers.
    busy_next           = busy_view;
    load_pending_next   = load_view;
    if (issue0 && reg_write0_issue && (rd0_issue != 5'd0)) begin
      busy_next[rd0_issue]         = 1'b1;
      load_pending_next[rd0_issue] = is_load0_issue;
    end
    if (issue1 && reg_write1_issue && (rd1_issue != 5'd0)) begin
      busy_next[rd1_issue]         = 1'b1;
      load_pending_next[rd1_issue] = is_load1_issue;
    end
  end

  // Sequentially hold the scoreboard state.
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      busy            <= 32'h0;
      is_load_pending <= 32'h0;
    end else begin
      busy            <= busy_next;
      is_load_pending <= load_pending_next;
    end
  end

  // Flatten busy arrays for tracing.
  assign busy_vec         = busy;
  assign load_pending_vec = is_load_pending;

endmodule
