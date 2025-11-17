`timescale 1ns/1ps

import rv32i_pkg::*;

module decoder (
    input  logic [31:0] instr,
    output control_t    ctrl,
    output logic [4:0]  rs1,
    output logic [4:0]  rs2,
    output logic [4:0]  rd
);

  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [6:0] funct7;

  assign opcode = instr[6:0];
  assign funct3 = instr[14:12];
  assign funct7 = instr[31:25];
  assign rs1    = instr[19:15];
  assign rs2    = instr[24:20];
  assign rd     = instr[11:7];

  always_comb begin
    // Defaults implement NOP (addi x0, x0, 0)
    ctrl.imm_type    = IMM_I;
    ctrl.op1_sel     = OP1_RS1;
    ctrl.op2_sel     = OP2_IMM;
    ctrl.alu_op      = ALU_ADD;
    ctrl.branch_type = BR_EQ;
    ctrl.branch      = 1'b0;
    ctrl.jump        = 1'b0;
    ctrl.mem_read    = 1'b0;
    ctrl.mem_write   = 1'b0;
    ctrl.mem_funct3  = 3'b000;
    ctrl.reg_write   = 1'b0;
    ctrl.wb_sel      = WB_ALU;
    ctrl.is_lui      = 1'b0;
    ctrl.is_auipc    = 1'b0;

    unique case (opcode)
      7'b0110011: begin // R-type
        ctrl.op2_sel  = OP2_RS2;
        ctrl.reg_write = 1'b1;
        ctrl.wb_sel    = WB_ALU;
        unique case ({funct7, funct3})
          10'b0000000_000: ctrl.alu_op = ALU_ADD;
          10'b0100000_000: ctrl.alu_op = ALU_SUB;
          10'b0000000_001: ctrl.alu_op = ALU_SLL;
          10'b0000000_010: ctrl.alu_op = ALU_SLT;
          10'b0000000_011: ctrl.alu_op = ALU_SLTU;
          10'b0000000_100: ctrl.alu_op = ALU_XOR;
          10'b0000000_101: ctrl.alu_op = ALU_SRL;
          10'b0100000_101: ctrl.alu_op = ALU_SRA;
          10'b0000000_110: ctrl.alu_op = ALU_OR;
          10'b0000000_111: ctrl.alu_op = ALU_AND;
          default: ctrl.alu_op = ALU_ADD;
        endcase
      end

      7'b0010011: begin // I-type ALU immediate
        ctrl.reg_write = 1'b1;
        ctrl.wb_sel    = WB_ALU;
        ctrl.op2_sel   = OP2_IMM;
        ctrl.imm_type  = IMM_I;
        unique case (funct3)
          3'b000: ctrl.alu_op = ALU_ADD;                  // ADDI
          3'b010: ctrl.alu_op = ALU_SLT;                  // SLTI
          3'b011: ctrl.alu_op = ALU_SLTU;                 // SLTIU
          3'b100: ctrl.alu_op = ALU_XOR;                  // XORI
          3'b110: ctrl.alu_op = ALU_OR;                   // ORI
          3'b111: ctrl.alu_op = ALU_AND;                  // ANDI
          3'b001: begin // SLLI
            ctrl.alu_op  = ALU_SLL;
            ctrl.imm_type = IMM_Z;
          end
          3'b101: begin // SRLI/SRAI
            ctrl.imm_type = IMM_Z;
            ctrl.alu_op   = (funct7[5]) ? ALU_SRA : ALU_SRL;
          end
          default: ctrl.alu_op = ALU_ADD;
        endcase
      end

      7'b0000011: begin // Loads
        ctrl.reg_write = 1'b1;
        ctrl.mem_read  = 1'b1;
        ctrl.wb_sel    = WB_MEM;
        ctrl.op2_sel   = OP2_IMM;
        ctrl.imm_type  = IMM_I;
        ctrl.alu_op    = ALU_ADD; // address calc
        ctrl.mem_funct3 = funct3;
      end

      7'b0100011: begin // Stores
        ctrl.mem_write = 1'b1;
        ctrl.op2_sel   = OP2_IMM;
        ctrl.imm_type  = IMM_S;
        ctrl.alu_op    = ALU_ADD;
        ctrl.mem_funct3 = funct3;
      end

      7'b1100011: begin // Branches
        ctrl.branch    = 1'b1;
        ctrl.op2_sel   = OP2_RS2;
        ctrl.imm_type  = IMM_B;
        ctrl.alu_op    = ALU_ADD; // unused
        unique case (funct3)
          3'b000: ctrl.branch_type = BR_EQ;
          3'b001: ctrl.branch_type = BR_NE;
          3'b100: ctrl.branch_type = BR_LT;
          3'b101: ctrl.branch_type = BR_GE;
          3'b110: ctrl.branch_type = BR_LTU;
          3'b111: ctrl.branch_type = BR_GEU;
          default: ctrl.branch_type = BR_EQ;
        endcase
      end

      7'b1101111: begin // JAL
        ctrl.jump       = 1'b1;
        ctrl.reg_write  = 1'b1;
        ctrl.imm_type   = IMM_J;
        ctrl.wb_sel     = WB_PC4;
        ctrl.op1_sel    = OP1_PC;
        ctrl.op2_sel    = OP2_IMM;
        ctrl.alu_op     = ALU_ADD;
      end

      7'b1100111: begin // JALR
        ctrl.jump       = 1'b1;
        ctrl.reg_write  = 1'b1;
        ctrl.imm_type   = IMM_I;
        ctrl.wb_sel     = WB_PC4;
        ctrl.op1_sel    = OP1_RS1;
        ctrl.op2_sel    = OP2_IMM;
        ctrl.alu_op     = ALU_ADD;
      end

      7'b0110111: begin // LUI
        ctrl.reg_write = 1'b1;
        ctrl.imm_type  = IMM_U;
        ctrl.wb_sel    = WB_IMM;
        ctrl.op1_sel   = OP1_ZERO;
        ctrl.op2_sel   = OP2_IMM;
        ctrl.is_lui    = 1'b1;
        ctrl.alu_op    = ALU_ADD;
      end

      7'b0010111: begin // AUIPC
        ctrl.reg_write = 1'b1;
        ctrl.imm_type  = IMM_U;
        ctrl.wb_sel    = WB_ALU;
        ctrl.op1_sel   = OP1_PC;
        ctrl.op2_sel   = OP2_IMM;
        ctrl.is_auipc  = 1'b1;
        ctrl.alu_op    = ALU_ADD;
      end

      default: begin
        // keep NOP defaults
      end
    endcase
  end

endmodule
