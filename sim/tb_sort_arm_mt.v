`timescale 1ns/1ns
// =============================================================================
// tb_sort.v  -  Quad bubble-sort testbench for pipeline_p.v
//
// Four identical sort programs are loaded into IMEM, one at each 128-word
// boundary.  Each copy processes a different 10-element array stored in DMEM.
// All words not occupied by a program are filled with NOP (100 NOPs per copy).
//
// IMEM layout (512 words, 9-bit PC):
//   Copy 0:  IMEM[  0..  27] program   IMEM[ 28..127] NOP x100
//   Copy 1:  IMEM[128..155] program   IMEM[156..255] NOP x100
//   Copy 2:  IMEM[256..283] program   IMEM[284..383] NOP x100
//   Copy 3:  IMEM[384..411] program   IMEM[412..511] NOP x100
//
// DMEM layout (256 x 64-bit words, address = alu_result[7:0]):
//   Copy 0:  DMEM[  0..  9]  base=0   [323, 123,-455,  2, 98,125, 10, 65,-56,  0]
//   Copy 1:  DMEM[ 16.. 25]  base=16  [500, -12,  77,300,-88,200, 45,-200, 99, -1]
//   Copy 2:  DMEM[ 32.. 41]  base=32  [  1,   2,   3,  4,  5,  6,  7,  8,  9, 10] (sorted)
//   Copy 3:  DMEM[ 48.. 57]  base=48  [ 10,   9,   8,  7,  6,  5,  4,  3,  2,  1] (reverse)
//
// Program template (28 words, no NOPs, offsets relative to copy base):
// -----------------------------------------------------------------------------
//  +0   main:     MOV  R1,#BASE      R1 = DMEM data base
//  +1             MOV  R0,#0         zero constant
//  +2             MOV  R7,#0         shift=0  (word addr, not byte addr)
//  +3             MOV  R2,#0         i=0
//  +4   i_loop:   MOV  R10,#10       limit
//  +5             SLT  R11,R2,R10    R11=(i<10)?1:0
//  +6             BEQ  R11,R0,done   off=+17 -> +25
//  +7             ADD  R3,R2,#0      j=i
//  +8             ADD  R3,R3,#1      j=i+1
//  +9   j_loop:   SLT  R11,R3,R10   R11=(j<10)?1:0
//  +10            BEQ  R11,R0,i_next off=+11 -> +23
//  +11            SLL  R8,R2,R7      R8=i  (word addr of array[i])
//  +12            ADD  R8,R1,R8      R8=base+i
//  +13            SLL  R9,R3,R7      R9=j
//  +14            ADD  R9,R1,R9      R9=base+j
//  +15            LDR  R5,[R8,#0]    R5=array[i]
//  +16            LDR  R6,[R9,#0]    R6=array[j]
//  +17            SLT  R4,R6,R5      R4=(array[j]<array[i])?1:0
//  +18            BEQ  R4,R0,no_swap off=+1 -> +21
//  +19            STR  R5,[R9,#0]    array[j]=old array[i]
//  +20            STR  R6,[R8,#0]    array[i]=old array[j]
//  +21  no_swap:  ADD  R3,R3,#1      j++
//  +22            B    j_loop        off=-15 (24'hFFFFF1)
//  +23  i_next:   ADD  R2,R2,#1      i++
//  +24            B    i_loop        off=-22 (24'hFFFFEA)
//  +25  done:     NOP
//  +26            B    halt          off=-1  (24'hFFFFFF)
//  +27  halt:     NOP
//  +28..+127      NOP x100           (pad to fill 128-word slot)
//
// Branch offsets (target-branch_word-2) are IDENTICAL for all 4 copies
// because all branches are relative and the internal structure is the same.
//
// Copies 1-3 are started by placing J <base> at IMEM word 0 before each run,
// so the PC jumps immediately to the correct copy after reset.
//
// Memory model:
//   mem_bram_addr = alu_result[7:0] is the DMEM word address.
//   R7=0 so SLL Rx,Ri,R7 = Ri<<0 = Ri (word addr = index).
// =============================================================================

module tb_sort_mt_4_4;

  // ---------------------------------------------------------------------------
  // DUT ports
  // ---------------------------------------------------------------------------
  reg         clk;
  reg         reset;
  reg         run;
  reg         step;
  reg         pc_reset_pulse;

  reg         imem_prog_we;
  reg  [8:0]  imem_prog_addr;
  reg  [31:0] imem_prog_wdata;

  reg         dmem_prog_en;
  reg         dmem_prog_we;
  reg  [7:0]  dmem_prog_addr;
  reg  [63:0] dmem_prog_wdata;
  wire [63:0] dmem_prog_rdata;

  wire [8:0]  pc_dbg;
  wire [31:0] if_instr_dbg;

  integer pass_count;
  integer fail_count;

  // ---------------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------------
  cpu_top_with_Mem dut (
    .clk            (clk),
    .reset          (reset),
    .run            (run),
    .step           (step),
    .pc_reset_pulse (pc_reset_pulse),
    .imem_prog_we   (imem_prog_we),
    .imem_prog_addr (imem_prog_addr),
    .imem_prog_wdata(imem_prog_wdata),
	 
    .dmem_prog_en   (dmem_prog_en),
    .dmem_prog_we   (dmem_prog_we),
    .dmem_prog_addr (dmem_prog_addr),
    .dmem_prog_wdata(dmem_prog_wdata),
    .dmem_prog_rdata(dmem_prog_rdata),
	 
    .pc_dbg         (pc_dbg),
    .if_instr_dbg   (if_instr_dbg)
  );

  `define RF dut.u_rf.regFile

  // ---------------------------------------------------------------------------
  // Clock
  // ---------------------------------------------------------------------------
  localparam CLK_PERIOD = 10;
  initial clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  // ===========================================================================
  // Instruction encoding functions
  // ===========================================================================
  localparam NOP = 32'hE000_0000;

  function [31:0] f_mov;
    input [3:0] Rd; input [7:0] imm8;
    f_mov = {4'hE, 3'b001, 4'b1101, 1'b0, 4'h0, Rd, 4'h0, imm8};
  endfunction

  function [31:0] f_add_r;
    input [3:0] Rd, Rn, Rm;
    f_add_r = {4'hE, 3'b000, 4'b0100, 1'b0, Rn, Rd, 8'h00, Rm};
  endfunction

  function [31:0] f_add_i;
    input [3:0] Rd, Rn; input [7:0] imm8;
    f_add_i = {4'hE, 3'b001, 4'b0100, 1'b0, Rn, Rd, 4'h0, imm8};
  endfunction

  function [31:0] f_sll;
    input [3:0] Rd, Rn, Rm;
    f_sll = {4'hE, 3'b000, 4'b0110, 1'b0, Rn, Rd, 8'h00, Rm};
  endfunction

  function [31:0] f_slt;
    input [3:0] Rd, Rn, Rm;
    f_slt = {4'hE, 3'b000, 4'b1011, 1'b0, Rn, Rd, 8'h00, Rm};
  endfunction

  function [31:0] f_beq;
    input [3:0] Rn, Rm; input [15:0] off16;
    f_beq = {4'hE, 4'b1000, Rn, Rm, off16};
  endfunction

  function [31:0] f_b;
    input [23:0] off24;
    f_b = {4'hE, 4'b1010, off24};
  endfunction

  function [31:0] f_j;
    input [8:0] target9;
    f_j = {6'b111010, 17'b0, target9};
  endfunction

  function [31:0] f_ldr;
    input [3:0] Rd, Rn; input [11:0] off12;
    f_ldr = {4'hE, 8'b0101_1001, Rn, Rd, off12};
  endfunction

  function [31:0] f_str;
    input [3:0] Rd, Rn; input [11:0] off12;
    f_str = {4'hE, 8'b0101_1000, Rn, Rd, off12};
  endfunction

  // ===========================================================================
  // Tasks
  // ===========================================================================
  
  integer file_handle_imem;
  integer file_handle_dmem;
  initial begin
  file_handle_imem = $fopen("imem_mt_4_sort.txt", "w");
  file_handle_dmem = $fopen("dmem_mt_4_sort.txt", "w");
  end
  task program_imem_word;
    input [8:0]  waddr;
    input [31:0] data;
    begin
	 	 	 	   $fwrite(file_handle_imem, "%h;%h\n", waddr, data);

      run = 1'b0; step = 1'b0;
      imem_prog_addr  = waddr;
      imem_prog_wdata = data;
      imem_prog_we    = 1'b1;
      @(posedge clk); #1;
      imem_prog_we = 1'b0;
    end
  endtask

  task program_dmem_word;
    input [7:0]  waddr;
    input [63:0] data;
    begin
	 	 	 	   $fwrite(file_handle_dmem, "%h;%h\n", waddr, data);

      run = 1'b0; step = 1'b0;
      dmem_prog_addr  = waddr;
      dmem_prog_wdata = data;
      dmem_prog_en    = 1'b1;
      dmem_prog_we    = 1'b1;
      @(posedge clk); #1;
      dmem_prog_we = 1'b0;
      dmem_prog_en = 1'b0;
    end
  endtask

  task read_dmem_word;
    input  [7:0]  waddr;
    output [63:0] data;
    begin
      run = 1'b0; step = 1'b0;
      dmem_prog_addr  = waddr;
      dmem_prog_en    = 1'b1;
      dmem_prog_we    = 1'b0;
      dmem_prog_wdata = 64'h0;
      @(posedge clk); #1;
      data = dmem_prog_rdata;
      dmem_prog_en = 1'b0;
      @(posedge clk); #1;
    end
  endtask

  task pulse_pc_reset;
    begin
      pc_reset_pulse = 1'b1;
      @(posedge clk); #1;
      pc_reset_pulse = 1'b0;
      @(posedge clk); #1;
    end
  endtask

  task do_reset;
    begin
      reset          = 1'b1;
      run = 1'b0; step = 1'b0; pc_reset_pulse = 1'b0;
      imem_prog_we   = 1'b0; imem_prog_addr  = 9'h0; imem_prog_wdata = 32'h0;
      dmem_prog_en   = 1'b0; dmem_prog_we    = 1'b0;
      dmem_prog_addr = 8'h0; dmem_prog_wdata = 64'h0;
      repeat(4) @(posedge clk); #1;
      reset = 1'b0;
      @(posedge clk); #1;
    end
  endtask

  task run_cycles;
    input integer n;
    begin
      run = 1'b1;
      repeat(n) @(posedge clk);
      #1;
      run = 1'b0;
    end
  endtask

  task check_dmem;
    input [7:0]   waddr;
    input [63:0]  expected;
    input [127:0] label;
    reg   [63:0]  actual;
    begin
      read_dmem_word(waddr, actual);
      if (actual === expected) begin
        $display("  PASS  %-20s  DMEM[%0d] = 0x%016h  (%0d)",
                 label, waddr, actual, $signed(actual));
        pass_count = pass_count + 1;
      end else begin
        $display("  FAIL  %-20s  DMEM[%0d]  got=0x%016h(%0d)  exp=0x%016h(%0d)",
                 label, waddr, actual, $signed(actual),
                 expected, $signed(expected));
        fail_count = fail_count + 1;
      end
    end
  endtask

  // ===========================================================================
  // program_sort_copy
  //
  // Writes one complete sort program into IMEM starting at word `ibase`.
  // `dbase` is loaded into R1 as the DMEM data base address for this copy.
  // Words ibase+28 through ibase+127 are filled with NOP.
  //
  // All branch offsets are relative and identical across all 4 copies:
  //   BEQ @+6  -> done    @+25 : off = +17
  //   BEQ @+10 -> i_next  @+23 : off = +11
  //   BEQ @+18 -> no_swap @+21 : off = +1
  //   B   @+22 -> j_loop  @+9  : off = -15  (24'hFFFFF1)
  //   B   @+24 -> i_loop  @+4  : off = -22  (24'hFFFFEA)
  //   B   @+26 -> halt    @+27 : off = -1   (24'hFFFFFF)
  // ===========================================================================
  
  task program_sort_copy;
    input [8:0] ibase;   // IMEM start word: 0, 128, 256, or 384
    input [7:0] dbase;   // DMEM data base:  0,  16,  32, or 48
    integer     i;
    begin
      // ?? main: +0..+3 ????????????????????????????????????????????????????????
      program_imem_word(ibase+9'd0,  f_mov(4'd1,  dbase));         // MOV R1,#BASE
      program_imem_word(ibase+9'd1,  f_mov(4'd0,  8'd0));          // MOV R0,#0
      program_imem_word(ibase+9'd2,  f_mov(4'd7,  8'd0));          // MOV R7,#0
      program_imem_word(ibase+9'd3,  f_mov(4'd2,  8'd0));          // MOV R2,#0  i=0

      // ?? i_loop: +4..+8 ??????????????????????????????????????????????????????
      program_imem_word(ibase+9'd4,  f_mov(4'd10, 8'd10));         // MOV R10,#10
      program_imem_word(ibase+9'd5,  f_slt(4'd11,4'd2, 4'd10));   // SLT R11,R2,R10
      // +6: BEQ R11,R0,done | done@+25, off=25-6-2=+17
      program_imem_word(ibase+9'd6,  f_beq(4'd11,4'd0,16'd17));   // BEQ R11,R0,done
      program_imem_word(ibase+9'd7,  f_add_i(4'd3,4'd2,8'd0));    // ADD R3,R2,#0 j=i
      program_imem_word(ibase+9'd8,  f_add_i(4'd3,4'd3,8'd1));    // ADD R3,R3,#1 j=i+1

      // ?? j_loop: +9..+22 ?????????????????????????????????????????????????????
      program_imem_word(ibase+9'd9,  f_slt(4'd11,4'd3, 4'd10));   // SLT R11,R3,R10 //
      // +10: BEQ R11,R0,i_next | i_next@+23, off=23-10-2=+11
      program_imem_word(ibase+9'd10, f_beq(4'd11,4'd0,16'd11));   // BEQ R11,R0,i_next
      program_imem_word(ibase+9'd11, f_sll(4'd8, 4'd2, 4'd7));    // SLL R8,R2,R7
      program_imem_word(ibase+9'd12, f_add_r(4'd8,4'd1,4'd8));    // ADD R8,R1,R8
      program_imem_word(ibase+9'd13, f_sll(4'd9, 4'd3, 4'd7));    // SLL R9,R3,R7
      program_imem_word(ibase+9'd14, f_add_r(4'd9,4'd1,4'd9));    // ADD R9,R1,R9 //
      program_imem_word(ibase+9'd15, f_ldr(4'd5,4'd8,12'd0));     // LDR R5,[R8,#0]
      program_imem_word(ibase+9'd16, f_ldr(4'd6,4'd9,12'd0));     // LDR R6,[R9,#0] //
      program_imem_word(ibase+9'd17, f_slt(4'd4, 4'd6, 4'd5));    // SLT R4,R6,R5
      // +18: BEQ R4,R0,no_swap | no_swap@+21, off=21-18-2=+1
      program_imem_word(ibase+9'd18, f_beq(4'd4, 4'd0,16'd1));    // BEQ R4,R0,no_swap
      program_imem_word(ibase+9'd19, f_str(4'd5,4'd9,12'd0));     // STR R5,[R9,#0]
      program_imem_word(ibase+9'd20, f_str(4'd6,4'd8,12'd0));     // STR R6,[R8,#0]

      // ?? no_swap: +21..+22 ???????????????????????????????????????????????????
      program_imem_word(ibase+9'd21, f_add_i(4'd3,4'd3,8'd1));    // ADD R3,R3,#1 j++
      // +22: B j_loop | j_loop@+9, off=9-22-2=-15 (24'hFFFFF1)
      program_imem_word(ibase+9'd22, f_b(24'hFFFFF1));             // B j_loop

      // ?? i_next: +23..+24 ????????????????????????????????????????????????????
      program_imem_word(ibase+9'd23, f_add_i(4'd2,4'd2,8'd1));    // ADD R2,R2,#1 i++
      // +24: B i_loop | i_loop@+4, off=4-24-2=-22 (24'hFFFFEA)
      program_imem_word(ibase+9'd24, f_b(24'hFFFFEA));             // B i_loop

      // ?? done/halt: +25..+27 ?????????????????????????????????????????????????
      program_imem_word(ibase+9'd25, NOP);                          // done: NOP
      // +26: B halt | halt@+27, off=27-26-2=-1 (24'hFFFFFF)
      program_imem_word(ibase+9'd26, f_b(24'hFFFFFF));             // B halt
      program_imem_word(ibase+9'd27, NOP);                          // halt: NOP

      // ?? NOP padding: +28..+127 (100 words) ??????????????????????????????????
      for (i = 28; i < 128; i = i+1)
        program_imem_word(ibase + i[8:0], NOP);
    end
  endtask

  // ---------------------------------------------------------------------------
  // WB monitor
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (!reset && dut.cpu_mt_mt.wb_wen)
      $display("[%0t] WB  R%0d <- 0x%016h  (pc=%0d)",
               $time, dut.cpu_mt_mt.wb_waddr, dut.cpu_mt_mt.wb_wdata, pc_dbg);
  end

  // ===========================================================================
  // MAIN
  // ===========================================================================
  initial begin
    pass_count = 0; fail_count = 0;
    reset = 1'b1; run = 1'b0; step = 1'b0; pc_reset_pulse = 1'b0;
    imem_prog_we   = 1'b0; imem_prog_addr  = 9'h0; imem_prog_wdata = 32'h0;
    dmem_prog_en   = 1'b0; dmem_prog_we    = 1'b0;
    dmem_prog_addr = 8'h0; dmem_prog_wdata = 64'h0;

    $dumpfile("tb_sort_mt_4_4.vcd");
    $dumpvars(0, tb_sort_mt_4_4);

    $display("=============================================================");
    $display("  Quad Bubble-Sort Testbench  (pipeline_p.v, no NOPs)");
    $display("=============================================================");

    repeat(3) @(posedge clk); #1;
    reset = 1'b0;
    @(posedge clk); #1;

    // =========================================================================
    // Step 1 ? Load DMEM: four 10-element arrays at words 0, 16, 32, 48
    // =========================================================================
    $display("\n--- Loading DMEM ---");

    // Copy 0: DMEM[0..9]  [323, 123, -455, 2, 98, 125, 10, 65, -56, 0]
    program_dmem_word(8'd0,  64'h0000000000000143); //  323
    program_dmem_word(8'd1,  64'h000000000000007B); //  123
    program_dmem_word(8'd2,  64'hFFFFFFFFFFFFFE39); // -455
    program_dmem_word(8'd3,  64'h0000000000000002); //    2
    program_dmem_word(8'd4,  64'h0000000000000062); //   98
    program_dmem_word(8'd5,  64'h000000000000007D); //  125
    program_dmem_word(8'd6,  64'h000000000000000A); //   10
    program_dmem_word(8'd7,  64'h0000000000000041); //   65
    program_dmem_word(8'd8,  64'hFFFFFFFFFFFFFFC8); //  -56
    program_dmem_word(8'd9,  64'h0000000000000000); //    0
    $display("  C0 DMEM[0..9]:   [323,123,-455,2,98,125,10,65,-56,0]");

    // Copy 1: DMEM[16..25]  [500, -12, 77, 300, -88, 200, 45, -200, 99, -1]
    program_dmem_word(8'd16, 64'h00000000000001F4); //  500
    program_dmem_word(8'd17, 64'hFFFFFFFFFFFFFFF4); //  -12
    program_dmem_word(8'd18, 64'h000000000000004D); //   77
    program_dmem_word(8'd19, 64'h000000000000012C); //  300
    program_dmem_word(8'd20, 64'hFFFFFFFFFFFFFFA8); //  -88
    program_dmem_word(8'd21, 64'h00000000000000C8); //  200
    program_dmem_word(8'd22, 64'h000000000000002D); //   45
    program_dmem_word(8'd23, 64'hFFFFFFFFFFFFFF38); // -200
    program_dmem_word(8'd24, 64'h0000000000000063); //   99
    program_dmem_word(8'd25, 64'hFFFFFFFFFFFFFFFF); //   -1
    $display("  C1 DMEM[16..25]: [500,-12,77,300,-88,200,45,-200,99,-1]");

    // Copy 2: DMEM[32..41]  [1..10]  (already sorted ? best case)
    program_dmem_word(8'd32, 64'h0000000000000001);
    program_dmem_word(8'd33, 64'h0000000000000002);
    program_dmem_word(8'd34, 64'h0000000000000003);
    program_dmem_word(8'd35, 64'h0000000000000004);
    program_dmem_word(8'd36, 64'h0000000000000005);
    program_dmem_word(8'd37, 64'h0000000000000006);
    program_dmem_word(8'd38, 64'h0000000000000007);
    program_dmem_word(8'd39, 64'h0000000000000008);
    program_dmem_word(8'd40, 64'h0000000000000009);
    program_dmem_word(8'd41, 64'h000000000000000A);
    $display("  C2 DMEM[32..41]: [1,2,3,4,5,6,7,8,9,10]  (already sorted)");

    // Copy 3: DMEM[48..57]  [10..1]  (reverse sorted ? worst case)
    program_dmem_word(8'd48, 64'h000000000000000A);
    program_dmem_word(8'd49, 64'h0000000000000009);
    program_dmem_word(8'd50, 64'h0000000000000008);
    program_dmem_word(8'd51, 64'h0000000000000007);
    program_dmem_word(8'd52, 64'h0000000000000006);
    program_dmem_word(8'd53, 64'h0000000000000005);
    program_dmem_word(8'd54, 64'h0000000000000004);
    program_dmem_word(8'd55, 64'h0000000000000003);
    program_dmem_word(8'd56, 64'h0000000000000002);
    program_dmem_word(8'd57, 64'h0000000000000001);
    $display("  C3 DMEM[48..57]: [10,9,8,7,6,5,4,3,2,1]  (reverse sorted)");

    // =========================================================================
    // Step 2 ? Load IMEM: 4 program copies, each 128 words (28 instr + 100 NOP)
    // =========================================================================
    $display("\n--- Programming IMEM (4 x 128 = 512 words) ---");
    do_reset;

    program_sort_copy(9'd0,   8'd0);   // Copy 0: IMEM[  0..127], DMEM base  0
    program_sort_copy(9'd128, 8'd16);  // Copy 1: IMEM[128..255], DMEM base 16
    program_sort_copy(9'd256, 8'd32);  // Copy 2: IMEM[256..383], DMEM base 32
    program_sort_copy(9'd384, 8'd48);  // Copy 3: IMEM[384..511], DMEM base 48
    $display("  Done. IMEM fully programmed (512 words).");

    // =========================================================================
    // Step 3 ? Run each copy
    //
    // Copy 0: PC resets to 0, runs directly.
    // Copies 1-3: Place J <ibase> at IMEM word 0 so PC jumps immediately
    //             after reset.  IMEM[0] is restored after each run by
    //             program_sort_copy filling it with the real instruction.
    //             (The J at word 0 overwrites the real MOV R1 of copy 0,
    //              but copy 0 has already finished by then.)
    //
    // Cycle budget per copy:
    //   ~55 j-loop iterations x 14 instr = 770 cycles
    //   ~10 i-loop iterations x  5 instr =  50 cycles
    //   ~110 branch penalties  x  2       = 220 cycles
    //   Total ~1040; run 3000 for margin.
    // =========================================================================

    // -- Copy 0 (IMEM base 0, DMEM base 0) ------------------------------------
    $display("\n--- Running Copy 0 (IMEM[0..127], DMEM base=0) ---");
    pulse_pc_reset();                          // PC <- 0
    run_cycles(8000);

    // -- Copy 1 (IMEM base 128, DMEM base 16) ----------------------------------
    //$display("\n--- Running Copy 1 (IMEM[128..255], DMEM base=16) ---");
    //program_imem_word(9'd0, f_j(9'd128));      // patch word 0: J 128
    //pulse_pc_reset();                          // PC <- 0; pipeline fetches J 128
    //run_cycles(3000);

    // -- Copy 2 (IMEM base 256, DMEM base 32) ----------------------------------
    //$display("\n--- Running Copy 2 (IMEM[256..383], DMEM base=32) ---");
    //program_imem_word(9'd0, f_j(9'd256));      // patch word 0: J 256
    //pulse_pc_reset();
    //run_cycles(3000);

    // -- Copy 3 (IMEM base 384, DMEM base 48) ----------------------------------
    //$display("\n--- Running Copy 3 (IMEM[384..511], DMEM base=48) ---");
    //program_imem_word(9'd0, f_j(9'd384));      // patch word 0: J 384
    //pulse_pc_reset();
    ///run_cycles(3000);

    // =========================================================================
    // Step 4 ? Verify all four sorted arrays in DMEM
    // =========================================================================
    $display("\n--- Verifying results ---");

    // Copy 0: [-455,-56,0,2,10,65,98,123,125,323]
    $display("\n  Copy 0  DMEM[0..9]  expected: [-455,-56,0,2,10,65,98,123,125,323]");
    check_dmem(8'd0,  64'hFFFFFFFFFFFFFE39, "C0[0]=-455");
    check_dmem(8'd1,  64'hFFFFFFFFFFFFFFC8, "C0[1]=-56");
    check_dmem(8'd2,  64'h0000000000000000, "C0[2]=0");
    check_dmem(8'd3,  64'h0000000000000002, "C0[3]=2");
    check_dmem(8'd4,  64'h000000000000000A, "C0[4]=10");
    check_dmem(8'd5,  64'h0000000000000041, "C0[5]=65");
    check_dmem(8'd6,  64'h0000000000000062, "C0[6]=98");
    check_dmem(8'd7,  64'h000000000000007B, "C0[7]=123");
    check_dmem(8'd8,  64'h000000000000007D, "C0[8]=125");
    check_dmem(8'd9,  64'h0000000000000143, "C0[9]=323");

    // Copy 1: [-200,-88,-12,-1,45,77,99,200,300,500]
    $display("\n  Copy 1  DMEM[16..25]  expected: [-200,-88,-12,-1,45,77,99,200,300,500]");
    check_dmem(8'd16, 64'hFFFFFFFFFFFFFF38, "C1[0]=-200");
    check_dmem(8'd17, 64'hFFFFFFFFFFFFFFA8, "C1[1]=-88");
    check_dmem(8'd18, 64'hFFFFFFFFFFFFFFF4, "C1[2]=-12");
    check_dmem(8'd19, 64'hFFFFFFFFFFFFFFFF, "C1[3]=-1");
    check_dmem(8'd20, 64'h000000000000002D, "C1[4]=45");
    check_dmem(8'd21, 64'h000000000000004D, "C1[5]=77");
    check_dmem(8'd22, 64'h0000000000000063, "C1[6]=99");
    check_dmem(8'd23, 64'h00000000000000C8, "C1[7]=200");
    check_dmem(8'd24, 64'h000000000000012C, "C1[8]=300");
    check_dmem(8'd25, 64'h00000000000001F4, "C1[9]=500");

    // Copy 2: [1,2,3,4,5,6,7,8,9,10]  (unchanged ? already sorted)
    $display("\n  Copy 2  DMEM[32..41]  expected: [1,2,3,4,5,6,7,8,9,10]  (unchanged)");
    check_dmem(8'd32, 64'h0000000000000001, "C2[0]=1");
    check_dmem(8'd33, 64'h0000000000000002, "C2[1]=2");
    check_dmem(8'd34, 64'h0000000000000003, "C2[2]=3");
    check_dmem(8'd35, 64'h0000000000000004, "C2[3]=4");
    check_dmem(8'd36, 64'h0000000000000005, "C2[4]=5");
    check_dmem(8'd37, 64'h0000000000000006, "C2[5]=6");
    check_dmem(8'd38, 64'h0000000000000007, "C2[6]=7");
    check_dmem(8'd39, 64'h0000000000000008, "C2[7]=8");
    check_dmem(8'd40, 64'h0000000000000009, "C2[8]=9");
    check_dmem(8'd41, 64'h000000000000000A, "C2[9]=10");

    // Copy 3: [1,2,3,4,5,6,7,8,9,10]  (worst-case reverse)
    $display("\n  Copy 3  DMEM[48..57]  expected: [1,2,3,4,5,6,7,8,9,10]  (from reverse)");
    check_dmem(8'd48, 64'h0000000000000001, "C3[0]=1");
    check_dmem(8'd49, 64'h0000000000000002, "C3[1]=2");
    check_dmem(8'd50, 64'h0000000000000003, "C3[2]=3");
    check_dmem(8'd51, 64'h0000000000000004, "C3[3]=4");
    check_dmem(8'd52, 64'h0000000000000005, "C3[4]=5");
    check_dmem(8'd53, 64'h0000000000000006, "C3[5]=6");
    check_dmem(8'd54, 64'h0000000000000007, "C3[6]=7");
    check_dmem(8'd55, 64'h0000000000000008, "C3[7]=8");
    check_dmem(8'd56, 64'h0000000000000009, "C3[8]=9");
    check_dmem(8'd57, 64'h000000000000000A, "C3[9]=10");

    // =========================================================================
    // Summary
    // =========================================================================
    $display("\n=============================================================");
    $display("  Results: %0d PASSED   %0d FAILED", pass_count, fail_count);
    $display("=============================================================");
    if (fail_count == 0)
      $display("  ALL TESTS PASSED");
    else
      $display("  *** FAILURES - inspect tb_sort.vcd ***");
    $display("=============================================================\n");
	  $fclose(file_handle_dmem);
	  $fclose(file_handle_imem);
    $finish;
  end

  // ---------------------------------------------------------------------------
  // Watchdog: 4 runs x 3000 cycles x 10 ns + margin
  // ---------------------------------------------------------------------------
  initial begin
    #20_000_000;
    $display("TIMEOUT - simulation exceeded 20 ms");
    $finish;
  end

endmodule
