`timescale 1ns/1ps

module simple_memory #(
    parameter MEM_WORDS = 2048
) (
    input  logic        clk,
    // Instruction port (read-only)
    input  logic [31:0] instr_addr,
    output logic [31:0] instr_rdata,
    // Data port (read/write)
    input  logic [31:0] data_addr,
    input  logic [31:0] data_wdata,
    input  logic [3:0]  data_we,
    input  logic        data_re,
    output logic [31:0] data_rdata
);

  logic [31:0] mem [0:MEM_WORDS-1];

  integer i;
  initial begin
    for (i = 0; i < MEM_WORDS; i = i + 1) begin
      mem[i] = 32'h0;
    end
  end

  // Provide a simple hook for testbench initialization
  task automatic load_hex(input string filename);
    $readmemh(filename, mem);
  endtask

  // Instruction fetch: combinational read
  assign instr_rdata = mem[instr_addr[31:2]];

  // Data read: combinational for this simple stage
  always_comb begin
    if (data_re) begin
      data_rdata = mem[data_addr[31:2]];
    end else begin
      data_rdata = 32'h0;
    end
  end

  // Data write
  always_ff @(posedge clk) begin
    if (|data_we) begin
      if (data_we[0]) mem[data_addr[31:2]][7:0]   <= data_wdata[7:0];
      if (data_we[1]) mem[data_addr[31:2]][15:8]  <= data_wdata[15:8];
      if (data_we[2]) mem[data_addr[31:2]][23:16] <= data_wdata[23:16];
      if (data_we[3]) mem[data_addr[31:2]][31:24] <= data_wdata[31:24];
    end
  end

endmodule
