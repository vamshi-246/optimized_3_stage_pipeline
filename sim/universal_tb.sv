`timescale 1ns/1ps

import rv32i_pkg::*;

module universal_tb;

  // Clock and reset
  logic clk = 0;
  logic rst = 1;

  // Memory interfaces
  logic [31:0] instr_addr;
  logic [31:0] instr_rdata;
  logic [31:0] instr_addr1;
  logic [31:0] instr_rdata1;
  logic [31:0] data_addr;
  logic [31:0] data_wdata;
  logic [3:0]  data_we;
  logic        data_re;
  logic [31:0] data_rdata;

  // Simulation controls
  integer cycle_count = 0;
  integer max_cycles  = 200;
  string  hexfile     = "tests/sample_program.hex";
  bit     debug       = 1'b0;

  integer trace_fd;

  // Debug tap wires
  logic [31:0] dbg_pc_f;
  logic [31:0] dbg_instr_f;
  logic [31:0] dbg_instr_d;
  logic [31:0] dbg_instr_e, dbg_instr_e1;
  logic [31:0] dbg_result_e, dbg_result_e1;
  logic        dbg_branch_taken, dbg_branch_taken1, dbg_jump_taken, dbg_jump_taken1;
  logic [31:0] dbg_jump_target, dbg_jump_target1;
  logic        dbg_stall, dbg_fwd_rs1, dbg_fwd_rs2;
  logic [31:0] dbg_busy_vec;

  // Local debug-only helpers for forwarding source classification
  integer fwd_rs1_1_src;
  integer fwd_rs2_1_src;
  logic   is_load_ex0;
  logic   is_load_ex1;
  logic   prev_ex0_fwd_valid = 1'b0;
  logic   prev_ex1_fwd_valid = 1'b0;
  logic [4:0] prev_ex0_rd = 5'd0;
  logic [4:0] prev_ex1_rd = 5'd0;

  // Simple helper: print 32-bit value as hex, or "xx" if any bit is X/Z.
  function string fmt_hex(input logic [31:0] v);
    if ($isunknown(v)) begin
      fmt_hex = "xx";
    end else begin
      fmt_hex = $sformatf("%08x", v);
    end
  endfunction

  // Clock generation: 10ns period
  always #5 clk = ~clk;

  // DUT instance
  rv32i_cpu dut (
      .clk            (clk),
      .rst            (rst),
      .instr_addr     (instr_addr),
      .instr_rdata    (instr_rdata),
      .instr_addr1    (instr_addr1),
      .instr_rdata1   (instr_rdata1),
      .data_addr      (data_addr),
      .data_wdata     (data_wdata),
      .data_we        (data_we),
      .data_re        (data_re),
      .data_rdata     (data_rdata),
      .dbg_pc_f       (dbg_pc_f),
      .dbg_instr_f    (dbg_instr_f),
      .dbg_instr_d    (dbg_instr_d),
      .dbg_instr_e    (dbg_instr_e),
      .dbg_instr_e1   (dbg_instr_e1),
      .dbg_result_e   (dbg_result_e),
      .dbg_result_e1  (dbg_result_e1),
      .dbg_branch_taken(dbg_branch_taken),
      .dbg_branch_taken1(dbg_branch_taken1),
      .dbg_jump_taken  (dbg_jump_taken),
      .dbg_jump_taken1 (dbg_jump_taken1),
      .dbg_jump_target (dbg_jump_target),
      .dbg_jump_target1(dbg_jump_target1),
      .dbg_stall      (dbg_stall),
      .dbg_fwd_rs1    (dbg_fwd_rs1),
      .dbg_fwd_rs2    (dbg_fwd_rs2),
      .dbg_busy_vec   (dbg_busy_vec)
  );

  // Simple unified memory
  simple_memory mem (
      .clk         (clk),
      .instr_addr  (instr_addr),
      .instr_rdata (instr_rdata),
      .instr_addr1 (instr_addr1),
      .instr_rdata1(instr_rdata1),
      .data_addr   (data_addr),
      .data_wdata  (data_wdata),
      .data_we     (data_we),
      .data_re     (data_re),
      .data_rdata  (data_rdata)
  );

  // Optional plusargs for configuration
  initial begin
    if ($value$plusargs("HEX=%s", hexfile)) begin
      $display("Loading program from %s", hexfile);
    end else begin
      $display("Defaulting to program %s", hexfile);
    end

    if ($value$plusargs("MAX_CYCLES=%d", max_cycles)) begin
      $display("Max cycles set to %0d", max_cycles);
    end

    if ($test$plusargs("DEBUG")) begin
      debug = 1'b1;
      $display("Debug tracing enabled.");
    end
  end

  // Initialize memory before releasing reset
  initial begin
    mem.load_hex(hexfile);
  end

  // Reset sequence
  initial begin
    rst = 1'b1;
    repeat (5) @(posedge clk);
    rst = 1'b0;
  end

  // Waveform dump (honor +DUMPFILE plusarg if provided)
  string dumpfile = "sim/out.vcd";

  initial begin
    if ($value$plusargs("DUMPFILE=%s", dumpfile)) begin
      $display("Using dumpfile %s", dumpfile);
    end
    $dumpfile(dumpfile);
    $dumpvars(0, universal_tb);
  end

  // Trace logging
  initial begin
    trace_fd = $fopen("sim/pipeline_trace.log", "w");
    $fwrite(trace_fd,
            "cycle,pc_f,fetch0,fetch1,decode0,decode1,issue0,issue1,exec0,exec1,result0,result1,branch_taken0,branch_taken1,jump_taken0,jump_taken1,branch_target0,branch_target1,jump_target0,jump_target1,mem0_re,mem0_we,mem1_re,mem1_we,mem_addr0,mem_addr1,fwd_rs1_0_en,fwd_rs2_0_en,fwd_rs1_1_src,fwd_rs2_1_src,stall_if_id,raw1,waw1,load_use0,load_use1,busy_vec,load_pending_vec\n");
  end

  // Cycle-by-cycle tracing and stop conditions
  always_ff @(posedge clk) begin
    if (rst) begin
      cycle_count <= 0;
    end else begin
      cycle_count <= cycle_count + 1;

      // Forwarding source encoding for slot1:
      // 0 = regfile, 1 = EX1 result, 2 = EX0 result.
      is_load_ex0 = dut.is_load_ex;
      is_load_ex1 = dut.de1_ctrl.mem_read && !dut.de1_ctrl.mem_write;

      // Forwarding metadata: compare current decode operands against the
      // previous cycle's execute results.
      fwd_rs1_1_src = 0;
      if (dut.rs1_1_d != 5'd0) begin
        if (prev_ex1_fwd_valid && (dut.rs1_1_d == prev_ex1_rd)) begin
          fwd_rs1_1_src = 1;
        end else if (prev_ex0_fwd_valid && (dut.rs1_1_d == prev_ex0_rd)) begin
          fwd_rs1_1_src = 2;
        end
      end

      fwd_rs2_1_src = 0;
      if (dut.rs2_1_d != 5'd0) begin
        if (prev_ex1_fwd_valid && (dut.rs2_1_d == prev_ex1_rd)) begin
          fwd_rs2_1_src = 1;
        end else if (prev_ex0_fwd_valid && (dut.rs2_1_d == prev_ex0_rd)) begin
          fwd_rs2_1_src = 2;
        end
      end

      $fwrite(
          trace_fd,
          "%0d,%s,%s,%s,%s,%s,%0d,%0d,%s,%s,%s,%s,%0d,%0d,%0d,%0d,%s,%s,%s,%s,%0d,%0d,%0d,%0d,%s,%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%s,%s\n",
          cycle_count,
          fmt_hex(dbg_pc_f),
          fmt_hex(dbg_instr_f),
          fmt_hex(dut.instr1_f),
          fmt_hex(dbg_instr_d),
          fmt_hex(dut.fd_instr1),
          dut.issue_slot0,
          dut.issue_slot1,
          fmt_hex(dbg_instr_e),
          fmt_hex(dbg_instr_e1),
          fmt_hex(dbg_result_e),
          fmt_hex(dbg_result_e1),
          dbg_branch_taken,
          dbg_branch_taken1,
          dbg_jump_taken,
          dbg_jump_taken1,
          fmt_hex(dut.branch_target_e),
          fmt_hex(dut.branch_target_e1),
          fmt_hex(dbg_jump_target),
          fmt_hex(dbg_jump_target1),
          (dut.use_mem0 && dut.de_ctrl.mem_read),
          (dut.use_mem0 && dut.de_ctrl.mem_write),
          (dut.use_mem1 && dut.de1_ctrl.mem_read),
          (dut.use_mem1 && dut.de1_ctrl.mem_write),
          fmt_hex(dut.addr_e0),
          fmt_hex(dut.addr_e1),
          dbg_fwd_rs1,
          dbg_fwd_rs2,
          fwd_rs1_1_src,
          fwd_rs2_1_src,
          dbg_stall,
          dut.raw_hazard1,
          dut.waw_hazard1,
          dut.load_use0_h,
          dut.load_use1_h,
          fmt_hex(dbg_busy_vec),
          fmt_hex(dut.load_pending_vec)
      );

      if (debug) begin
        $display("[dbg] cyc=%0d pc_f=%08x F0=%08x F1=%08x D0=%08x D1=%08x E0=%08x E1=%08x issue0=%b issue1=%b",
                 cycle_count,
                 dbg_pc_f,
                 dbg_instr_f,
                 dut.instr1_f,
                 dbg_instr_d,
                 dut.fd_instr1,
                 dbg_instr_e,
                 dbg_instr_e1,
                 dut.issue_slot0,
                 dut.issue_slot1);
      end

      if (dbg_instr_e == 32'h00100073 || dbg_instr_e == 32'h00000073 ||
          dbg_instr_e1 == 32'h00100073 || dbg_instr_e1 == 32'h00000073) begin
        $display("Halting on system instruction at cycle %0d", cycle_count);
        $finish;
      end

      if (cycle_count >= max_cycles) begin
        $display("Reached max cycles (%0d). Finishing simulation.", max_cycles);
        $finish;
      end
    end

    // Record this cycle's execute-stage writers for next cycle's tagging.
    prev_ex0_fwd_valid <= dut.de_ctrl.reg_write &&
                          !is_load_ex0 &&
                          (dut.de_rd != 5'd0);
    prev_ex0_rd        <= dut.de_rd;
    prev_ex1_fwd_valid <= dut.de1_ctrl.reg_write &&
                          !is_load_ex1 &&
                          (dut.de1_rd != 5'd0);
    prev_ex1_rd        <= dut.de1_rd;
  end

endmodule
