`timescale 1ns/1ps

module regfile (
    input  logic        clk,
    input  logic        rst,

    // Write port 0 (typically slot0 / older)
    input  logic        we0,
    input  logic [4:0]  waddr0,
    input  logic [31:0] wdata0,

    // Write port 1 (typically slot1 / younger)
    input  logic        we1,
    input  logic [4:0]  waddr1,
    input  logic [31:0] wdata1,

    // Read ports for slot 0
    input  logic [4:0]  raddr0_1,
    input  logic [4:0]  raddr0_2,
    output logic [31:0] rdata0_1,
    output logic [31:0] rdata0_2,

    // Read ports for slot 1
    input  logic [4:0]  raddr1_1,
    input  logic [4:0]  raddr1_2,
    output logic [31:0] rdata1_1,
    output logic [31:0] rdata1_2
);

  logic [31:0] regs[31:0];

  integer i;
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      for (i = 0; i < 32; i = i + 1) begin
        regs[i] <= 32'h0;
      end
    end else begin
      // Commit slot0 write first (older)
      if (we0 && (waddr0 != 5'd0)) begin
        regs[waddr0] <= wdata0;
      end
      // Then commit slot1 write (younger) so it wins if same destination
      if (we1 && (waddr1 != 5'd0)) begin
        regs[waddr1] <= wdata1;
      end
    end
  end

  // Combinational reads
  assign rdata0_1 = (raddr0_1 == 5'd0) ? 32'h0 : regs[raddr0_1];
  assign rdata0_2 = (raddr0_2 == 5'd0) ? 32'h0 : regs[raddr0_2];

  assign rdata1_1 = (raddr1_1 == 5'd0) ? 32'h0 : regs[raddr1_1];
  assign rdata1_2 = (raddr1_2 == 5'd0) ? 32'h0 : regs[raddr1_2];

endmodule
