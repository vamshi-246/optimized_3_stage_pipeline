`timescale 1ns/1ps

// Simple EX->ID forwarding unit for the 3-stage RV32I pipeline.
// - For ALU/branch dependencies, forwards the result from EX to the
//   Decode-stage operands when rs1/rs2 match rd_ex.
// - Load-use hazards are not resolved by forwarding; they must be
//   handled by the hazard_unit through a stall.
module forward_unit (
    // ID stage register indices and raw register file values
    input  logic [4:0]  rs1_id,
    input  logic [4:0]  rs2_id,
    input  logic [31:0] rs1_data_id,
    input  logic [31:0] rs2_data_id,

    // EX stage write-back information
    input  logic [4:0]  rd_ex,
    input  logic        reg_write_ex,
    input  logic        is_load_ex,
    input  logic [31:0] ex_result,

    // Forwarded values to use in ID
    output logic [31:0] fwd_rs1,
    output logic [31:0] fwd_rs2,
    output logic        fwd_rs1_en,
    output logic        fwd_rs2_en
);

  always_comb begin
    // Defaults: no forwarding, use register file values
    fwd_rs1    = rs1_data_id;
    fwd_rs2    = rs2_data_id;
    fwd_rs1_en = 1'b0;
    fwd_rs2_en = 1'b0;

    // Forward from EX stage when it writes a non-zero register and
    // is not a load (loads are handled by stalling instead).
    if (reg_write_ex && !is_load_ex && (rd_ex != 5'd0)) begin
      if (rs1_id == rd_ex) begin
        fwd_rs1    = ex_result;
        fwd_rs1_en = 1'b1;
      end
      if (rs2_id == rd_ex) begin
        fwd_rs2    = ex_result;
        fwd_rs2_en = 1'b1;
      end
    end
  end

endmodule

