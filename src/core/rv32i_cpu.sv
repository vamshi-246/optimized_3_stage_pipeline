`timescale 1ns/1ps

import rv32i_pkg::*;

module rv32i_cpu (
    input  logic        clk,
    input  logic        rst,
    // Instruction memory interface
    output logic [31:0] instr_addr,
    input  logic [31:0] instr_rdata,
    // Data memory interface
    output logic [31:0] data_addr,
    output logic [31:0] data_wdata,
    output logic [3:0]  data_we,
    output logic        data_re,
    input  logic [31:0] data_rdata,
    // Debug/trace visibility
    output logic [31:0] dbg_pc_f,
    output logic [31:0] dbg_instr_f,
    output logic [31:0] dbg_instr_d,
    output logic [31:0] dbg_instr_e,
    output logic [31:0] dbg_result_e,
    output logic        dbg_branch_taken
);

  localparam logic [31:0] NOP = 32'h00000013; // addi x0, x0, 0

  // Fetch stage
  logic [31:0] pc_f;
  logic [31:0] pc_next;
  logic [31:0] pc_plus4_f;
  logic [31:0] instr_f;

  assign instr_addr = pc_f;
  assign instr_f    = instr_rdata;
  assign pc_plus4_f = pc_f + 32'd4;

  // Fetch/Decode pipeline registers
  logic [31:0] fd_pc;
  logic [31:0] fd_instr;

  // Decode stage signals
  control_t ctrl_d;
  logic [4:0] rs1_d, rs2_d, rd_d;
  logic [31:0] imm_d;
  logic [31:0] rs1_val_d, rs2_val_d;

  // Decode/Execute pipeline registers
  logic [31:0] de_pc;
  logic [31:0] de_instr;
  control_t de_ctrl;
  logic [4:0] de_rs1, de_rs2, de_rd;
  logic [31:0] de_rs1_val, de_rs2_val;
  logic [31:0] de_imm;

  // Execute stage helpers
  logic [31:0] op1_e, op2_e;
  logic [31:0] alu_result_e;
  logic [31:0] branch_target_e;
  logic branch_cond_e;
  logic branch_taken_e;
  logic [31:0] load_data_e;
  logic [31:0] wb_data_e;

  // Register file instance
  regfile u_regfile (
      .clk    (clk),
      .rst    (rst),
      .we     (de_ctrl.reg_write),
      .waddr  (de_rd),
      .wdata  (wb_data_e),
      .raddr1 (rs1_d),
      .raddr2 (rs2_d),
      .rdata1 (rs1_val_d),
      .rdata2 (rs2_val_d)
  );

  decoder u_decoder (
      .instr (fd_instr),
      .ctrl  (ctrl_d),
      .rs1   (rs1_d),
      .rs2   (rs2_d),
      .rd    (rd_d)
  );

  imm_gen u_imm_gen (
      .instr  (fd_instr),
      .imm_sel(ctrl_d.imm_type),
      .imm    (imm_d)
  );

  alu u_alu (
      .op_a  (op1_e),
      .op_b  (op2_e),
      .alu_op(de_ctrl.alu_op),
      .result(alu_result_e)
  );

  branch_unit u_branch_unit (
      .rs1_val    (de_rs1_val),
      .rs2_val    (de_rs2_val),
      .branch_type(de_ctrl.branch_type),
      .take_branch(branch_cond_e)
  );

  // FETCH stage registers
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      pc_f     <= 32'h0;
      fd_pc    <= 32'h0;
      fd_instr <= NOP;
    end else begin
      pc_f  <= pc_next;
      fd_pc <= pc_f;
      fd_instr <= branch_taken_e ? NOP : instr_f; // flush on branch
    end
  end

  // DECODE/EXECUTE pipeline registers
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      de_pc      <= 32'h0;
      de_instr   <= NOP;
      de_ctrl    <= '0;
      de_rs1     <= 5'd0;
      de_rs2     <= 5'd0;
      de_rd      <= 5'd0;
      de_rs1_val <= 32'h0;
      de_rs2_val <= 32'h0;
      de_imm     <= 32'h0;
    end else if (branch_taken_e) begin
      // Flush decode stage when a branch resolves taken in execute
      de_pc      <= 32'h0;
      de_instr   <= NOP;
      de_ctrl    <= '0;
      de_rs1     <= 5'd0;
      de_rs2     <= 5'd0;
      de_rd      <= 5'd0;
      de_rs1_val <= 32'h0;
      de_rs2_val <= 32'h0;
      de_imm     <= 32'h0;
    end else begin
      de_pc      <= fd_pc;
      de_instr   <= fd_instr;
      de_ctrl    <= ctrl_d;
      de_rs1     <= rs1_d;
      de_rs2     <= rs2_d;
      de_rd      <= rd_d;
      de_rs1_val <= rs1_val_d;
      de_rs2_val <= rs2_val_d;
      de_imm     <= imm_d;
    end
  end

  // Operand selection
  always_comb begin
    unique case (de_ctrl.op1_sel)
      OP1_RS1:  op1_e = de_rs1_val;
      OP1_PC:   op1_e = de_pc;
      OP1_ZERO: op1_e = 32'h0;
      default:  op1_e = de_rs1_val;
    endcase
  end

  always_comb begin
    op2_e = (de_ctrl.op2_sel == OP2_IMM) ? de_imm : de_rs2_val;
  end

  // Branch and jump handling
  always_comb begin
    if (de_ctrl.jump && (de_instr[6:0] == 7'b1100111)) begin
      // JALR target needs LSB cleared
      branch_target_e = (de_rs1_val + de_imm) & ~32'h1;
    end else begin
      branch_target_e = de_pc + de_imm;
    end
  end

  assign branch_taken_e = (de_ctrl.branch && branch_cond_e) || de_ctrl.jump;

  // Data memory interface (no stalling, single-cycle view)
  logic [31:0] addr_e;
  logic [3:0]  be_e;
  logic [31:0] wdata_e;

  assign addr_e = de_rs1_val + de_imm;

  always_comb begin
    // Default store parameters
    be_e    = 4'b0000;
    wdata_e = de_rs2_val;

    if (de_ctrl.mem_write) begin
      unique case (de_ctrl.mem_funct3)
        3'b000: begin // SB
          be_e    = 4'b0001 << addr_e[1:0];
          wdata_e = {4{de_rs2_val[7:0]}} << (8 * addr_e[1:0]);
        end
        3'b001: begin // SH
          be_e    = addr_e[1] ? 4'b1100 : 4'b0011;
          wdata_e = {2{de_rs2_val[15:0]}} << (16 * addr_e[1]);
        end
        default: begin // SW
          be_e    = 4'b1111;
          wdata_e = de_rs2_val;
        end
      endcase
    end
  end

  // Load data sign/zero extension
  always_comb begin
    load_data_e = data_rdata;
    unique case (de_ctrl.mem_funct3)
      3'b000: begin // LB
        logic [7:0] b;
        b = data_rdata >> (8 * addr_e[1:0]);
        load_data_e = {{24{b[7]}}, b};
      end
      3'b100: begin // LBU
        logic [7:0] b;
        b = data_rdata >> (8 * addr_e[1:0]);
        load_data_e = {24'h0, b};
      end
      3'b001: begin // LH
        logic [15:0] h;
        h = data_rdata >> (16 * addr_e[1]);
        load_data_e = {{16{h[15]}}, h};
      end
      3'b101: begin // LHU
        logic [15:0] h;
        h = data_rdata >> (16 * addr_e[1]);
        load_data_e = {16'h0, h};
      end
      default: load_data_e = data_rdata; // LW and default
    endcase
  end

  // Write-back selection
  always_comb begin
    unique case (de_ctrl.wb_sel)
      WB_MEM: wb_data_e = load_data_e;
      WB_PC4: wb_data_e = de_pc + 32'd4;
      WB_IMM: wb_data_e = de_imm;
      default: wb_data_e = alu_result_e;
    endcase
  end

  // Output assignments
  assign data_addr  = addr_e;
  assign data_wdata = wdata_e;
  assign data_we    = de_ctrl.mem_write ? be_e : 4'b0000;
  assign data_re    = de_ctrl.mem_read;

  assign pc_next = branch_taken_e ? branch_target_e : pc_plus4_f;

  // Debug/trace
  assign dbg_pc_f         = pc_f;
  assign dbg_instr_f      = instr_f;
  assign dbg_instr_d      = fd_instr;
  assign dbg_instr_e      = de_instr;
  assign dbg_result_e     = wb_data_e;
  assign dbg_branch_taken = branch_taken_e;

endmodule
