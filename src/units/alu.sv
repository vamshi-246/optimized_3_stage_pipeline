`timescale 1ns/1ps

import rv32i_pkg::*;

module alu (
    input  logic [31:0] op_a,
    input  logic [31:0] op_b,
    input  alu_op_e     alu_op,
    output logic [31:0] result
);

  always_comb begin
    unique case (alu_op)
      ALU_ADD:  result = op_a + op_b;
      ALU_SUB:  result = op_a - op_b;
      ALU_SLL:  result = op_a << op_b[4:0];
      ALU_SLT:  result = ($signed(op_a) < $signed(op_b)) ? 32'd1 : 32'd0;
      ALU_SLTU: result = (op_a < op_b) ? 32'd1 : 32'd0;
      ALU_XOR:  result = op_a ^ op_b;
      ALU_SRL:  result = op_a >> op_b[4:0];
      ALU_SRA:  result = $signed(op_a) >>> op_b[4:0];
      ALU_OR:   result = op_a | op_b;
      ALU_AND:  result = op_a & op_b;
      default:  result = 32'h0;
    endcase
  end

endmodule
