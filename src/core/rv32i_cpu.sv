`timescale 1ns/1ps

import rv32i_pkg::*;

module rv32i_cpu (
    input  logic        clk,
    input  logic        rst,
    // Instruction memory interface
    output logic [31:0] instr_addr,
    input  logic [31:0] instr_rdata,
    // Second instruction fetch slot (PC+4)
    output logic [31:0] instr_addr1,
    input  logic [31:0] instr_rdata1,
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
    // Slot1 execute-stage instruction (for debug / system detection in TB)
    output logic [31:0] dbg_instr_e1,
    output logic [31:0] dbg_result_e,
    output logic [31:0] dbg_result_e1,
    output logic        dbg_branch_taken,
    output logic        dbg_branch_taken1,
    output logic        dbg_jump_taken,
    output logic        dbg_jump_taken1,
    output logic [31:0] dbg_jump_target,
    output logic [31:0] dbg_jump_target1,
    output logic        dbg_stall,
    output logic        dbg_fwd_rs1,
    output logic        dbg_fwd_rs2,
    output logic [31:0] dbg_busy_vec
);

  localparam logic [31:0] NOP = 32'h00000013; // addi x0, x0, 0

  // Fetch stage
  logic [31:0] pc_f;
  logic [31:0] pc_next;
  logic [31:0] pc_plus4_f;
  logic [31:0] pc_plus8_f;
  logic [31:0] instr0_f, instr1_f;

  // Dual fetch addresses: slot0 at PC, slot1 at PC+4
  assign instr_addr  = pc_f;
  assign instr_addr1 = pc_f + 32'd4;
  assign instr0_f    = instr_rdata;
  assign instr1_f    = instr_rdata1;
  assign pc_plus4_f  = pc_f + 32'd4;
  assign pc_plus8_f  = pc_f + 32'd8;

  // Fetch/Decode pipeline registers
  logic [31:0] fd_pc;
  logic [31:0] fd_instr;
  logic [31:0] fd_instr1;

  // Decode stage signals (slot 0 = older, slot 1 = younger)
  control_t ctrl_d;      // slot 0 control
  control_t ctrl1_d;     // slot 1 control
  logic [4:0] rs1_d, rs2_d, rd_d;
  logic [4:0] rs1_1_d, rs2_1_d, rd1_d;
  logic       use_rs1_d, use_rs2_d;
  logic       use_rs1_1_d, use_rs2_1_d;
  logic [31:0] imm_d;
  logic [31:0] imm1_d;
  logic [31:0] rs1_val_d, rs2_val_d;
  logic [31:0] rs1_val1_d, rs2_val1_d;
  logic [31:0] rs1_val_d_fwd, rs2_val_d_fwd;
  logic [31:0] rs1_val1_d_fwd, rs2_val1_d_fwd;

  // Decode/Execute pipeline registers
  logic [31:0] de_pc;
  logic [31:0] de_instr;
  control_t de_ctrl;
  logic [4:0] de_rs1, de_rs2, de_rd;
  logic [31:0] de_rs1_val, de_rs2_val;
  logic [31:0] de_imm;
  // Slot 1 (younger) pipeline registers - currently kept as bubbles
  logic [31:0] de1_pc;
  logic [31:0] de1_instr;
  control_t de1_ctrl;
  logic [4:0] de1_rs1, de1_rs2, de1_rd;
  logic [31:0] de1_rs1_val, de1_rs2_val;
  logic [31:0] de1_imm;

  // Execute stage helpers
  logic [31:0] op1_e0, op2_e0;
  logic [31:0] op1_e1, op2_e1;
  logic [31:0] alu_result_e0, alu_result_e1;
  logic [31:0] branch_target_e, branch_target_e1;
  logic [31:0] jump_target_e, jump_target_e1;
  logic branch_cond_e, branch_cond_e1;
  logic branch_taken_e, branch_taken_e1;
  logic jump_taken_e, jump_taken_e1;
  logic [31:0] load_data_e0, load_data_e1;
  logic [31:0] wb_data_e0, wb_data_e1;

  // Hazard / forwarding controls
  logic        stall_if_id;
  logic        is_load_ex;
  logic        fwd_rs1_en, fwd_rs2_en;
  // Scoreboard signals
  logic [31:0] busy_vec;
  logic [31:0] load_pending_vec;
  logic        raw_hazard1;
  logic        waw_hazard1;
  logic        load_use0_h, load_use1_h;
  // Issue decisions
  logic        issue_slot0_raw, issue_slot1_raw;
  logic        issue_slot0, issue_slot1;
  // Simple validity markers for decode slots
  logic        slot0_valid, slot1_valid;

  // Register file instance: 4R / 2W logical implementation.
  // Slot0 (older) uses write port 0. Slot1 uses write port 1 only for safe ALU ops.
  regfile u_regfile (
      .clk      (clk),
      .rst      (rst),
      .we0      (de_ctrl.reg_write),
      .waddr0   (de_rd),
      .wdata0   (wb_data_e0),
      // Slot1: enable writeback only for pure ALU ops (no mem, no branches/jumps,
      // no LUI/AUIPC). This ensures we only turn on EX1 execution for the safe
      // subset requested for this step.
      .we1      (de1_ctrl.reg_write &&
                 !de1_ctrl.mem_write &&
                 !de1_ctrl.branch &&
                 !de1_ctrl.is_lui &&
                 !de1_ctrl.is_auipc),
      .waddr1   (de1_rd),
      .wdata1   (wb_data_e1),
      .raddr0_1 (rs1_d),
      .raddr0_2 (rs2_d),
      .rdata0_1 (rs1_val_d),
      .rdata0_2 (rs2_val_d),
      .raddr1_1 (rs1_1_d),
      .raddr1_2 (rs2_1_d),
      .rdata1_1 (rs1_val1_d),
      .rdata1_2 (rs2_val1_d)
  );

  decoder u_decoder (
      .instr (fd_instr),
      .ctrl  (ctrl_d),
      .rs1   (rs1_d),
      .rs2   (rs2_d),
      .rd    (rd_d),
      .use_rs1(use_rs1_d),
      .use_rs2(use_rs2_d)
  );

  decoder u_decoder1 (
      .instr (fd_instr1),
      .ctrl  (ctrl1_d),
      .rs1   (rs1_1_d),
      .rs2   (rs2_1_d),
      .rd    (rd1_d),
      .use_rs1(use_rs1_1_d),
      .use_rs2(use_rs2_1_d)
  );

  imm_gen u_imm_gen (
      .instr  (fd_instr),
      .imm_sel(ctrl_d.imm_type),
      .imm    (imm_d)
  );

  imm_gen u_imm_gen1 (
      .instr  (fd_instr1),
      .imm_sel(ctrl1_d.imm_type),
      .imm    (imm1_d)
  );

  // Classify EX slot0 instruction as load (used by forwarding and scoreboard).
  assign is_load_ex = de_ctrl.mem_read && !de_ctrl.mem_write;

  // Mini-scoreboard: track pending writes and classify hazards seen in ID.
  reg_status_table u_reg_status_table (
      .clk                (clk),
      .rst                (rst),
      // Issue-stage info (already gated by issue_slot*)
      .issue0             (issue_slot0),
      .issue1             (issue_slot1),
      .reg_write0_issue   (ctrl_d.reg_write),
      .reg_write1_issue   (ctrl1_d.reg_write),
      .rd0_issue          (rd_d),
      .rd1_issue          (rd1_d),
      .is_load0_issue     (ctrl_d.mem_read && !ctrl_d.mem_write),
      .is_load1_issue     (ctrl1_d.mem_read && !ctrl1_d.mem_write),
      .rs1_0              (rs1_d),
      .rs2_0              (rs2_d),
      .rs1_1              (rs1_1_d),
      .rs2_1              (rs2_1_d),
      .use_rs1_0          (use_rs1_d),
      .use_rs2_0          (use_rs2_d),
      .use_rs1_1          (use_rs1_1_d),
      .use_rs2_1          (use_rs2_1_d),
      // Writeback completions this cycle
      .wb0_we             (de_ctrl.reg_write && (de_rd != 5'd0)),
      .wb0_rd             (de_rd),
      .wb1_we             (de1_ctrl.reg_write && (de1_rd != 5'd0)),
      .wb1_rd             (de1_rd),
      // Hazard outputs
      .raw_hazard1        (raw_hazard1),
      .waw_hazard1        (waw_hazard1),
      .load_use0          (load_use0_h),
      .load_use1          (load_use1_h),
      .busy_vec           (busy_vec),
      .load_pending_vec   (load_pending_vec)
  );

  // Issue unit: decides whether slot0/slot1 are allowed to issue this cycle.
  issue_unit u_issue_unit (
      .ctrl0          (ctrl_d),
      .ctrl1          (ctrl1_d),
      .raw_hazard1    (raw_hazard1),
      .waw_hazard1    (waw_hazard1),
      .load_use0      (load_use0_h),
      .load_use1      (load_use1_h),
      .issue_slot0    (issue_slot0_raw),
      .issue_slot1    (issue_slot1_raw),
      .stall_if       (stall_if_id)
  );

  // Issue gating:
  // - Always allow slot0 when not stalled.
  // - Allow slot1 only when the issue unit deems it safe, the pipeline is
  //   not stalled by slot0 hazards, and both decode slots contain real
  //   instructions (not synthetic NOPs).
  assign issue_slot0 = issue_slot0_raw & ~stall_if_id;
  assign issue_slot1 = issue_slot1_raw & ~stall_if_id & slot0_valid & slot1_valid;

  // Forwarding from EX results into ID operands (for ALU/branch).
  forward_unit u_forward_unit (
      // Slot0 ID sources
      .rs1_0_id      (rs1_d),
      .rs2_0_id      (rs2_d),
      .rs1_0_reg     (rs1_val_d),
      .rs2_0_reg     (rs2_val_d),
      // Slot1 ID sources
      .rs1_1_id      (rs1_1_d),
      .rs2_1_id      (rs2_1_d),
      .rs1_1_reg     (rs1_val1_d),
      .rs2_1_reg     (rs2_val1_d),
      // EX0 info
      .rd_ex0        (de_rd),
      .reg_write_ex0 (de_ctrl.reg_write),
      .is_load_ex0   (is_load_ex),
      .ex0_result    (wb_data_e0),
      // EX1 info (slot1 loads are still disabled, so is_load_ex1 is 0)
      .rd_ex1        (de1_rd),
      .reg_write_ex1 (de1_ctrl.reg_write),
      .is_load_ex1   (de1_ctrl.mem_read && !de1_ctrl.mem_write),
      .ex1_result    (wb_data_e1),
      // Outputs
      .fwd_rs1_0     (rs1_val_d_fwd),
      .fwd_rs2_0     (rs2_val_d_fwd),
      .fwd_rs1_0_en  (fwd_rs1_en),
      .fwd_rs2_0_en  (fwd_rs2_en),
      .fwd_rs1_1     (rs1_val1_d_fwd),
      .fwd_rs2_1     (rs2_val1_d_fwd)
  );

  // FETCH stage registers
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      pc_f     <= 32'h0;
      fd_pc    <= 32'h0;
      fd_instr <= NOP;
      fd_instr1 <= NOP;
    end else if (stall_if_id) begin
      // Hold PC and IF/ID on a hazard stall
      pc_f     <= pc_f;
      fd_pc    <= fd_pc;
      fd_instr <= fd_instr;
      fd_instr1 <= fd_instr1;
    end else begin
      pc_f  <= pc_next;
      fd_pc <= pc_f;
      // flush both fetched instructions on branch taken
      fd_instr  <= redirect_taken_any ? NOP : instr0_f;
      fd_instr1 <= redirect_taken_any ? NOP : instr1_f;
    end
  end

  // Treat a slot as valid only when its fetched instruction is not the NOP
  // we use for bubbles/reset.
  assign slot0_valid = (fd_instr  != NOP);
  assign slot1_valid = (fd_instr1 != NOP);

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
      de1_pc      <= 32'h0;
      de1_instr   <= NOP;
      de1_ctrl    <= '0;
      de1_rs1     <= 5'd0;
      de1_rs2     <= 5'd0;
      de1_rd      <= 5'd0;
      de1_rs1_val <= 32'h0;
      de1_rs2_val <= 32'h0;
      de1_imm     <= 32'h0;
    end else if (redirect_taken_any) begin
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
      de1_pc      <= 32'h0;
      de1_instr   <= NOP;
      de1_ctrl    <= '0;
      de1_rs1     <= 5'd0;
      de1_rs2     <= 5'd0;
      de1_rd      <= 5'd0;
      de1_rs1_val <= 32'h0;
      de1_rs2_val <= 32'h0;
      de1_imm     <= 32'h0;
    end else begin
      // Slot0: issue or bubble
      if (issue_slot0) begin
        de_pc      <= fd_pc;
        de_instr   <= fd_instr;
        de_ctrl    <= ctrl_d;
        de_rs1     <= rs1_d;
        de_rs2     <= rs2_d;
        de_rd      <= rd_d;
        de_rs1_val <= rs1_val_d_fwd;
        de_rs2_val <= rs2_val_d_fwd;
        de_imm     <= imm_d;
      end else begin
        de_pc      <= 32'h0;
        de_instr   <= NOP;
        de_ctrl    <= '0;
        de_rs1     <= 5'd0;
        de_rs2     <= 5'd0;
        de_rd      <= 5'd0;
        de_rs1_val <= 32'h0;
        de_rs2_val <= 32'h0;
        de_imm     <= 32'h0;
      end

      // Slot1: issue when legal, else bubble
      if (issue_slot1) begin
        de1_pc      <= fd_pc + 32'd4;
        de1_instr   <= fd_instr1;
        de1_ctrl    <= ctrl1_d;
        de1_rs1     <= rs1_1_d;
        de1_rs2     <= rs2_1_d;
        de1_rd      <= rd1_d;
        de1_rs1_val <= rs1_val1_d_fwd;
        de1_rs2_val <= rs2_val1_d_fwd;
        de1_imm     <= imm1_d;
      end else begin
        de1_pc      <= 32'h0;
        de1_instr   <= NOP;
        de1_ctrl    <= '0;
        de1_rs1     <= 5'd0;
        de1_rs2     <= 5'd0;
        de1_rd      <= 5'd0;
        de1_rs1_val <= 32'h0;
        de1_rs2_val <= 32'h0;
        de1_imm     <= 32'h0;
      end
    end
  end

  // Operand selection for slot0
  always_comb begin
    unique case (de_ctrl.op1_sel)
      OP1_RS1:  op1_e0 = de_rs1_val;
      OP1_PC:   op1_e0 = de_pc;
      OP1_ZERO: op1_e0 = 32'h0;
      default:  op1_e0 = de_rs1_val;
    endcase
  end

  always_comb begin
    op2_e0 = (de_ctrl.op2_sel == OP2_IMM) ? de_imm : de_rs2_val;
  end

  // Operand selection for slot1
  always_comb begin
    unique case (de1_ctrl.op1_sel)
      OP1_RS1:  op1_e1 = de1_rs1_val;
      OP1_PC:   op1_e1 = de1_pc;
      OP1_ZERO: op1_e1 = 32'h0;
      default:  op1_e1 = de1_rs1_val;
    endcase
  end

  always_comb begin
    op2_e1 = (de1_ctrl.op2_sel == OP2_IMM) ? de1_imm : de1_rs2_val;
  end

  // Branch and jump handling (slot0)
  logic branch_cmp0, branch_cmp1;
  branch_unit u_branch0 (
      .rs1_val    (de_rs1_val),
      .rs2_val    (de_rs2_val),
      .branch_type(de_ctrl.branch_type),
      .take_branch(branch_cmp0)
  );
  assign branch_cond_e = de_ctrl.branch ? branch_cmp0 : 1'b0;
  assign branch_target_e = de_pc + de_imm;

  always_comb begin
    if (de_ctrl.is_jalr) begin
      jump_target_e = (de_rs1_val + de_imm) & ~32'h1;
    end else begin
      jump_target_e = de_pc + de_imm;
    end
  end

  assign branch_taken_e = (de_instr != NOP) &&
                          (de_ctrl.branch && branch_cond_e);
  assign jump_taken_e   = (de_instr != NOP) && de_ctrl.jump;

  // Slot1 branch handling (now with jump support)
  branch_unit u_branch1 (
      .rs1_val    (de1_rs1_val),
      .rs2_val    (de1_rs2_val),
      .branch_type(de1_ctrl.branch_type),
      .take_branch(branch_cmp1)
  );
  assign branch_cond_e1  = de1_ctrl.branch ? branch_cmp1 : 1'b0;
  assign branch_target_e1 = de1_pc + de1_imm;

  always_comb begin
    if (de1_ctrl.is_jalr) begin
      jump_target_e1 = (de1_rs1_val + de1_imm) & ~32'h1;
    end else begin
      jump_target_e1 = de1_pc + de1_imm;
    end
  end

  assign branch_taken_e1 = (de1_instr != NOP) &&
                           (de1_ctrl.branch && branch_cond_e1);
  assign jump_taken_e1   = (de1_instr != NOP) && de1_ctrl.jump;

  // Combined redirect priority: slot0 (branch/jump) first, then slot1.
  logic redirect_taken0, redirect_taken1;
  logic [31:0] redirect_target0, redirect_target1;
  logic redirect_taken_any;
  logic [31:0] redirect_target_any;

  assign redirect_taken0  = branch_taken_e || jump_taken_e;
  assign redirect_target0 = jump_taken_e ? jump_target_e : branch_target_e;

  assign redirect_taken1  = branch_taken_e1 || jump_taken_e1;
  assign redirect_target1 = jump_taken_e1 ? jump_target_e1 : branch_target_e1;

  assign redirect_taken_any  = redirect_taken0 || redirect_taken1;
  assign redirect_target_any = redirect_taken0 ? redirect_target0 :
                               redirect_taken1 ? redirect_target1 : 32'h0;

  // Data memory interface (single port, slot0 priority)
  logic [31:0] addr_e0;
  logic [31:0] addr_e1;
  logic [3:0]  be_e;
  logic [31:0] wdata_e;
  logic [3:0]  be_e1;
  logic [31:0] wdata_e1;
  logic        use_mem0;
  logic        use_mem1;

  assign addr_e0 = de_rs1_val + de_imm;
  assign addr_e1 = de1_rs1_val + de1_imm;

  always_comb begin
    // Default store parameters
    be_e    = 4'b0000;
    wdata_e = de_rs2_val;

    if (de_ctrl.mem_write) begin
      unique case (de_ctrl.mem_funct3)
        3'b000: begin // SB
          be_e    = 4'b0001 << addr_e0[1:0];
          wdata_e = {4{de_rs2_val[7:0]}} << (8 * addr_e0[1:0]);
        end
        3'b001: begin // SH
          be_e    = addr_e0[1] ? 4'b1100 : 4'b0011;
          wdata_e = {2{de_rs2_val[15:0]}} << (16 * addr_e0[1]);
        end
        default: begin // SW
          be_e    = 4'b1111;
          wdata_e = de_rs2_val;
        end
      endcase
    end
  end

  // Memory port arbitration: slot0 owns the port unless idle; slot1 may use
  // the port (load/store) only when slot0 is not doing memory.
  assign use_mem0 = de_ctrl.mem_read || de_ctrl.mem_write;
  assign use_mem1 = (!use_mem0) && (de1_ctrl.mem_read || de1_ctrl.mem_write);

  assign data_addr  = use_mem0 ? addr_e0 : use_mem1 ? addr_e1 : 32'h0;
  assign data_wdata = use_mem0 ? wdata_e : use_mem1 ? wdata_e1 : 32'h0;
  assign data_we    = (use_mem0 && de_ctrl.mem_write) ? be_e :
                      (use_mem1 && de1_ctrl.mem_write) ? be_e1 : 4'b0000;
  assign data_re    = (use_mem0 && de_ctrl.mem_read) ||
                      (use_mem1 && de1_ctrl.mem_read);

  // Load data sign/zero extension for slot0
  always_comb begin
    load_data_e0 = data_rdata;
    unique case (de_ctrl.mem_funct3)
      3'b000: begin // LB
        logic [7:0] b;
        b = data_rdata >> (8 * addr_e0[1:0]);
        load_data_e0 = {{24{b[7]}}, b};
      end
      3'b100: begin // LBU
        logic [7:0] b;
        b = data_rdata >> (8 * addr_e0[1:0]);
        load_data_e0 = {24'h0, b};
      end
      3'b001: begin // LH
        logic [15:0] h;
        h = data_rdata >> (16 * addr_e0[1]);
        load_data_e0 = {{16{h[15]}}, h};
      end
      3'b101: begin // LHU
        logic [15:0] h;
        h = data_rdata >> (16 * addr_e0[1]);
        load_data_e0 = {16'h0, h};
      end
      default: load_data_e0 = data_rdata; // LW and default
    endcase
  end

  // Load data sign/zero extension for slot1 (reuses shared data_rdata)
  always_comb begin
    load_data_e1 = data_rdata;
    unique case (de1_ctrl.mem_funct3)
      3'b000: begin // LB
        logic [7:0] b1;
        b1 = data_rdata >> (8 * addr_e1[1:0]);
        load_data_e1 = {{24{b1[7]}}, b1};
      end
      3'b100: begin // LBU
        logic [7:0] b1;
        b1 = data_rdata >> (8 * addr_e1[1:0]);
        load_data_e1 = {24'h0, b1};
      end
      3'b001: begin // LH
        logic [15:0] h1;
        h1 = data_rdata >> (16 * addr_e1[1]);
        load_data_e1 = {{16{h1[15]}}, h1};
      end
      3'b101: begin // LHU
        logic [15:0] h1;
        h1 = data_rdata >> (16 * addr_e1[1]);
        load_data_e1 = {16'h0, h1};
      end
      default: load_data_e1 = data_rdata; // LW and default
    endcase
  end

  // Store data formatting for slot1
  always_comb begin
    be_e1    = 4'b0000;
    wdata_e1 = de1_rs2_val;

    if (de1_ctrl.mem_write) begin
      unique case (de1_ctrl.mem_funct3)
        3'b000: begin // SB
          be_e1    = 4'b0001 << addr_e1[1:0];
          wdata_e1 = {4{de1_rs2_val[7:0]}} << (8 * addr_e1[1:0]);
        end
        3'b001: begin // SH
          be_e1    = addr_e1[1] ? 4'b1100 : 4'b0011;
          wdata_e1 = {2{de1_rs2_val[15:0]}} << (16 * addr_e1[1]);
        end
        default: begin // SW
          be_e1    = 4'b1111;
          wdata_e1 = de1_rs2_val;
        end
      endcase
    end
  end

  // Write-back selection for slot0 and slot1
  always_comb begin
    unique case (de_ctrl.wb_sel)
      WB_MEM: wb_data_e0 = load_data_e0;
      WB_PC4: wb_data_e0 = de_pc + 32'd4;
      WB_IMM: wb_data_e0 = de_imm;
      default: wb_data_e0 = alu_result_e0;
    endcase

    unique case (de1_ctrl.wb_sel)
      WB_MEM: wb_data_e1 = load_data_e1;   // slot1 load uses shared data port
      WB_PC4: wb_data_e1 = de1_pc + 32'd4;
      WB_IMM: wb_data_e1 = de1_imm;
      default: wb_data_e1 = alu_result_e1;
    endcase
  end

  // Next PC: branch target wins (slot0 priority, then slot1), otherwise advance
  // by 4 or 8 depending on whether slot1 issued in this cycle.
  assign pc_next = redirect_taken_any ? redirect_target_any
                                      : (issue_slot1 ? pc_plus8_f : pc_plus4_f);

  // Debug/trace
  assign dbg_pc_f         = pc_f;
  assign dbg_instr_f      = instr0_f;
  assign dbg_instr_d      = fd_instr;
  assign dbg_instr_e      = de_instr;
  assign dbg_instr_e1     = de1_instr;
  assign dbg_result_e     = wb_data_e0;
  assign dbg_result_e1    = wb_data_e1;
  assign dbg_branch_taken = branch_taken_e;
  assign dbg_branch_taken1= branch_taken_e1;
  assign dbg_jump_taken   = jump_taken_e;
  assign dbg_jump_taken1  = jump_taken_e1;
  assign dbg_jump_target  = jump_target_e;
  assign dbg_jump_target1 = jump_target_e1;
  // Stage-2/2.5 debug indicators
  assign dbg_stall        = stall_if_id;
  assign dbg_fwd_rs1      = fwd_rs1_en;
  assign dbg_fwd_rs2      = fwd_rs2_en;
  assign dbg_busy_vec     = busy_vec;

endmodule
