`timescale 1ns/1ps

// Mini register status table ("mini-scoreboard") for the 3-stage RV32I core.
//
// This tracks, per architectural register:
//   - whether there is a pending write in the pipeline (busy[]),
//   - whether that pending write comes from a load (is_load_pending[]).
//
// The current pipeline has a single EX/WB stage that writes results in one
// cycle. For this stage, we simply treat the instruction currently in EX as
// the sole producer in flight. That is enough to detect RAW dependencies
// between the ID and EX stages and to distinguish load-use hazards from
// regular ALU dependencies.
//
// Interface:
//   Inputs:
//     clk, rst
//     rd_write_en_ex  - EX/WB will write rd_ex this cycle
//     rd_ex           - destination register in EX/WB
//     is_load_ex      - EX/WB instruction is a load (MEM->WB)
//     rs1_id, rs2_id  - source registers in ID
//     use_rs1_id,
//     use_rs2_id      - indicate whether the ID instruction actually uses rs1/rs2
//
//   Outputs:
//     hazard_rs1, hazard_rs2          - ID sees some in-flight producer for rs1/rs2
//     producer_is_load_rs1 / rs2      - that producer is a load (load-use hazard)
//     busy_vec[31:0]                  - snapshot of busy bits, for tracing/analysis
//
// NOTE: This is intentionally simple and single-stage. It is a stepping stone
// towards a fuller scoreboard in later stages, and currently only needs to
// model dependencies on the EX/WB stage.
module reg_status_table (
    input  logic        clk,
    input  logic        rst,

    // EX/WB stage write information
    input  logic        rd_write_en_ex,
    input  logic [4:0]  rd_ex,
    input  logic        is_load_ex,

    // ID stage sources
    input  logic [4:0]  rs1_id,
    input  logic [4:0]  rs2_id,
    input  logic        use_rs1_id,
    input  logic        use_rs2_id,

    // Hazard classification towards ID
    output logic        hazard_rs1,
    output logic        hazard_rs2,
    output logic        producer_is_load_rs1,
    output logic        producer_is_load_rs2,

    // Optional: expose busy[] snapshot for analyzer / debug
    output logic [31:0] busy_vec
);

  // Per-register status
  logic busy[31:0];
  logic is_load_pending[31:0];

  // For the current 3-stage design, there is at most one writer in flight
  // (the EX/WB stage). We rebuild busy[] combinationally from the EX write
  // information. This is equivalent to the previous direct EX-vs-ID
  // comparison, but expressed as a tiny scoreboard structure.
  always_comb begin
    // Default: no registers busy.
    for (int i = 0; i < 32; i = i + 1) begin
      busy[i]            = 1'b0;
      is_load_pending[i] = 1'b0;
    end

    if (rd_write_en_ex && (rd_ex != 5'd0)) begin
      busy[rd_ex]            = 1'b1;
      is_load_pending[rd_ex] = is_load_ex;
    end

    // Combinational hazard view for the ID stage.
    hazard_rs1           = use_rs1_id && busy[rs1_id];
    hazard_rs2           = use_rs2_id && busy[rs2_id];
    producer_is_load_rs1 = hazard_rs1 && is_load_pending[rs1_id];
    producer_is_load_rs2 = hazard_rs2 && is_load_pending[rs2_id];

    // Flatten busy[] into a vector for logging/analysis.
    for (int j = 0; j < 32; j = j + 1) begin
      busy_vec[j] = busy[j];
    end
  end

endmodule
