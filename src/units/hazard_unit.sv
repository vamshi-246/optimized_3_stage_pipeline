`timescale 1ns/1ps

// Simple hazard detection unit for the 3-stage RV32I pipeline.
// This sits on top of the mini scoreboard (reg_status_table) and
// classifies hazards into "load-use" vs others.
//
// Inputs are already decoded hazard information from the scoreboard:
//   - hazard_rs1 / hazard_rs2: ID stage sees some in-flight producer
//   - producer_is_load_rs1 / rs2: that producer is a load instruction
//
// For Stage-2.5 behaviour we still only stall for load-use hazards.
// All other RAW hazards are handled by forwarding and do not cause stalls.
module hazard_unit (
    input  logic hazard_rs1,
    input  logic hazard_rs2,
    input  logic producer_is_load_rs1,
    input  logic producer_is_load_rs2,

    // Control outputs
    output logic       stall_if_id,
    output logic       bubble_ex
);

  logic load_use_hazard;

  always_comb begin
    load_use_hazard = 1'b0;
    if ((hazard_rs1 && producer_is_load_rs1) ||
        (hazard_rs2 && producer_is_load_rs2)) begin
      load_use_hazard = 1'b1;
    end

    stall_if_id = load_use_hazard;
    bubble_ex   = load_use_hazard;
  end

endmodule
