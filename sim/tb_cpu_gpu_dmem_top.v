// tb_cpu_gpu_dmem_top.v
// Testbench for cpu_gpu_dmem_top.
//
// NOTE: R0 is hardwired to zero in REG_FILE_BANK (reads always return 0,
//       writes to waddr==0 are silently discarded).  The CPU program therefore
//       uses only R3..R5 as working registers; R0 is never the destination of
//       a MOV or the source of a WRP.
//
// Test flow:
//   1. Program the GPU IMEM (imem_sel=0) with a simple kernel:
//         reads input vector from DMEM, adds a scalar, writes output.
//   2. Program the CPU IMEM (imem_sel=1) with a program that:
//         a. MOVs param values into R3, R4, R5  (non-zero registers)
//         b. Issues WRP R3,#0 / WRP R4,#1 / WRP R5,#2  (writes GPU params via CPU)
//         c. Issues GPURUN  (hands control to GPU)
//         d. After GPU returns, halts with an infinite B loop
//   3. Initialise DMEM via Port-A with input data.
//   4. Assert run=1 and wait for done.
//   5. Read back DMEM via Port-A and verify GPU modified the data.
//
// ─── Instruction encoding quick-reference ───────────────────────────────────
//   CPU ISA (ARM-32 subset, 32-bit):
//     NOP         32'hE000_0000
//     MOV Rd,#imm8  {cond=E I=1 op=00 opcode=1101 S=0 Rn=0 Rd imm8}
//                   = {8'hE3, 4'hA, Rd[3:0], 4'h0, imm8[7:0]}
//     WRP Rs,#imm3  {8'b10101110, Rs[3:0], 17'b0, imm3[2:0]}
//     GPURUN        {8'b10101101, 24'b0}
//     B  off24      {4'hE, 8'hEA, off24[23:0]}   off24 = target-(PC+2)
//
//   GPU ISA (5-bit opcode):
//     [31:27]=op [26:23]=RD [22:19]=RS1 [18:15]=RS2 [14:0]=IMM15
//     LD_PARAM  5'h16  RD = PARAM[imm3]
//     LD64      5'h10  RD = DMEM[RS1 + imm15]
//     ADDI64    5'h05  RD = RS1 + sign_ext(imm15)
//     ADD64     5'h04  RD = RS1 + RS2
//     ADD_I16   5'h01  RD[4xi16] = RS1[4xi16] + RS2[4xi16]
//     ST64      5'h11  DMEM[RS1 + imm15] = RD
//     MOV       5'h12  RD = sign_ext(imm15)
//     SETP_GE   5'h06  PRED = (RS1 >= RS2)
//     BPR       5'h13  if PRED: PC = imm15[8:0]
//     BR        5'h14  PC = imm15[8:0]
//     RET       5'h15  halt / done
// ─────────────────────────────────────────────────────────────────────────────
//
// GPU kernel: "vector add scalar"  (GPU R0 is not hardwired — GPU has its own RF)
//   Params:  p0 = input  base word-address in DMEM  (= 10)
//            p1 = output base word-address in DMEM  (= 20)
//            p2 = scalar to add to every i16 lane   (= 64'h0001_0001_0001_0001)
//
//   GPU program word addresses:
//     0  LD_PARAM R1, #0       R1 = param[0] = input  base
//     1  LD_PARAM R2, #1       R2 = param[1] = output base
//     2  LD_PARAM R3, #2       R3 = param[2] = scalar
//     3  MOV      R4, #0       R4 = loop counter (0..3)
//     4  MOV      R5, #4       R5 = loop limit
//     5  NOP                   pipeline fill after MOVs
//     6  NOP
//     -- loop head (addr 7) --
//     7  ADD64    R6, R1, R4   R6 = input  base + counter
//     8  ADD64    R7, R2, R4   R7 = output base + counter
//     9  LD64     R8, [R6+0]   R8 = DMEM[R6]
//    10  NOP                   LD64 pipeline bubble
//    11  NOP
//    12  ADD_I16  R8, R8, R3   R8[4xi16] += scalar
//    13  ST64     R8, [R7+0]   DMEM[R7] = R8
//    14  ADDI64   R4, R4, #1   counter++
//    15  SETP_GE  R4, R5       PRED = (counter >= 4)
//    16  BPR      #18          if done → jump to RET
//    17  BR       #7           else loop back → addr 7
//    18  RET
//
// ─────────────────────────────────────────────────────────────────────────────
//   CPU program: written to CPU IMEM (imem_sel=1).
//   R0 is hardwired-zero, so we use R3/R4/R5 as the three param registers.
//   The pipeline is 5 stages with no forwarding; a MOV result is visible at
//   WB after 4 more advance cycles, so 4 NOPs are inserted between every
//   MOV and the WRP that reads its result.
//
//   CPU word addresses (thread 0, PC starts at 0):
//     0:  MOV  R3, #10      R3 = input  base addr (DMEM word 10)
//     1:  NOP
//     2:  NOP
//     3:  NOP
//     4:  NOP
//     5:  WRP  R3, #0       param[0] = R3 = 10
//     6:  NOP
//     7:  NOP
//     8:  MOV  R4, #20      R4 = output base addr (DMEM word 20)
//     9:  NOP
//    10:  NOP
//    11:  NOP
//    12:  NOP
//    13:  WRP  R4, #1       param[1] = R4 = 20
//    14:  NOP
//    15:  NOP
//    16:  MOV  R5, #1       R5 = scalar = 1 per i16 lane
//    17:  NOP
//    18:  NOP
//    19:  NOP
//    20:  NOP
//    21:  WRP  R5, #2       param[2] = R5 = 1
//    22:  NOP
//    23:  NOP
//    24:  NOP
//    25:  NOP
//    26:  GPURUN            launch GPU; CPU stalls until gpu_done
//    27:  NOP
//    28:  NOP
//    29:  NOP
//    30:  B    -2           infinite loop  (off24 = 24'hFFFFFE)
// ─────────────────────────────────────────────────────────────────────────────

`timescale 1ns/1ps

module tb_cpu_gpu_dmem_top;

    // =========================================================================
    // DUT ports
    // =========================================================================
    reg         clk, reset;
    reg         run, step, pc_reset;
    wire        done;

    reg         imem_sel;
    reg         imem_prog_we;
    reg  [8:0]  imem_prog_addr;
    reg  [31:0] imem_prog_wdata;

    reg         dmem_prog_en, dmem_prog_we;
    reg  [7:0]  dmem_prog_addr;
    reg  [63:0] dmem_prog_wdata;
    wire [63:0] dmem_prog_rdata;

    reg  [7:0]  fifo_start_offset, fifo_end_offset;
    reg         fifo_data_ready;
    wire        fifo_data_done;

    wire [8:0]  pc_dbg;
    wire [31:0] if_instr_dbg;

    // =========================================================================
    // DUT instantiation
    // =========================================================================
    cpu_gpu_dmem_top DUT (
        .clk              (clk),
        .reset            (reset),
        .run              (run),
        .step             (step),
        .pc_reset         (pc_reset),
        .done             (done),
        .imem_sel         (imem_sel),
        .imem_prog_we     (imem_prog_we),
        .imem_prog_addr   (imem_prog_addr),
        .imem_prog_wdata  (imem_prog_wdata),
        .dmem_prog_en     (dmem_prog_en),
        .dmem_prog_we     (dmem_prog_we),
        .dmem_prog_addr   (dmem_prog_addr),
        .dmem_prog_wdata  (dmem_prog_wdata),
        .dmem_prog_rdata  (dmem_prog_rdata),
        .fifo_start_offset(fifo_start_offset),
        .fifo_end_offset  (fifo_end_offset),
        .fifo_data_ready  (fifo_data_ready),
        .fifo_data_done   (fifo_data_done),
        .pc_dbg           (pc_dbg),
        .if_instr_dbg     (if_instr_dbg)
    );

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 0;
    always  #5 clk = ~clk;

    // =========================================================================
    // Pass / Fail counter
    // =========================================================================
    integer pass_cnt, fail_cnt;

    // =========================================================================
    // Task: write one word into IMEM (GPU or CPU, selected by imem_sel)
    // =========================================================================
    task imem_write;
        input [8:0]  addr;
        input [31:0] data;
        begin
            @(negedge clk);
            imem_prog_we    = 1'b1;
            imem_prog_addr  = addr;
            imem_prog_wdata = data;
            @(posedge clk);
            @(negedge clk);
            imem_prog_we    = 1'b0;
        end
    endtask

    // =========================================================================
    // Task: write one 64-bit word into DMEM via Port-A
    // =========================================================================
    task dmem_write;
        input [7:0]  addr;
        input [63:0] data;
        begin
            @(negedge clk);
            dmem_prog_en    = 1'b1;
            dmem_prog_we    = 1'b1;
            dmem_prog_addr  = addr;
            dmem_prog_wdata = data;
            @(posedge clk); #1;
            dmem_prog_en    = 1'b0;
            dmem_prog_we    = 1'b0;
        end
    endtask

    // =========================================================================
    // Task: read and check one 64-bit word from DMEM via Port-A
    // =========================================================================
    task dmem_read_check;
        input [7:0]  addr;
        input [63:0] expected;
        input [63:0] test_id;
        begin
            @(negedge clk);
            dmem_prog_en    = 1'b1;
            dmem_prog_we    = 1'b0;
            dmem_prog_addr  = addr;
            @(posedge clk); #1;   // addr latched
            @(posedge clk); #1;   // dout valid
            if (dmem_prog_rdata === expected) begin
                $display("[PASS] Test %0d  DMEM[%0d] = 0x%016h  (expected 0x%016h)",
                          test_id, addr, dmem_prog_rdata, expected);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("[FAIL] Test %0d  DMEM[%0d] = 0x%016h  (expected 0x%016h)",
                          test_id, addr, dmem_prog_rdata, expected);
                fail_cnt = fail_cnt + 1;
            end
            @(negedge clk);
            dmem_prog_en = 1'b0;
        end
    endtask

    // =========================================================================
    // Instruction encoding helpers
    // =========================================================================

    // --- CPU ISA ---
    // MOV Rd, #imm8   {cond=E I=1 op=00 opcode=1101 S=0 Rn=0 Rd imm8}
    //                 = {8'hE3, 4'hA, Rd, 4'h0, imm8}
    function [31:0] cpu_mov;
        input [3:0]  rd;
        input [7:0]  imm8;
        begin cpu_mov = {8'hE3, 4'hA, rd, 4'h0, imm8}; end
    endfunction

    // WRP Rs, #imm3   {8'b10101110, Rs, 17'b0, imm3}
    function [31:0] cpu_wrp;
        input [3:0] rs;
        input [2:0] imm3;
        begin cpu_wrp = {8'b10101110, rs, 17'b0, imm3}; end
    endfunction

    // GPURUN           {8'b10101101, 24'b0}
    function [31:0] cpu_gpurun;
		input a;
        begin cpu_gpurun = {8'b10101101, 24'b0}; end
    endfunction

    // NOP              32'hE000_0000
    function [31:0] cpu_nop;
	 		input a;
        begin cpu_nop = 32'hE000_0000; end
    endfunction

    // B off24   {4'hE, 8'hEA, off24}   — off24 is signed offset from PC+2
    function [31:0] cpu_b;
        input signed [23:0] off24;
        begin cpu_b = {4'hE, 8'hEA, off24}; end
    endfunction

    // --- GPU ISA  {op[31:27], RD[26:23], RS1[22:19], RS2[18:15], IMM15[14:0]} ---
    function [31:0] gpu_ld_param;
        input [3:0] rd;
        input [2:0] imm3;   // param index
        begin gpu_ld_param = {5'h16, rd, 4'h0, 4'h0, 12'h0, imm3}; end
    endfunction

    function [31:0] gpu_ld64;
        input [3:0] rd;
        input [3:0] rs1;    // base register
        input [14:0] imm15; // word offset
        begin gpu_ld64 = {5'h10, rd, rs1, 4'h0, 1'b0, imm15}; end
    endfunction

    function [31:0] gpu_st64;
        input [3:0] rd;     // data register
        input [3:0] rs1;    // base register
        input [14:0] imm15; // word offset
        begin gpu_st64 = {5'h11, rd, rs1, 4'h0, 1'b0, imm15}; end
    endfunction

    function [31:0] gpu_addi64;
        input [3:0] rd;
        input [3:0] rs1;
        input signed [14:0] imm15;
        begin gpu_addi64 = {5'h05, rd, rs1, 4'h0, imm15}; end
    endfunction

    function [31:0] gpu_add64;
        input [3:0] rd;
        input [3:0] rs1;
        input [3:0] rs2;
        begin gpu_add64 = {5'h04, rd, rs1, rs2, 15'h0}; end
    endfunction

    function [31:0] gpu_add_i16;
        input [3:0] rd;
        input [3:0] rs1;
        input [3:0] rs2;
        begin gpu_add_i16 = {5'h01, rd, rs1, rs2, 15'h0}; end
    endfunction

    function [31:0] gpu_mov;
        input [3:0] rd;
        input signed [14:0] imm15;
        begin gpu_mov = {5'h12, rd, 4'h0, 4'h0, imm15}; end
    endfunction

    function [31:0] gpu_setp_ge;
        input [3:0] rs1;
        input [3:0] rs2;
        begin gpu_setp_ge = {5'h06, 4'h0, rs1, rs2, 15'h0}; end
    endfunction

    function [31:0] gpu_bpr;
        input [8:0] target;
        begin gpu_bpr = {5'h13, 4'h0, 4'h0, 4'h0, 6'h0, target}; end
    endfunction

    function [31:0] gpu_br;
        input [8:0] target;
        begin gpu_br = {5'h14, 4'h0, 4'h0, 4'h0, 6'h0, target}; end
    endfunction

    function [31:0] gpu_ret;
	 input a;
        begin gpu_ret = {5'h15, 27'h0}; end
    endfunction

    function [31:0] gpu_nop;
	 input a;
        begin gpu_nop = 32'h0; end
    endfunction

    // =========================================================================
    // Main stimulus
    // =========================================================================
    integer timeout;

    initial begin
        // ---- defaults ----
        pass_cnt         = 0;
        fail_cnt         = 0;
        reset            = 1'b1;
        run              = 1'b0;
        step             = 1'b0;
        pc_reset         = 1'b0;
        imem_sel         = 1'b0;
        imem_prog_we     = 1'b0;
        imem_prog_addr   = 9'h0;
        imem_prog_wdata  = 32'h0;
        dmem_prog_en     = 1'b0;
        dmem_prog_we     = 1'b0;
        dmem_prog_addr   = 8'h0;
        dmem_prog_wdata  = 64'h0;
        fifo_start_offset= 8'h0;
        fifo_end_offset  = 8'h0;
        fifo_data_ready  = 1'b0;

        repeat(6) @(posedge clk);
        reset = 1'b0;
        repeat(2) @(posedge clk);

        // =====================================================================
        // PHASE 1 — Program GPU IMEM (imem_sel = 0)
        // =====================================================================
        // Kernel: vector-add-scalar over 4 words
        //   R1 = param[0] = input  base (word addr)
        //   R2 = param[1] = output base (word addr)
        //   R3 = param[2] = scalar (packed 4×i16)
        //   R4 = loop counter (0..3)   NOTE: GPU has its own RF, R0 is fine
        //   R5 = loop limit (4)         in the GPU; we use R4 here for clarity
        //   R6 = effective input  addr (R1 + counter)
        //   R7 = effective output addr (R2 + counter)
        //   R8 = temp data register
        //
        //  GPU program word addresses:
        //   0  LD_PARAM R1, #0        R1 = param[0] = input  base
        //   1  LD_PARAM R2, #1        R2 = param[1] = output base
        //   2  LD_PARAM R3, #2        R3 = scalar
        //   3  MOV      R4, #0        R4 = 0  (loop counter)
        //   4  MOV      R5, #4        R5 = 4  (loop limit)
        //   5  NOP                    pipeline fill
        //   6  NOP
        //   -- loop head (addr 7) --
        //   7  ADD64    R6, R1, R4    R6 = input  base + counter
        //   8  ADD64    R7, R2, R4    R7 = output base + counter
        //   9  LD64     R8, [R6+0]    R8 = DMEM[R6]
        //  10  NOP                    LD pipeline bubble
        //  11  NOP
        //  12  ADD_I16  R8, R8, R3    R8[4xi16] += scalar
        //  13  ST64     R8, [R7+0]    DMEM[R7] = R8
        //  14  ADDI64   R4, R4, #1    counter++
        //  15  SETP_GE  R4, R5        PRED = (counter >= 4)
        //  16  BPR      #18           if done → RET at 18
        //  17  BR       #7            else loop back → 7
        //  18  RET
        // =====================================================================

        $display("\n=== PHASE 1: Program GPU IMEM ===");
        imem_sel = 1'b0;  // GPU IMEM

        imem_write(9'd0,  gpu_ld_param(4'd1, 3'd0));     // R1 = param[0]
        imem_write(9'd1,  gpu_ld_param(4'd2, 3'd1));     // R2 = param[1]
        imem_write(9'd2,  gpu_ld_param(4'd3, 3'd2));     // R3 = scalar
        imem_write(9'd3,  gpu_mov(4'd4, 15'd0));          // R4 = 0  (counter)
        imem_write(9'd4,  gpu_mov(4'd5, 15'd4));          // R5 = 4  (limit)
        imem_write(9'd5,  gpu_nop(1'b0));                     // pipeline fill
        imem_write(9'd6,  gpu_nop(1'b0));
        // loop head = addr 7
        imem_write(9'd7,  gpu_add64(4'd6, 4'd1, 4'd4));  // R6 = R1 + R4
        imem_write(9'd8,  gpu_add64(4'd7, 4'd2, 4'd4));  // R7 = R2 + R4
        imem_write(9'd9,  gpu_ld64 (4'd8, 4'd6, 15'd0)); // R8 = DMEM[R6]
        imem_write(9'd10, gpu_nop(1'b0));                     // LD pipeline bubble
        imem_write(9'd11, gpu_nop(1'b0));
        imem_write(9'd12, gpu_add_i16(4'd8, 4'd8, 4'd3));// R8 += scalar
        imem_write(9'd13, gpu_st64 (4'd8, 4'd7, 15'd0)); // DMEM[R7] = R8
        imem_write(9'd14, gpu_addi64(4'd4, 4'd4, 15'd1));// R4++
        imem_write(9'd15, gpu_setp_ge(4'd4, 4'd5));      // PRED = (R4 >= 4)
        imem_write(9'd16, gpu_bpr(9'd18));                // if done → RET at 18
        imem_write(9'd17, gpu_br(9'd7));                  // else loop back → 7
        imem_write(9'd18, gpu_ret(1'b0));                     // done

        repeat(2) @(posedge clk);
        $display("[INFO] GPU IMEM programmed (19 instructions).");

        // =====================================================================
        // PHASE 2 — Program CPU IMEM (imem_sel = 1)
        // =====================================================================
        // R0 is hardwired-zero in the CPU register file, so we use R3/R4/R5
        // as the three working registers for the param values.
        // Pipeline is 5 stages with no forwarding; a MOV result reaches WB
        // after 4 more advance cycles, so 4 NOPs follow every MOV before the
        // WRP that reads its result.
        //
        //  Word  Instruction
        //   0    MOV  R3, #10          R3 = input  base = DMEM word 10
        //   1    NOP
        //   2    NOP
        //   3    NOP
        //   4    NOP
        //   5    WRP  R3, #0           param[0] = R3 = 10
        //   6    NOP
        //   7    NOP
        //   8    MOV  R4, #20          R4 = output base = DMEM word 20
        //   9    NOP
        //  10    NOP
        //  11    NOP
        //  12    NOP
        //  13    WRP  R4, #1           param[1] = R4 = 20
        //  14    NOP
        //  15    NOP
        //  16    MOV  R5, #1           R5 = scalar = 1 per i16 lane
        //  17    NOP
        //  18    NOP
        //  19    NOP
        //  20    NOP
        //  21    WRP  R5, #2           param[2] = R5 = 1
        //  22    NOP
        //  23    NOP
        //  24    NOP
        //  25    NOP
        //  26    GPURUN                launch GPU; CPU stalls until gpu_done
        //  27    NOP
        //  28    NOP
        //  29    NOP
        //  30    B    -2               infinite loop (off24 = 24'hFFFFFE)
        // =====================================================================

        $display("\n=== PHASE 2: Program CPU IMEM ===");
        imem_sel = 1'b1;  // CPU IMEM

        imem_write(9'd0,  cpu_mov(4'd3, 8'd10));    // MOV R3, #10
        imem_write(9'd1,  cpu_nop(1'b0));
        imem_write(9'd2,  cpu_nop(1'b0));
        imem_write(9'd3,  cpu_nop(1'b0));
        imem_write(9'd4,  cpu_nop(1'b0));
        imem_write(9'd5,  cpu_wrp(4'd3, 3'd0));     // WRP R3, #0  → param[0]=10
        imem_write(9'd6,  cpu_nop(1'b0));
        imem_write(9'd7,  cpu_nop(1'b0));
        imem_write(9'd8,  cpu_mov(4'd4, 8'd20));    // MOV R4, #20
        imem_write(9'd9,  cpu_nop(1'b0));
        imem_write(9'd10, cpu_nop(1'b0));
        imem_write(9'd11, cpu_nop(1'b0));
        imem_write(9'd12, cpu_nop(1'b0));
        imem_write(9'd13, cpu_wrp(4'd4, 3'd1));     // WRP R4, #1  → param[1]=20
        imem_write(9'd14, cpu_nop(1'b0));
        imem_write(9'd15, cpu_nop(1'b0));
        imem_write(9'd16, cpu_mov(4'd5, 8'd1));     // MOV R5, #1  (scalar=1 per lane)
        imem_write(9'd17, cpu_nop(1'b0));
        imem_write(9'd18, cpu_nop(1'b0));
        imem_write(9'd19, cpu_nop(1'b0));
        imem_write(9'd20, cpu_nop(1'b0));
        imem_write(9'd21, cpu_wrp(4'd5, 3'd2));     // WRP R5, #2  → param[2]=1
        imem_write(9'd22, cpu_nop(1'b0));
        imem_write(9'd23, cpu_nop(1'b0));
        imem_write(9'd24, cpu_nop(1'b0));
        imem_write(9'd25, cpu_nop(1'b0));
        imem_write(9'd26, cpu_gpurun(1'b0));             // GPURUN
        imem_write(9'd27, cpu_nop(1'b0));
        imem_write(9'd28, cpu_nop(1'b0));
        imem_write(9'd29, cpu_nop(1'b0));
        imem_write(9'd30, cpu_b(24'hFFFFFE));        // B -2  (loop forever)

        repeat(2) @(posedge clk);
        $display("[INFO] CPU IMEM programmed (31 words).");

        // =====================================================================
        // PHASE 3 — Initialise DMEM via Port-A
        //   Input  vector: DMEM[10..13] = {0x0001_0002_0003_0004, ..., ...}
        //   Output region: DMEM[20..23] = 0 (clear first)
        // =====================================================================
        $display("\n=== PHASE 3: Initialise DMEM ===");

        // Input words: each 64-bit word packs 4 × i16 values
        //   word 10: lanes = {1, 2, 3, 4}  → 0x0001_0002_0003_0004
        //   word 11: lanes = {5, 6, 7, 8}  → 0x0005_0006_0007_0008
        //   word 12: lanes = {9,10,11,12}  → 0x0009_000A_000B_000C
        //   word 13: lanes = {13,14,15,16} → 0x000D_000E_000F_0010
        dmem_write(8'd10, 64'h0001_0002_0003_0004);
        dmem_write(8'd11, 64'h0005_0006_0007_0008);
        dmem_write(8'd12, 64'h0009_000A_000B_000C);
        dmem_write(8'd13, 64'h000D_000E_000F_0010);

        // Clear output region
        dmem_write(8'd20, 64'h0);
        dmem_write(8'd21, 64'h0);
        dmem_write(8'd22, 64'h0);
        dmem_write(8'd23, 64'h0);

        repeat(2) @(posedge clk);
        $display("[INFO] DMEM initialised.");
        $display("[INFO] Input  DMEM[10]= 0x0001_0002_0003_0004");
        $display("[INFO] Input  DMEM[11]= 0x0005_0006_0007_0008");
        $display("[INFO] Input  DMEM[12]= 0x0009_000A_000B_000C");
        $display("[INFO] Input  DMEM[13]= 0x000D_000E_000F_0010");
        $display("[INFO] Scalar (param2)= 0x0000_0000_0000_0001  (1 per i16 lane)");
        $display("[INFO] Expected output DMEM[20]= 0x0002_0003_0004_0005");
        $display("[INFO] Expected output DMEM[21]= 0x0006_0007_0008_0009");
        $display("[INFO] Expected output DMEM[22]= 0x000A_000B_000C_000D");
        $display("[INFO] Expected output DMEM[23]= 0x000E_000F_0010_0011");

        // =====================================================================
        // PHASE 4 — Assert run, wait for done
        //   CPU executes: MOVs + WRPs → GPURUN (stalls) → GPU runs → done
        // =====================================================================
        $display("\n=== PHASE 4: Run CPU+GPU system ===");
        @(negedge clk);
        run = 1'b1;
        $display("[INFO] run=1 asserted at time %0t", $time);

        timeout = 0;
        while (!done && timeout < 2000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        if (done) begin
            $display("[PASS] done=1 after %0d cycles  (time %0t)", timeout, $time);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("[FAIL] done never asserted within 2000 cycles");
            fail_cnt = fail_cnt + 1;
        end

        // Keep run asserted; deassert after a few cycles
        repeat(4) @(posedge clk);
        @(negedge clk);
        run = 1'b0;
        repeat(3) @(posedge clk);

        // =====================================================================
        // PHASE 5 — Read back DMEM output and verify
        //   GPU wrote: output[i] = input[i] + 1  (per i16 lane)
        //   output base = DMEM word 20
        //   DMEM[20] = 0x0001_0002_0003_0004 + {1,1,1,1} = 0x0002_0003_0004_0005
        //   DMEM[21] = 0x0005_0006_0007_0008 + {1,1,1,1} = 0x0006_0007_0008_0009
        //   DMEM[22] = 0x0009_000A_000B_000C + {1,1,1,1} = 0x000A_000B_000C_000D
        //   DMEM[23] = 0x000D_000E_000F_0010 + {1,1,1,1} = 0x000E_000F_0010_0011
        // =====================================================================
        $display("\n=== PHASE 5: Verify DMEM output after GPU kernel ===");

        dmem_read_check(8'd20, 64'h0002_0003_0004_0005, 1);
        dmem_read_check(8'd21, 64'h0006_0007_0008_0009, 2);
        dmem_read_check(8'd22, 64'h000A_000B_000C_000D, 3);
        dmem_read_check(8'd23, 64'h000E_000F_0010_0011, 4);

        // =====================================================================
        // PHASE 6 — Verify input DMEM region untouched
        // =====================================================================
        $display("\n=== PHASE 6: Verify input DMEM region untouched ===");

        dmem_read_check(8'd10, 64'h0001_0002_0003_0004, 5);
        dmem_read_check(8'd11, 64'h0005_0006_0007_0008, 6);
        dmem_read_check(8'd12, 64'h0009_000A_000B_000C, 7);
        dmem_read_check(8'd13, 64'h000D_000E_000F_0010, 8);

        // =====================================================================
        // PHASE 7 — Second run (CPU re-executes; pc_reset restarts CPU)
        // =====================================================================
        $display("\n=== PHASE 7: Second kernel run (pc_reset → run again) ===");

        // Overwrite input with fresh values for the second run
        dmem_write(8'd10, 64'h0010_0020_0030_0040);
        dmem_write(8'd11, 64'h0050_0060_0070_0080);
        dmem_write(8'd12, 64'h0090_00A0_00B0_00C0);
        dmem_write(8'd13, 64'h00D0_00E0_00F0_0100);
        // Clear outputs
        dmem_write(8'd20, 64'h0);
        dmem_write(8'd21, 64'h0);
        dmem_write(8'd22, 64'h0);
        dmem_write(8'd23, 64'h0);

        // Reset CPU PC
        @(negedge clk); pc_reset = 1'b1;
        @(posedge clk); #1;
        @(negedge clk); pc_reset = 1'b0;
        repeat(2) @(posedge clk);

        // Run again
        @(negedge clk); run = 1'b1;
        $display("[INFO] Second run: run=1 at time %0t", $time);

        timeout = 0;
        while (!done && timeout < 2000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        if (done) begin
            $display("[PASS] Second done=1 after %0d cycles", timeout);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("[FAIL] Second done never asserted");
            fail_cnt = fail_cnt + 1;
        end

        repeat(4) @(posedge clk);
        @(negedge clk); run = 1'b0;
        repeat(3) @(posedge clk);

        $display("\n=== PHASE 8: Verify second-run output ===");
        dmem_read_check(8'd20, 64'h0011_0021_0031_0041, 9);
        dmem_read_check(8'd21, 64'h0051_0061_0071_0081, 10);
        dmem_read_check(8'd22, 64'h0091_00A1_00B1_00C1, 11);
        dmem_read_check(8'd23, 64'h00D1_00E1_00F1_0101, 12);

        // =====================================================================
        // Summary
        // =====================================================================
        $display("\n========================================");
        $display("  TEST SUMMARY");
        $display("  PASS: %0d   FAIL: %0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("  *** ALL TESTS PASSED ***");
        else
            $display("  *** SOME TESTS FAILED ***");
        $display("========================================\n");

        $finish;
    end

    // =========================================================================
    // Waveform dump
    // =========================================================================
    initial begin
        $dumpfile("tb_cpu_gpu_dmem_top.vcd");
        $dumpvars(0, tb_cpu_gpu_dmem_top);
    end

    // =========================================================================
    // Watchdog — safety net against infinite simulation
    // =========================================================================
    initial begin
        #200000;
        $display("[WATCHDOG] Simulation exceeded 200 µs — forcing finish.");
        $finish;
    end

endmodule
