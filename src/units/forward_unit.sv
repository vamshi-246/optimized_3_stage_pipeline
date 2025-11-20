`timescale 1ns/1ps

// Simple EX->ID forwarding unit for the 3-stage RV32I pipeline.
// - For ALU/branch dependencies, forwards the result from EX to the
//   Decode-stage operands when rs1/rs2 match rd_ex.
// - Load-use hazards are not resolved by forwarding; they are handled
//   by the scoreboard/issue logic inserting a stall.

module forward_unit (
    // Slot0 ID sources and raw register file values
    input  logic [4:0]  rs1_0_id,
    input  logic [4:0]  rs2_0_id,
    input  logic [31:0] rs1_0_reg,
    input  logic [31:0] rs2_0_reg,

    // Slot1 ID sources and raw register file values
    input  logic [4:0]  rs1_1_id,
    input  logic [4:0]  rs2_1_id,
    input  logic [31:0] rs1_1_reg,
    input  logic [31:0] rs2_1_reg,

    // EX0 stage write-back information (older)
    input  logic [4:0]  rd_ex0,
    input  logic        reg_write_ex0,
    input  logic        is_load_ex0,
    input  logic [31:0] ex0_result,

    // EX1 stage write-back information (younger)
    input  logic [4:0]  rd_ex1,
    input  logic        reg_write_ex1,
    input  logic        is_load_ex1,
    input  logic [31:0] ex1_result,

    // Forwarded values to use in ID0
    output logic [31:0] fwd_rs1_0,
    output logic [31:0] fwd_rs2_0,
    output logic        fwd_rs1_0_en,
    output logic        fwd_rs2_0_en,

    // Forwarded values to use in ID1
    output logic [31:0] fwd_rs1_1,
    output logic [31:0] fwd_rs2_1
);

  always_comb begin
    // Defaults: no forwarding, use register file values
    fwd_rs1_0    = rs1_0_reg;
    fwd_rs2_0    = rs2_0_reg;
    fwd_rs1_0_en = 1'b0;
    fwd_rs2_0_en = 1'b0;

    fwd_rs1_1    = rs1_1_reg;
    fwd_rs2_1    = rs2_1_reg;

    // Slot0 forwarding: EX0 -> ID0 only.
    if (reg_write_ex0 && !is_load_ex0 && (rd_ex0 != 5'd0)) begin
      if (rs1_0_id == rd_ex0) begin
        fwd_rs1_0    = ex0_result;
        fwd_rs1_0_en = 1'b1;
      end
      if (rs2_0_id == rd_ex0) begin
        fwd_rs2_0    = ex0_result;
        fwd_rs2_0_en = 1'b1;
      end
    end

    // Slot1 forwarding: EX1 has priority, then EX0. This guarantees that a
    // younger slot taking the same destination register always observes its
    // own result first, even when EX0 is also writing elsewhere.
    // EX1 -> ID1
    if (reg_write_ex1 && !is_load_ex1 && (rd_ex1 != 5'd0)) begin
      if (rs1_1_id == rd_ex1) begin
        fwd_rs1_1 = ex1_result;
      end
      if (rs2_1_id == rd_ex1) begin
        fwd_rs2_1 = ex1_result;
      end
    end

    // EX0 -> ID1 (only if EX1 did not already match)
    if (reg_write_ex0 && !is_load_ex0 && (rd_ex0 != 5'd0)) begin
      if ((rs1_1_id == rd_ex0) && !(reg_write_ex1 && !is_load_ex1 && (rd_ex1 == rs1_1_id))) begin
        fwd_rs1_1 = ex0_result;
      end
      if ((rs2_1_id == rd_ex0) && !(reg_write_ex1 && !is_load_ex1 && (rd_ex1 == rs2_1_id))) begin
        fwd_rs2_1 = ex0_result;
      end
    end
  end

endmodule
