`timescale 1ns/1ps

// Simple hazard detection unit for the 3-stage RV32I pipeline.
// - Looks at the instruction in Decode (ID) and the instruction in Execute (EX).
// - Detects load-use RAW hazards:
//     * EX is a load that will write rd_ex
//     * ID uses rs1_id and/or rs2_id that match rd_ex
// - On a detected load-use hazard:
//     * Request a stall of PC and IF/ID pipeline register
//     * Request insertion of a bubble into the ID/EX pipeline register
module hazard_unit (
    // ID stage sources
    input  logic [4:0] rs1_id,
    input  logic [4:0] rs2_id,
    input  logic       use_rs1_id,
    input  logic       use_rs2_id,

    // EX stage destination and type
    input  logic [4:0] rd_ex,
    input  logic       reg_write_ex,
    input  logic       mem_read_ex,

    // Control outputs
    output logic       stall_if_id,
    output logic       bubble_ex
);

  logic load_use_hazard;

  always_comb begin
    load_use_hazard = 1'b0;

    if (mem_read_ex && reg_write_ex && (rd_ex != 5'd0)) begin
      if ((use_rs1_id && (rs1_id == rd_ex)) ||
          (use_rs2_id && (rs2_id == rd_ex))) begin
        load_use_hazard = 1'b1;
      end
    end

    stall_if_id = load_use_hazard;
    bubble_ex   = load_use_hazard;
  end

endmodule

