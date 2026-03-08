`timescale 1ns/1ps
module control_unit (
    input  wire [31:0] instr,         // Full 32-bit instruction

    // -------------------------------------------------------
    // Decoded register addresses (combinational pass-through)
    // -------------------------------------------------------
    output wire [3:0]  rd_addr,       // Destination / accumulator  [26:23]
    output wire [3:0]  rs1_addr,      // Source 1                   [22:19]
    output wire [3:0]  rs2_addr,      // Source 2                   [18:15]
    output wire [14:0] imm15,         // Immediate value            [14:0]
    output wire [2:0]  param_addr,    // Param register index       [2:0]

    // -------------------------------------------------------
    // EX stage control
    // -------------------------------------------------------
    output reg  [4:0]  op_alu,        // ALU local opcode (see ALU_ params)
    output reg         use_tc,        // 1 = route to Tensor Core, 0 = ALU
    output reg         op_tc,         // TC mode: 1 = MAC (RD+=RS1*RS2), 0 = MUL
    output reg         use_imm,       // 1 = use sign_ext(imm15) as ALU operand B

    // -------------------------------------------------------
    // MEM stage control
    // -------------------------------------------------------
    output reg         mem_rd_en,     // Load  enable (LD64)
    output reg         mem_wr_en,     // Store enable (ST64)

    // -------------------------------------------------------
    // WB stage control
    // -------------------------------------------------------
    output reg         rf_wr_en,      // Register file write enable
    output reg  [1:0]  wb_sel,        // WB mux: 0=ALU  1=TC  2=MEM  3=PARAM/MOV

    // -------------------------------------------------------
    // Special / branch control
    // -------------------------------------------------------
    output reg         pred_wr_en,    // Write predicate register (SETP_GE)
    output reg         is_bpr,        // Predicated branch  (BPR, 0x13)
    output reg         is_branch,     // Unconditional branch (BR, 0x14)
    output reg         is_ret         // Halt / done         (RET, 0x15)
);

    // -------------------------------------------------------
    // Field extraction
    // -------------------------------------------------------
    wire [4:0] opcode = instr[31:27];
    assign rd_addr    = instr[26:23];
    assign rs1_addr   = instr[22:19];
    assign rs2_addr   = instr[18:15];
    assign imm15      = instr[14:0];
    assign param_addr = instr[2:0];

    // -------------------------------------------------------
    // Global ISA opcodes
    // -------------------------------------------------------
    localparam OP_NOP      = 5'h00;
    localparam OP_ADD_I16  = 5'h01;
    localparam OP_SUB_I16  = 5'h02;
    localparam OP_MAX_I16  = 5'h03;
    localparam OP_ADD64    = 5'h04;
    localparam OP_ADDI64   = 5'h05;
    localparam OP_SETP_GE  = 5'h06;
    localparam OP_SHIFTLV  = 5'h07;
    localparam OP_SHIFTRV  = 5'h08;
    localparam OP_MAC_BF16 = 5'h09;
    localparam OP_MUL_BF16 = 5'h0a;
    localparam OP_LD64     = 5'h10;
    localparam OP_ST64     = 5'h11;
    localparam OP_MOV      = 5'h12;
    localparam OP_BPR      = 5'h13;
    localparam OP_BR       = 5'h14;
    localparam OP_RET      = 5'h15;
    localparam OP_LD_PARAM = 5'h16;

    // -------------------------------------------------------
    // ALU local opcodes  (must match alu_i16x4.v localparams)
    // -------------------------------------------------------
    localparam ALU_ADD_I16 = 5'h00;
    localparam ALU_SUB_I16 = 5'h01;
    localparam ALU_MAX_I16 = 5'h02;
    localparam ALU_ADD64   = 5'h03;
    localparam ALU_SETP_GE = 5'h04;
    localparam ALU_SHIFTLV = 5'h05;
    localparam ALU_SHIFTRV = 5'h06;
    localparam ALU_NOP     = 5'h1f;

    // WB source select encoding
    localparam WB_ALU   = 2'd0;
    localparam WB_TC    = 2'd1;
    localparam WB_MEM   = 2'd2;
    localparam WB_IMM   = 2'd3;   // MOV / LD_PARAM

    // -------------------------------------------------------
    // Combinational decode
    // -------------------------------------------------------
    always @(*) begin
        // defaults (safe NOP)
        op_alu     = ALU_NOP;
        use_tc     = 1'b0;
        op_tc      = 1'b0;
        use_imm    = 1'b0;
        mem_rd_en  = 1'b0;
        mem_wr_en  = 1'b0;
        rf_wr_en   = 1'b0;
        wb_sel     = WB_ALU;
        pred_wr_en = 1'b0;
        is_bpr     = 1'b0;
        is_branch  = 1'b0;
        is_ret     = 1'b0;

        case (opcode)
            OP_NOP: begin
                // nothing
            end

            // ---- Integer ALU ops ----
            OP_ADD_I16: begin
                op_alu   = ALU_ADD_I16;
                rf_wr_en = 1'b1;
                wb_sel   = WB_ALU;
            end
            OP_SUB_I16: begin
                op_alu   = ALU_SUB_I16;
                rf_wr_en = 1'b1;
                wb_sel   = WB_ALU;
            end
            OP_MAX_I16: begin
                op_alu   = ALU_MAX_I16;
                rf_wr_en = 1'b1;
                wb_sel   = WB_ALU;
            end
            OP_ADD64: begin
                op_alu   = ALU_ADD64;
                rf_wr_en = 1'b1;
                wb_sel   = WB_ALU;
            end
            OP_ADDI64: begin
                op_alu   = ALU_ADD64;
                use_imm  = 1'b1;
                rf_wr_en = 1'b1;
                wb_sel   = WB_ALU;
            end
            OP_SHIFTLV: begin
                op_alu   = ALU_SHIFTLV;
                use_imm  = 1'b1;
                rf_wr_en = 1'b1;
                wb_sel   = WB_ALU;
            end
            OP_SHIFTRV: begin
                op_alu   = ALU_SHIFTRV;
                use_imm  = 1'b1;
                rf_wr_en = 1'b1;
                wb_sel   = WB_ALU;
            end

            // ---- Predicate op ----
            OP_SETP_GE: begin
                op_alu     = ALU_SETP_GE;
                pred_wr_en = 1'b1;
                // rf_wr_en stays 0; result goes to PRED register
            end

            // ---- Tensor Core ops ----
            OP_MAC_BF16: begin
                use_tc   = 1'b1;
                op_tc    = 1'b1;      // MAC: RD = RS1*RS2 + RD
                rf_wr_en = 1'b1;
                wb_sel   = WB_TC;
            end
            OP_MUL_BF16: begin
                use_tc   = 1'b1;
                op_tc    = 1'b0;      // MUL: RD = RS1*RS2
                rf_wr_en = 1'b1;
                wb_sel   = WB_TC;
            end

            // ---- Memory ops ----
            OP_LD64: begin
                mem_rd_en = 1'b1;
                rf_wr_en  = 1'b1;
                wb_sel    = WB_MEM;
                use_imm  = 1'b1;
                op_alu   = ALU_ADD64;
            end
            OP_ST64: begin
                mem_wr_en = 1'b1;
                use_imm  = 1'b1;
                op_alu   = ALU_ADD64;
                // rd_addr holds the data register; rs1_addr is the base address
            end

            // ---- Immediate move ----
            OP_MOV: begin
                use_imm  = 1'b1;
                rf_wr_en = 1'b1;
                wb_sel   = WB_IMM;
            end

            // ---- Param load ----
            OP_LD_PARAM: begin
                rf_wr_en = 1'b1;
                wb_sel   = WB_IMM;   // param data forwarded via WB_IMM path
            end

            // ---- Control flow ----
            OP_BPR: begin
                is_bpr = 1'b1;       // branch if PRED, target = imm15[8:0]
            end
            OP_BR: begin
                is_branch = 1'b1;    // unconditional jump, target = imm15[8:0]
            end
            OP_RET: begin
                is_ret = 1'b1;
            end

            default: begin
                // treat unknown opcodes as NOP
            end
        endcase
    end

endmodule