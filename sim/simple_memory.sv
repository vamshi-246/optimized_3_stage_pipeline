`timescale 1ns/1ps

module simple_memory #(
    parameter MEM_WORDS = 2048
) (
    input  logic        clk,
    // Instruction port (read-only)
    input  logic [31:0] instr_addr,
    output logic [31:0] instr_rdata,
    // Second instruction read port for dual-issue fetch
    input  logic [31:0] instr_addr1,
    output logic [31:0] instr_rdata1,
    // Data port (read/write)
    input  logic [31:0] data_addr,
    input  logic [31:0] data_wdata,
    input  logic [3:0]  data_we,
    input  logic        data_re,
    output logic [31:0] data_rdata
);

  (* ram_style = "block" *) logic [31:0] mem [0:MEM_WORDS-1];

  // Provide a simple hook for testbench initialization
  task automatic load_hex(input string filename);
    $readmemh(filename, mem);
  endtask

  // Precompute word indices to avoid nested part-selects in procedural blocks.
  logic [31:0] instr_idx0;
  logic [31:0] instr_idx1;
  logic [31:0] data_idx;

  assign instr_idx0 = instr_addr >> 2;
  assign instr_idx1 = instr_addr1 >> 2;
  assign data_idx   = data_addr >> 2;

  // Instruction fetch: combinational read (dual port)
  assign instr_rdata  = mem[instr_idx0];
  assign instr_rdata1 = mem[instr_idx1];

  // Data read: combinational for this simple stage
  always_comb begin
    if (data_re) begin
      data_rdata = mem[data_idx];
    end else begin
      data_rdata = 32'h0;
    end
  end

  // Data write
  always_ff @(posedge clk) begin
    if (|data_we) begin
      logic [31:0] write_word;
      write_word = mem[data_idx];
      if (data_we[0]) write_word[7:0]   = data_wdata[7:0];
      if (data_we[1]) write_word[15:8]  = data_wdata[15:8];
      if (data_we[2]) write_word[23:16] = data_wdata[23:16];
      if (data_we[3]) write_word[31:24] = data_wdata[31:24];
      mem[data_idx] <= write_word;
    end
  end

endmodule
