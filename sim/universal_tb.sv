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
  logic [31:0] dbg_pc_f, dbg_instr_f, dbg_instr_d, dbg_instr_e, dbg_instr_e1, dbg_result_e;
  logic [31:0] dbg_result_e1;
  logic        dbg_branch_taken, dbg_stall, dbg_bubble_ex, dbg_fwd_rs1, dbg_fwd_rs2;
  logic [31:0] dbg_busy_vec;

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
      .dbg_stall      (dbg_stall),
      .dbg_bubble_ex  (dbg_bubble_ex),
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
    $fwrite(trace_fd, "cycle,pc_f,instr_fetch,instr_decode,instr_execute,instr_execute1,result_execute,result_execute1,stall,branch_taken,stall_flag,bubble,forward_rs1,forward_rs2,busy_vec\n");
  end

  // Cycle-by-cycle tracing and stop conditions
  always_ff @(posedge clk) begin
    if (rst) begin
      cycle_count <= 0;
    end else begin
	      cycle_count <= cycle_count + 1;
      $fwrite(trace_fd, "%0d,%08x,%08x,%08x,%08x,%08x,%08x,%08x,%s,%0d,%0d,%0d,%0d,%0d,%08x\n",
              cycle_count,
              dbg_pc_f,
              dbg_instr_f,
              dbg_instr_d,
              dbg_instr_e,
              dbg_instr_e1,
              dbg_result_e,
              dbg_result_e1,
              dbg_stall ? "stall" : "none",
              dbg_branch_taken,
              dbg_stall,
              dbg_bubble_ex,
              dbg_fwd_rs1,
              dbg_fwd_rs2,
              dbg_busy_vec);

      if (debug) begin
        $display("[dbg] cyc=%0d pc_f=%08x id0=%08x id1=%08x issue1=%b mem1=%b branch1=%b load1=%b sys0=%b sys1=%b",
                 cycle_count,
                 dbg_pc_f,
                 dbg_instr_d,
                 dut.fd_instr1,
                 dut.issue_slot1,
                 (dut.ctrl1_d.mem_read || dut.ctrl1_d.mem_write),
                 (dut.ctrl1_d.branch || dut.ctrl1_d.jump),
                 (dut.ctrl1_d.mem_read),
                 dut.de_ctrl.system,
                 dut.de1_ctrl.system);
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
  end

endmodule
