package rv32i_pkg;
  // Common encodings and control types for the RV32I pipeline

  typedef enum logic [3:0] {
    ALU_ADD  = 4'd0,
    ALU_SUB  = 4'd1,
    ALU_SLL  = 4'd2,
    ALU_SLT  = 4'd3,
    ALU_SLTU = 4'd4,
    ALU_XOR  = 4'd5,
    ALU_SRL  = 4'd6,
    ALU_SRA  = 4'd7,
    ALU_OR   = 4'd8,
    ALU_AND  = 4'd9
  } alu_op_e;

  typedef enum logic [2:0] {
    IMM_I = 3'd0,
    IMM_S = 3'd1,
    IMM_B = 3'd2,
    IMM_U = 3'd3,
    IMM_J = 3'd4,
    IMM_Z = 3'd5  // zero-extended immediate (for shifts, csr-like use)
  } imm_t;

  typedef enum logic [1:0] {
    OP1_RS1  = 2'b00,
    OP1_PC   = 2'b01,
    OP1_ZERO = 2'b10
  } op1_sel_e;

  typedef enum logic [1:0] {
    OP2_RS2 = 2'b00,
    OP2_IMM = 2'b01
  } op2_sel_e;

  typedef enum logic [2:0] {
    BR_EQ  = 3'd0,
    BR_NE  = 3'd1,
    BR_LT  = 3'd2,
    BR_GE  = 3'd3,
    BR_LTU = 3'd4,
    BR_GEU = 3'd5
  } branch_t;

  typedef enum logic [1:0] {
    WB_ALU = 2'b00,
    WB_MEM = 2'b01,
    WB_PC4 = 2'b10,
    WB_IMM = 2'b11
  } wb_sel_e;

  typedef struct packed {
    imm_t      imm_type;
    op1_sel_e  op1_sel;
    op2_sel_e  op2_sel;
    alu_op_e   alu_op;
    branch_t   branch_type;
    logic      branch;
    logic      jump;
    logic      is_jump;      // semantic jump (jal/jalr)
    logic      is_jal;
    logic      is_jalr;
    logic      mem_read;
    logic      mem_write;
    logic [2:0] mem_funct3;  // loads/stores size + sign
    logic      reg_write;
    wb_sel_e   wb_sel;
    logic      is_lui;
    logic      is_auipc;
    logic      system;       // system/ebreak/ecall
    logic      is_store;     // store instruction (mem_write)
  } control_t;

endpackage : rv32i_pkg
