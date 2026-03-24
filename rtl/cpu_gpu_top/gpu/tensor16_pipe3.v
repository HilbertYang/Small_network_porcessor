`timescale 1ns / 1ps

// tensor16_pipe3 — BF16 MAC/MUL with 4-stage pipeline
//
// Pipeline structure:
//   Stage 1 (comb) : Unpack A/B, feed multest3, compute sign_mul/exp_mul combinatorially
//   Stage 2 (FF)   : Delay sign/exp (no carry yet) and side-channel C/op_mac  [edge N+1]
//   Stage 3 (FF)   : Capture multest3 output (2-cycle latency); propagate from S2  [edge N+2]
//                    Comb after S3: apply carry correction, MAC exponent compare,
//                                   compute alignment shift, right-shift smaller mantissa
//   Stage 4 (FF)   : Register aligned mantissas + large exponent  [edge N+3]
//                    Comb after S4: add/subtract, LZ detect, left-shift normalize,
//                                   exponent adjust -> result output
//
// Critical path cut:  barrel-shift-right lives in S3->S4 window;
//                     barrel-shift-left  lives in S4->output window.
// Each half is ~7-9 ns, meeting an ~11 ns constraint.
//
// Latency: result valid 4 cycles after inputs (vs 3 in pipe2, which failed timing).

module tensor16_pipe3 (
    input  [15:0] fb16_A,
    input  [15:0] fb16_B,
    input  [15:0] fb16_C,
    input         op_mac,    // 1: MAC (A*B + C),  0: MUL (A*B)
    input         clk,
    input         reset,
    input         pc_reset,

    output [15:0] result
);

// =========================================================================
// Stage 1 (combinatorial) — Unpack inputs, drive multiplier
// =========================================================================

wire        sign_A    = fb16_A[15];
wire        sign_B    = fb16_B[15];
wire [7:0]  exp_A     = fb16_A[14:7];
wire [7:0]  exp_B     = fb16_B[14:7];
wire [7:0]  man_A_f   = {1'b1, fb16_A[6:0]};  // implicit leading 1
wire [7:0]  man_B_f   = {1'b1, fb16_B[6:0]};

// multest3: 2-clock pipelined 8x8 multiplier
//   cycle 0  : inputs latched by MULT18X18S
//   cycle 1  : product registered by FD pi_Preg -> p[8:0] valid from edge N+2
wire [8:0]  man_mul_raw;
multest3 u_mul (
    .clk(clk),
    .a(man_A_f),
    .b(man_B_f),
    .p(man_mul_raw)
);

// Combinatorial multiply sign and base exponent (carry correction done in Stage 3)
wire        sign_mul_comb = sign_A ^ sign_B;
wire [7:0]  exp_mul_base  = exp_A + exp_B - 8'd127;

// =========================================================================
// Stage 2 (FF, edge N+1) — Pipeline side-channel signals one cycle
// =========================================================================

reg        s2_sign_mul;
reg [7:0]  s2_exp_mul_base;
reg [15:0] s2_fb16_C;
reg        s2_op_mac;

always @(posedge clk) begin
    if (reset || pc_reset) begin
        s2_sign_mul     <= 1'b0;
        s2_exp_mul_base <= 8'd0;
        s2_fb16_C       <= 16'd0;
        s2_op_mac       <= 1'b0;
    end else begin
        s2_sign_mul     <= sign_mul_comb;
        s2_exp_mul_base <= exp_mul_base;
        s2_fb16_C       <= fb16_C;
        s2_op_mac       <= op_mac;
    end
end

// =========================================================================
// Stage 3 (FF, edge N+2) — Capture multest3 result; propagate from S2
// =========================================================================

reg        s3_sign_mul;
reg [7:0]  s3_exp_mul_base;
reg [15:0] s3_fb16_C;
reg        s3_op_mac;
reg [8:0]  s3_man_mul_raw;   // top-9 bits of 8x8 product

always @(posedge clk) begin
    if (reset || pc_reset) begin
        s3_sign_mul     <= 1'b0;
        s3_exp_mul_base <= 8'd0;
        s3_fb16_C       <= 16'd0;
        s3_op_mac       <= 1'b0;
        s3_man_mul_raw  <= 9'd0;
    end else begin
        s3_sign_mul     <= s2_sign_mul;
        s3_exp_mul_base <= s2_exp_mul_base;
        s3_fb16_C       <= s2_fb16_C;
        s3_op_mac       <= s2_op_mac;
        s3_man_mul_raw  <= man_mul_raw;
    end
end

// -------------------------------------------------------------------------
// Post-Stage-3 combinatorial: normalize multiply result, then compute
// MAC alignment (EXP compare + shift amount + right-shift smaller mantissa)
// This entire block must complete before Stage-4 setup time.
// -------------------------------------------------------------------------

// Apply carry correction from multiplier MSB
wire        carry_mul   = s3_man_mul_raw[8];
wire [7:0]  exp_mul_s3  = s3_exp_mul_base + {7'd0, carry_mul};
wire [6:0]  man_mul_s3  = carry_mul ? s3_man_mul_raw[7:1] : s3_man_mul_raw[6:0];

// Packed MUL result (passed to S4 for op_mac==0 selection)
wire [15:0] mul_result_s3 = {s3_sign_mul, exp_mul_s3, man_mul_s3};

// Unpack C
wire        sign_C_s3   = s3_fb16_C[15];
wire [7:0]  exp_C_s3    = s3_fb16_C[14:7];
wire [7:0]  man_C_f_s3  = {1'b1, s3_fb16_C[6:0]};   // 8-bit with implicit 1
wire [7:0]  man_mul_f_s3 = {1'b1, man_mul_s3};       // 8-bit with implicit 1

// Determine which operand has larger magnitude
//   shift_sel = 1 : C is larger  (small = mul_result)
//   shift_sel = 0 : mul is larger (small = C)
wire exp_gt_s3   = (exp_C_s3 > exp_mul_s3);
wire exp_eq_s3   = (exp_C_s3 == exp_mul_s3);
wire man_gt_s3   = (man_C_f_s3 > man_mul_f_s3);
wire shift_sel_s3 = exp_eq_s3 ? man_gt_s3 : exp_gt_s3;

// Exponent difference (alignment shift amount), clamped to 8
//   (a shift >= 8 flushes an 8-bit mantissa to ~0)
wire [7:0]  exp_diff_s3 = shift_sel_s3 ? (exp_C_s3  - exp_mul_s3)
                                        : (exp_mul_s3 - exp_C_s3);
wire [3:0]  shift_amt_s3 = (|exp_diff_s3[7:3]) ? 4'd8 : {1'b0, exp_diff_s3[2:0]};

// Select large / small mantissas
wire [7:0]  man_lg_s3 = shift_sel_s3 ? man_C_f_s3   : man_mul_f_s3;
wire [7:0]  man_sm_s3 = shift_sel_s3 ? man_mul_f_s3 : man_C_f_s3;

// Right-shift the smaller mantissa to align with the larger
// Result is 9-bit (zero-extended before shift); bit[8] stays 0
wire [8:0]  man_sm_aligned_s3 = {1'b0, man_sm_s3} >> shift_amt_s3;

// Other information carried to Stage 4
wire [7:0]  large_exp_s3   = shift_sel_s3 ? exp_C_s3    : exp_mul_s3;
wire        sign_diff_s3   = s3_sign_mul ^ sign_C_s3;       // 1 = subtract
wire        sign_result_s3 = shift_sel_s3 ? sign_C_s3 : s3_sign_mul; // sign of larger

// =========================================================================
// Stage 4 (FF, edge N+3) — Register alignment results
// =========================================================================

reg        s4_sign_diff;
reg        s4_sign_result;
reg [7:0]  s4_man_large;
reg [8:0]  s4_man_small;        // already right-shifted
reg [7:0]  s4_large_exp;
reg        s4_op_mac;
reg [15:0] s4_mul_result;

always @(posedge clk) begin
    if (reset || pc_reset) begin
        s4_sign_diff    <= 1'b0;
        s4_sign_result  <= 1'b0;
        s4_man_large    <= 8'd0;
        s4_man_small    <= 9'd0;
        s4_large_exp    <= 8'd0;
        s4_op_mac       <= 1'b0;
        s4_mul_result   <= 16'd0;
    end else begin
        s4_sign_diff    <= sign_diff_s3;
        s4_sign_result  <= sign_result_s3;
        s4_man_large    <= man_lg_s3;
        s4_man_small    <= man_sm_aligned_s3;
        s4_large_exp    <= large_exp_s3;
        s4_op_mac       <= s3_op_mac;
        s4_mul_result   <= mul_result_s3;
    end
end

// -------------------------------------------------------------------------
// Post-Stage-4 combinatorial: add/subtract + normalize -> MAC result
// This path contains: 9-bit adder, 9-bit priority encoder, barrel-shift-left
// (~7-8 ns on Virtex-2 fabric, meeting ~11 ns constraint)
// -------------------------------------------------------------------------

// Mantissa add or subtract
wire [8:0] mac_sum = s4_sign_diff
                   ? ({1'b0, s4_man_large} - s4_man_small)   // subtract
                   : ({1'b0, s4_man_large} + s4_man_small);  // add

// Addition carry: overflow into bit[8] means result is 1x.xxxxxxx -> shift right 1
wire carry_mac = mac_sum[8];

// Leading-zero count for left normalization after subtraction
// Priority: highest set bit determines how many positions to shift left
wire [3:0] lz =
    mac_sum[8] ? 4'd0 :   // carry case  — no left shift
    mac_sum[7] ? 4'd0 :   // 1.xxxxxxx   — already normalized
    mac_sum[6] ? 4'd1 :
    mac_sum[5] ? 4'd2 :
    mac_sum[4] ? 4'd3 :
    mac_sum[3] ? 4'd4 :
    mac_sum[2] ? 4'd5 :
    mac_sum[1] ? 4'd6 :
    mac_sum[0] ? 4'd7 :
                 4'd8;    // zero result

// Normalize mantissa
wire [8:0] mac_man_norm = carry_mac ? (mac_sum >> 1) : (mac_sum << lz);

// Adjust exponent
wire [7:0] mac_exp = carry_mac ? (s4_large_exp + 8'd1)
                                : (s4_large_exp - {4'd0, lz});

wire [15:0] mac_result = {s4_sign_result, mac_exp, mac_man_norm[6:0]};

// Output: MUL or MAC result based on op_mac flag registered at Stage 4
assign result = s4_op_mac ? mac_result : s4_mul_result;

endmodule
