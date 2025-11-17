`timescale 1ns/1ps

import rv32i_pkg::*;

module branch_unit (
    input  logic [31:0] rs1_val,
    input  logic [31:0] rs2_val,
    input  branch_t     branch_type,
    output logic        take_branch
);

  always_comb begin
    case (branch_type)
      BR_EQ:  take_branch = (rs1_val == rs2_val);
      BR_NE:  take_branch = (rs1_val != rs2_val);
      BR_LT:  take_branch = ($signed(rs1_val) < $signed(rs2_val));
      BR_GE:  take_branch = ($signed(rs1_val) >= $signed(rs2_val));
      BR_LTU: take_branch = (rs1_val < rs2_val);
      BR_GEU: take_branch = (rs1_val >= rs2_val);
      default: take_branch = 1'b0;
    endcase
  end

endmodule
