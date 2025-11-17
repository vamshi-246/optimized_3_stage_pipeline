`timescale 1ns/1ps

import rv32i_pkg::*;

module universal_tb;

  // Clock and reset
  logic clk = 0;
  logic rst = 1;

  // Memory interfaces
  logic [31:0] instr_addr;
  logic [31:0] instr_rdata;
  logic [31:0] data_addr;
  logic [31:0] data_wdata;
  logic [3:0]  data_we;
  logic        data_re;
  logic [31:0] data_rdata;

  // Simulation controls
  integer cycle_count = 0;
  integer max_cycles  = 200;
  string  hexfile     = "tests/sample_program.hex";

  integer trace_fd;

  // Clock generation: 10ns period
  always #5 clk = ~clk;

  // DUT instance
  rv32i_cpu dut (
      .clk            (clk),
      .rst            (rst),
      .instr_addr     (instr_addr),
      .instr_rdata    (instr_rdata),
      .data_addr      (data_addr),
      .data_wdata     (data_wdata),
      .data_we        (data_we),
      .data_re        (data_re),
      .data_rdata     (data_rdata),
      .dbg_pc_f       (),
      .dbg_instr_f    (),
      .dbg_instr_d    (),
      .dbg_instr_e    (),
      .dbg_result_e   (),
      .dbg_branch_taken(),
      .dbg_stall      (),
      .dbg_bubble_ex  (),
      .dbg_fwd_rs1    (),
      .dbg_fwd_rs2    ()
  );

  // Simple unified memory
  simple_memory mem (
      .clk         (clk),
      .instr_addr  (instr_addr),
      .instr_rdata (instr_rdata),
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
    $fwrite(trace_fd, "cycle,pc_f,instr_fetch,instr_decode,instr_execute,result_execute,stall,branch_taken,stall_flag,bubble,forward_rs1,forward_rs2\n");
  end

  // Cycle-by-cycle tracing and stop conditions
  always_ff @(posedge clk) begin
    if (rst) begin
      cycle_count <= 0;
    end else begin
      cycle_count <= cycle_count + 1;
      $fwrite(trace_fd, "%0d,%08x,%08x,%08x,%08x,%08x,%s,%0d,%0d,%0d,%0d,%0d\n",
              cycle_count,
              dut.dbg_pc_f,
              dut.dbg_instr_f,
              dut.dbg_instr_d,
              dut.dbg_instr_e,
              dut.dbg_result_e,
              dut.dbg_stall ? "stall" : "none",
              dut.dbg_branch_taken,
              dut.dbg_stall,
              dut.dbg_bubble_ex,
              dut.dbg_fwd_rs1,
              dut.dbg_fwd_rs2);

      if (dut.dbg_instr_e == 32'h00100073 || dut.dbg_instr_e == 32'h00000073) begin
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
