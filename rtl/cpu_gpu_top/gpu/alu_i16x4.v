// alu_i16x4.v
// 4-lane 16-bit integer ALU
// Handles: ADD_I16, SUB_I16, MAX_I16 (ReLU = MAX with 0)
// Also handles 64-bit address arithmetic (ADD64, ADDI64, MUL_WIDE)
// and SETP_GE for predicate generation

module alu_i16x4(
    input  wire [63:0] a,        
    input  wire [63:0] b,        
    input  wire [4:0]  op,       // ALU opcode

    output reg  [63:0] y,

    output reg         pred_out
);

    // Unpack lanes
    wire signed [15:0] a0 = a[15:0];
    wire signed [15:0] a1 = a[31:16];
    wire signed [15:0] a2 = a[47:32];
    wire signed [15:0] a3 = a[63:48];

    wire signed [15:0] b0 = b[15:0];
    wire signed [15:0] b1 = b[31:16];
    wire signed [15:0] b2 = b[47:32];
    wire signed [15:0] b3 = b[63:48];
    
    localparam OP_ADD_I16  = 5'h00;
    localparam OP_SUB_I16  = 5'h01;
    localparam OP_MAX_I16  = 5'h02;
    localparam OP_ADD64    = 5'h03;
    localparam OP_SETP_GE  = 5'h04;
    localparam OP_SHIFTLV  = 5'h05;
    localparam OP_SHIFTRV  = 5'h06;

    reg signed [15:0] r0, r1, r2, r3;

    always @(*) begin
        y        = 64'd0;
        pred_out = 1'b0;
        r0 = 16'd0; r1 = 16'd0; r2 = 16'd0; r3 = 16'd0;

        case (op)
            OP_ADD_I16: begin
                r0 = a0 + b0;
                r1 = a1 + b1;
                r2 = a2 + b2;
                r3 = a3 + b3;
                y = {r3, r2, r1, r0};
            end

            OP_SUB_I16: begin
                r0 = a0 - b0;
                r1 = a1 - b1;
                r2 = a2 - b2;
                r3 = a3 - b3;
                y = {r3, r2, r1, r0};
            end

            OP_MAX_I16: begin
                r0 = (a0 > b0) ? a0 : b0;
                r1 = (a1 > b1) ? a1 : b1;
                r2 = (a2 > b2) ? a2 : b2;
                r3 = (a3 > b3) ? a3 : b3;
                y = {r3, r2, r1, r0};
            end

            OP_ADD64: begin
                y = a + b;
            end

            OP_SETP_GE: begin
                pred_out = ($signed(a[31:0]) >= $signed(b[31:0]));
                y = 64'd0;
            end

            OP_SHIFTLV: begin
                y = a;
            end

            OP_SHIFTRV: begin
                y = a;
            end

            default: begin
                y = a;
            end
        endcase
    end

endmodule
