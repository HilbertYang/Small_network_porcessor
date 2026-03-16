// tb_fifo_instrs.v
// Focused testbench for cpu_gpu_dmem_top — exercises the three new FIFO
// instructions in cpu_arm_mt:
//
//   RDF  Rd,#sel   {8'b10101111, Rd[3:0], 19'b0, sel}
//                  Rd = (sel==0) ? fifo_start_offset : fifo_end_offset
//                  Result available at WB: 4 NOPs needed before dependent use.
//
//   FIFOWAIT       {8'b10101100, 24'b0}
//                  Stall pipeline (advance=0) until fifo_data_ready=1.
//
//   FIFODONE       {8'b10101011, 24'b0}
//                  Assert fifo_data_done=1 for exactly one clock cycle (in EX).
//
// ── Test plan ────────────────────────────────────────────────────────────────
//
// TEST A — RDF basic read (no wait)
//   fifo_data_ready is held 1 throughout.
//   CPU program:
//     0: RDF  R3, #0      R3 = fifo_start_offset (driven = 8'hA5)
//     1: NOP
//     2: NOP
//     3: NOP
//     4: NOP              (4 NOPs: RDF writes back at WB after IF→ID→EX→MEM→WB)
//     5: RDF  R4, #1      R4 = fifo_end_offset   (driven = 8'h3C)
//     6: NOP
//     7: NOP
//     8: NOP
//     9: NOP
//    10: MOV  R8, #50     R8 = 50  (DMEM base for readback, avoid R0)
//    11: NOP
//    12: NOP
//    13: NOP
//    14: NOP
//    15: STR  R3,[R8,#0]  DMEM[50] = R3  (fifo_start_offset)
//    16: NOP
//    17: STR  R4,[R8,#1]  DMEM[51] = R4  (fifo_end_offset)
//    18: NOP
//    19: NOP
//    20: NOP
//    21: NOP
//    22: B    -2          infinite loop
//   Verify: DMEM[50]==0xA5, DMEM[51]==0x3C
//
// TEST B — FIFOWAIT stall + RDF after release
//   CPU program (reloaded after pc_reset):
//     0: FIFOWAIT          stall until fifo_data_ready
//     1: NOP               pipeline fill after stall releases
//     2: NOP
//     3: RDF  R3, #0       R3 = fifo_start_offset (driven = 8'h12 after ready)
//     4: NOP
//     5: NOP
//     6: NOP
//     7: NOP
//     8: RDF  R4, #1       R4 = fifo_end_offset   (driven = 8'hFE after ready)
//     9: NOP
//    10: NOP
//    11: NOP
//    12: NOP
//    13: MOV  R8, #60      R8 = 60  (DMEM base)
//    14: NOP
//    15: NOP
//    16: NOP
//    17: NOP
//    18: STR  R3,[R8,#0]   DMEM[60] = R3
//    19: NOP
//    20: STR  R4,[R8,#1]   DMEM[61] = R4
//    21: NOP
//    22: NOP
//    23: NOP
//    24: NOP
//    25: B    -2            loop
//   Sequence: run=1, fifo_data_ready=0 for 20 cycles, then fifo_data_ready=1.
//   Verify: CPU stalled while ready=0, then DMEM[60]==0x12, DMEM[61]==0xFE.
//
// TEST C — FIFODONE pulse width
//   CPU program (reloaded after pc_reset):
//     0: FIFODONE          fifo_data_done=1 for exactly one cycle
//     1: NOP
//     2: NOP
//     3: NOP
//     4: B    -2           loop (never hits FIFODONE again)
//   Monitor fifo_data_done: expect exactly 1 rising-edge and 1 falling-edge.
//   Fail if it pulses more than once, or never pulses.
//
// TEST D — FIFOWAIT then FIFODONE in sequence
//   CPU program:
//     0: FIFOWAIT
//     1: NOP
//     2: NOP
//     3: FIFODONE
//     4: NOP
//     5: NOP
//     6: NOP
//     7: B    -2
//   fifo_data_ready asserted after 15 cycles.
//   Verify FIFODONE pulse occurs AFTER FIFOWAIT releases.
//
// ── Instruction encodings ────────────────────────────────────────────────────
//   NOP       32'hE000_0000
//   MOV Rd,#i {4'hE,2'b00,1'b1,4'b1101,1'b0,4'h0,Rd,4'h0,imm8}  Rn=R0(=0)
//   STR Rd,[Rn,#off12]
//             op=01 I=0 P=1 U=1 B=0 W=0 L=0
//             {4'hE,2'b01,1'b1,4'b1000,Rn[3:0],Rd[3:0],off12[11:0]}
//   B   off24 {4'hE,8'hEA,off24}   off24 = target - (PC+2)
//   RDF Rd,sel {8'b10101111,Rd,19'b0,sel}
//   FIFOWAIT  {8'b10101100,24'b0}
//   FIFODONE  {8'b10101011,24'b0}
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps

module tb_fifo_instrs;

    // =========================================================================
    // DUT signals
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

    reg  [7:0]  fifo_start_offset;
    reg  [7:0]  fifo_end_offset;
    reg         fifo_data_ready;
    wire        fifo_data_done;

    wire [8:0]  cpu_pc_dbg;
    wire [31:0] cpu_instr_dbg;
    wire [8:0]  gpu_pc_dbg;
    wire [31:0] gpu_instr_dbg;
	 
	 reg [8:0] cpu_pc_prev;
	 always @ (posedge clk) begin
		cpu_pc_prev <= cpu_pc_dbg; 
	 end

    // =========================================================================
    // DUT
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
        .cpu_pc_dbg       (cpu_pc_dbg),
        .cpu_instr_dbg    (cpu_instr_dbg),
        .gpu_pc_dbg       (gpu_pc_dbg),
        .gpu_instr_dbg    (gpu_instr_dbg)
    );

    // =========================================================================
    // Clock  (10 ns period)
    // =========================================================================
    initial clk = 0;
    always  #5 clk = ~clk;

    // =========================================================================
    // Pass / fail counters
    // =========================================================================
    integer pass_cnt, fail_cnt;

    task pass; input [127:0] msg; begin
        $display("[PASS] %s  (t=%0t)", msg, $time);
        pass_cnt = pass_cnt + 1;
    end endtask

    task fail; input [127:0] msg; begin
        $display("[FAIL] %s  (t=%0t)", msg, $time);
        fail_cnt = fail_cnt + 1;
    end endtask

    // =========================================================================
    // Task: write one CPU IMEM word
    // =========================================================================
    task cpu_imem_write;
        input [8:0]  addr;
        input [31:0] data;
        begin
            @(negedge clk);
            imem_sel        = 1'b1;   // CPU IMEM
            imem_prog_we    = 1'b1;
            imem_prog_addr  = addr;
            imem_prog_wdata = data;
            @(posedge clk);
            @(negedge clk);
            imem_prog_we    = 1'b0;
        end
    endtask

    // =========================================================================
    // Task: write one 64-bit word to DMEM via Port-A
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
    // Task: read one 64-bit word from DMEM via Port-A and check value
    //   Port-A is a sync BRAM (Write-First): addr latches on posedge,
    //   dout valid one clock later.  Keep en=1 across both edges.
    // =========================================================================
    task dmem_check;
        input [7:0]  addr;
        input [63:0] expected;
        input [63:0] test_num;
        reg   [63:0] got;
        begin
            @(negedge clk);
            dmem_prog_en    = 1'b1;
            dmem_prog_we    = 1'b0;
            dmem_prog_addr  = addr;
            @(posedge clk); #1;   // addr latched
            @(posedge clk); #1;   // dout valid
            got = dmem_prog_rdata;
            @(negedge clk);
            dmem_prog_en = 1'b0;
            if (got === expected) begin
                $display("[PASS] T%0d  DMEM[%0d]=0x%016h  (expected 0x%016h)",
                          test_num, addr, got, expected);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("[FAIL] T%0d  DMEM[%0d]=0x%016h  (expected 0x%016h)",
                          test_num, addr, got, expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // =========================================================================
    // Task: pulse pc_reset to restart CPU without touching IMEM
    // =========================================================================
    task cpu_reset;
        begin
            @(negedge clk); run = 1'b0;
            @(negedge clk); pc_reset = 1'b1;
            @(posedge clk); #1;
            @(negedge clk); pc_reset = 1'b0;
            repeat(2) @(posedge clk);
        end
    endtask

    // =========================================================================
    // Instruction encoding functions
    // =========================================================================

    // NOP
    function [31:0] NOP;
	 		  input a;
        begin NOP = 32'hE000_0000; end
    endfunction

    // MOV Rd, #imm8   — Rn=R0 (hardwired 0) so result = 0+imm8 = imm8
    //   {4'hE, 2'b00, 1'b1, 4'b1101, 1'b0, 4'h0, Rd, 4'h0, imm8}
    function [31:0] MOV;
        input [3:0] rd;
        input [7:0] imm8;
        begin MOV = {4'hE, 3'b001, 4'b1101, 1'b0, 4'h0, rd, 4'h0, imm8}; end
    endfunction

    // STR Rd, [Rn, #off12]   (positive offset, pre-index, no writeback)
    //   op=01  I=0  P=1  U=1  B=0  W=0  L=0
    //   bits[27:20] = 8'b0110_0000  →  {2'b01, 6'b10_0000}
    //   {4'hE, 2'b01, 1'b1, 4'b1000, Rn, Rd, off12}
    //   Note: STR reads Rd from port-1 (id_reg2 = if_Rd when op=01 & ~L)
    function [31:0] STR;
        input [3:0]  rd;   // data register  (stored to memory)
        input [3:0]  rn;   // base  register (address)
        input [11:0] off;  // unsigned word offset
        begin STR = {4'hE, 8'b0101_1000, rn, rd, off}; end
    endfunction

    // B off24   {4'hE, 8'hEA, off24}   off24 = target - (PC+2)
    function [31:0] B;
        input signed [23:0] off24;
        begin B = {4'hE, 4'b1010, off24}; end
    endfunction

    // RDF Rd, #sel   {8'b10101111, Rd, 19'b0, sel}
    function [31:0] RDF;
        input [3:0] rd;
        input       sel;   // 0=start_offset  1=end_offset
        begin RDF = {8'b10101111, rd, 19'b0, sel}; end
    endfunction

    // FIFOWAIT   {8'b10101100, 24'b0}
    function [31:0] FIFOWAIT;
		  input a;
        begin FIFOWAIT = {8'b10101100, 24'b0}; end
    endfunction

    // FIFODONE   {8'b10101011, 24'b0}
    function [31:0] FIFODONE;
	 		  input a;
        begin FIFODONE = {8'b10101011, 24'b0}; end
    endfunction

    // =========================================================================
    // FIFO_DATA_DONE pulse monitor:
    //   Counts rising edges on fifo_data_done over a window of `cycles` clocks.
    //   Checks pulse width is exactly 1 cycle per pulse.
    // =========================================================================
    integer fd_pulse_count;
    integer fd_max_width;
    integer fd_cur_width;

    task monitor_fifodone;
        input integer window_cycles;
        integer i;
        begin
            fd_pulse_count = 0;
            fd_max_width   = 0;
            fd_cur_width   = 0;
            for (i = 0; i < window_cycles; i = i + 1) begin
                @(posedge clk); #1;
                if (fifo_data_done) begin
                    fd_cur_width = fd_cur_width + 1;
                    if (fd_cur_width == 1) fd_pulse_count = fd_pulse_count + 1;
                    if (fd_cur_width > fd_max_width) fd_max_width = fd_cur_width;
                end else begin
                    fd_cur_width = 0;
                end
            end
        end
    endtask

    // =========================================================================
    // Main stimulus
    // =========================================================================
    integer i;
    integer stall_cycles;
    integer advance_seen;

    initial begin
        // ---- defaults ----
        pass_cnt         = 0;
        fail_cnt         = 0;
        reset            = 1'b1;
        run              = 1'b0;
        step             = 1'b0;
        pc_reset         = 1'b0;
        imem_sel         = 1'b1;
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
        // TEST A — RDF reads fifo_start_offset and fifo_end_offset into
        //          registers, then STRs them to DMEM for readback.
        //
        // fifo_data_ready=1 throughout (no stall).
        // fifo_start_offset = 8'hA5,  fifo_end_offset = 8'h3C
        //
        // CPU IMEM:
        //   0: RDF  R3, #0       R3 = fifo_start_offset
        //   1-4: NOP x4          wait for WB (4 advance cycles)
        //   5: RDF  R4, #1       R4 = fifo_end_offset
        //   6-9: NOP x4
        //  10: MOV  R8, #50      R8 = DMEM base address (non-zero reg)
        //  11-14: NOP x4         wait for MOV WB
        //  15: STR  R3,[R8,#0]   DMEM[50] = R3 = 0xA5
        //  16: NOP
        //  17: STR  R4,[R8,#1]   DMEM[51] = R4 = 0x3C
        //  18-21: NOP x4
        //  22: B    -2            loop forever (off24 = 24'hFFFFFE)
        // =====================================================================
        $display("\n========================================");
        $display("TEST A: RDF basic read (no stall)");
        $display("========================================");

        // Drive FIFO offset ports with known values
        fifo_start_offset = 8'hA5;
        fifo_end_offset   = 8'h3C;
        fifo_data_ready   = 1'b1;   // no stall for this test

        // Clear DMEM readback locations
        dmem_write(8'd50, 64'h0);
        dmem_write(8'd51, 64'h0);

        // Load CPU IMEM
        cpu_imem_write(9'd0,  RDF(4'd3, 1'b0));      //  0: RDF R3,#0
        cpu_imem_write(9'd1,  NOP(1'b0));                  //  4: NOP
        cpu_imem_write(9'd2,  RDF(4'd4, 1'b1));       //  5: RDF R4,#1
        cpu_imem_write(9'd3,  NOP(1'b0));                  //  6: NOP
        cpu_imem_write(9'd4, MOV(4'd8, 8'd50));       // 10: MOV R8,#50
        cpu_imem_write(9'd5, NOP(1'b0));                  // 11: NOP
        cpu_imem_write(9'd6, STR(4'd3, 4'd8, 12'd0));// 15: STR R3,[R8,#0]
        cpu_imem_write(9'd7, NOP(1'b0));                  // 16: NOP
        cpu_imem_write(9'd8, STR(4'd4, 4'd8, 12'd1));// 17: STR R4,[R8,#1]
        cpu_imem_write(9'd9, NOP(1'b0));                  // 18: NOP
        cpu_imem_write(9'd10, B(24'hFFFFFE));          // 22: B -2

        // Run for enough cycles to execute the program
		  $stop;
        @(negedge clk); run = 1'b1;
        repeat(200) @(posedge clk);
        @(negedge clk); run = 1'b0;
        repeat(3)  @(posedge clk);
			
        // Readback
        $display("[INFO] A: fifo_start_offset=0x%02h  fifo_end_offset=0x%02h",
                  fifo_start_offset, fifo_end_offset);
        dmem_check(8'd50, 64'h0000_0000_0000_00A5, 1); // R3 = start = 0xA5
        dmem_check(8'd51, 64'h0000_0000_0000_003C, 2); // R4 = end   = 0x3C

        // =====================================================================
        // TEST A2 — RDF with different offset values (hot-swap while running).
        //           Reload same program, change offsets, re-run.
        // =====================================================================
        $display("\n========================================");
        $display("TEST A2: RDF with new offset values");
        $display("========================================");

        fifo_start_offset = 8'hBB;
        fifo_end_offset   = 8'h77;

        dmem_write(8'd50, 64'h0);
        dmem_write(8'd51, 64'h0);

        cpu_reset();

        @(negedge clk); run = 1'b1;
        repeat(200) @(posedge clk);
        @(negedge clk); run = 1'b0;
        repeat(3)  @(posedge clk);

        dmem_check(8'd50, 64'h0000_0000_0000_00BB, 3);
        dmem_check(8'd51, 64'h0000_0000_0000_0077, 4);

        // =====================================================================
        // TEST B — FIFOWAIT stall.
        //   CPU must not advance past FIFOWAIT until fifo_data_ready=1.
        //
        //   We measure CPU PC progress:
        //   - For 20 cycles with ready=0, PC should stay frozen at the
        //     FIFOWAIT instruction (pc_dbg should not advance beyond ~word 3).
        //   - After ready=1 the pipeline resumes and STRs write DMEM.
        //
        // CPU IMEM:
        //   0: FIFOWAIT
        //   1: NOP
        //   2: NOP
        //   3: RDF  R3, #0
        //   4-7: NOP x4
        //   8: RDF  R4, #1
        //   9-12: NOP x4
        //  13: MOV  R8, #60
        //  14-17: NOP x4
        //  18: STR  R3,[R8,#0]   DMEM[60] = start_offset
        //  19: NOP
        //  20: STR  R4,[R8,#1]   DMEM[61] = end_offset
        //  21-24: NOP x4
        //  25: B    -2
        // =====================================================================
        $display("\n========================================");
        $display("TEST B: FIFOWAIT stall then release");
        $display("========================================");

        fifo_start_offset = 8'h12;
        fifo_end_offset   = 8'hFE;
        fifo_data_ready   = 1'b0;   // start with ready=0 → will stall

        dmem_write(8'd60, 64'h0);
        dmem_write(8'd61, 64'h0);

        // Load new CPU IMEM
        cpu_reset();
        cpu_imem_write(9'd0,  FIFOWAIT(1'b0));             //  0: FIFOWAIT
        cpu_imem_write(9'd1,  NOP(1'b0));                  //  1: NOP
        cpu_imem_write(9'd2,  RDF(4'd3, 1'b0));       //  3: RDF R3,#0
        cpu_imem_write(9'd3,  NOP(1'b0));                  //  4: NOP
        cpu_imem_write(9'd4,  RDF(4'd4, 1'b1));       //  8: RDF R4,#1
        cpu_imem_write(9'd5,  NOP(1'b0));                  //  9: NOP
        cpu_imem_write(9'd6, MOV(4'd8, 8'd60));       // 13: MOV R8,#60
        cpu_imem_write(9'd7, NOP(1'b0));                  // 14: NOP
        cpu_imem_write(9'd8, STR(4'd3, 4'd8, 12'd0));// 18: STR R3,[R8,#0]
        cpu_imem_write(9'd9, NOP(1'b0));                  // 19: NOP
        cpu_imem_write(9'd10, STR(4'd4, 4'd8, 12'd1));// 20: STR R4,[R8,#1]
        cpu_imem_write(9'd11, NOP(1'b0));                  // 21: NOP
        cpu_imem_write(9'd12, B(24'hFFFFFE));          // 25: B -2

        // Start running — FIFOWAIT should freeze the pipeline immediately
        @(negedge clk); run = 1'b1;
        $display("[INFO] B: run=1, ready=0, stall begins.");

        // Sample PC for 20 cycles — it must not advance past word 4
        // (FIFOWAIT is at word 0; the pipeline fills 2 stages before stalling,
        //  so by the time FIFOWAIT reaches EX, PC has moved to ~3..4 at most)
        begin : check_stall
            reg stall_ok;
            stall_ok = 1'b1;
				//repeat(6) @(posedge clk)
				repeat(4) @(posedge clk);
            repeat(20) begin
                @(posedge clk); #1;
                // PC should stay ≤ 6 while stalled
                // (pipeline has 2-cycle fetch latency before FIFOWAIT hits EX)
                if (cpu_pc_dbg != cpu_pc_prev) begin
                    $display("[FAIL] T5 PC advanced to %0d during stall (t=%0t)",
                              cpu_pc_dbg, $time);
                    stall_ok = 1'b0;
                    fail_cnt = fail_cnt + 1;
                end
            end
            if (stall_ok) begin
                $display("[PASS] T5 PC held while fifo_data_ready=0 (max PC=%0d)",
                          cpu_pc_dbg);
                pass_cnt = pass_cnt + 1;
            end
        end

        // Release the stall
        @(negedge clk); fifo_data_ready = 1'b1;
        $display("[INFO] B: fifo_data_ready=1 asserted at t=%0t", $time);

        // Run until STRs complete
        repeat(200) @(posedge clk);
        @(negedge clk); run = 1'b0;
        fifo_data_ready = 1'b0;
        repeat(3) @(posedge clk);

        // Verify DMEM was written after stall released
        dmem_check(8'd60, 64'h0000_0000_0000_0012, 6); // start_offset=0x12
        dmem_check(8'd61, 64'h0000_0000_0000_00FE, 7); // end_offset=0xFE

        // =====================================================================
        // TEST C — FIFODONE pulse width check.
        //   FIFODONE must assert fifo_data_done for exactly ONE clock cycle.
        //   We monitor for 60 cycles and count rising edges / max width.
        //
        // CPU IMEM:
        //   0: FIFODONE       pulse fifo_data_done
        //   1: NOP
        //   2: NOP
        //   3: NOP
        //   4: B    -2         infinite loop (never hits FIFODONE again)
        // =====================================================================
        $display("\n========================================");
        $display("TEST C: FIFODONE pulse width");
        $display("========================================");

        fifo_data_ready = 1'b1;  // no stall needed

        cpu_reset();
        cpu_imem_write(9'd1, FIFODONE(1'b0));         //  0: FIFODONE
        cpu_imem_write(9'd0, NOP(1'b0));              //  1: NOP
        cpu_imem_write(9'd2, NOP(1'b0));              //  2: NOP
        cpu_imem_write(9'd3, NOP(1'b0));              //  3: NOP
        cpu_imem_write(9'd4, B(24'hFFFFFE));      //  4: B -2

        // Fork: start CPU and simultaneously watch fifo_data_done
        @(negedge clk); run = 1'b1;

        // Watch for 60 cycles
        monitor_fifodone(60);

        @(negedge clk); run = 1'b0;
        fifo_data_ready = 1'b0;
        repeat(3) @(posedge clk);

        // Evaluate results
        if (fd_pulse_count == 1)
            begin pass("T8 FIFODONE pulsed exactly once"); end
        else begin
            $display("[FAIL] T8 FIFODONE pulse_count=%0d (expected 1)", fd_pulse_count);
            fail_cnt = fail_cnt + 1;
        end

        if (fd_max_width == 1)
            begin pass("T9 FIFODONE pulse width = 1 cycle"); end
        else begin
            $display("[FAIL] T9 FIFODONE max pulse width=%0d cycles (expected 1)",
                      fd_max_width);
            fail_cnt = fail_cnt + 1;
        end

        // =====================================================================
        // TEST C2 — FIFODONE does NOT re-trigger in the B loop.
        //   After the first pulse the pipeline loops on B -2 forever.
        //   fifo_data_done must stay 0 for the remaining window.
        // =====================================================================
        $display("\n========================================");
        $display("TEST C2: FIFODONE does not re-trigger in loop");
        $display("========================================");

        cpu_reset();
        // Reload same program
        cpu_imem_write(9'd1, FIFODONE(1'b0));
        cpu_imem_write(9'd0, NOP(1'b0));
        cpu_imem_write(9'd2, NOP(1'b0));
        cpu_imem_write(9'd3, NOP(1'b0));
        cpu_imem_write(9'd4, B(24'hFFFFFE));

        fifo_data_ready = 1'b1;
        @(negedge clk); run = 1'b1;

        // Let FIFODONE fire once (needs ~5 cycles to reach EX)
        repeat(10) @(posedge clk);

        // Now count any further pulses over 60 more cycles
        monitor_fifodone(60);

        @(negedge clk); run = 1'b0;
        fifo_data_ready = 1'b0;
        repeat(3) @(posedge clk);

        if (fd_pulse_count == 0)
            begin pass("T10 FIFODONE silent after initial fire (B loop)"); end
        else begin
            $display("[FAIL] T10 FIFODONE retriggered %0d times in B loop",
                      fd_pulse_count);
            fail_cnt = fail_cnt + 1;
        end

        // =====================================================================
        // TEST D — FIFOWAIT then FIFODONE in sequence.
        //   FIFODONE pulse must arrive AFTER fifo_data_ready releases the stall.
        //
        // CPU IMEM:
        //   0: FIFOWAIT        stall
        //   1: NOP
        //   2: NOP
        //   3: FIFODONE        pulse after stall clears
        //   4: NOP
        //   5: NOP
        //   6: NOP
        //   7: B    -2
        //
        // Sequence:
        //   - run=1, ready=0 for 20 cycles → stall; no FIFODONE yet
        //   - ready=1 → stall clears → FIFODONE reaches EX → pulse
        // =====================================================================
        $display("\n========================================");
        $display("TEST D: FIFOWAIT then FIFODONE");
        $display("========================================");

        fifo_data_ready = 1'b0;

        cpu_reset();
        cpu_imem_write(9'd0, FIFOWAIT(1'b0));         //  0: FIFOWAIT
        cpu_imem_write(9'd1, NOP(1'b0));              //  1: NOP
        cpu_imem_write(9'd2, NOP(1'b0));              //  2: NOP
        cpu_imem_write(9'd3, FIFODONE(1'b0));         //  3: FIFODONE
        cpu_imem_write(9'd4, NOP(1'b0));              //  4: NOP
        cpu_imem_write(9'd5, NOP(1'b0));              //  5: NOP
        cpu_imem_write(9'd6, NOP(1'b0));              //  6: NOP
        cpu_imem_write(9'd7, B(24'hFFFFFE));      //  7: B -2

        @(negedge clk); run = 1'b1;
        $display("[INFO] D: run=1, ready=0");

        // Verify FIFODONE does NOT fire during stall
        begin : test_d_no_early_pulse
            integer early_pulse;
            early_pulse = 0;
            repeat(20) begin
                @(posedge clk); #1;
                if (fifo_data_done) early_pulse = early_pulse + 1;
            end
            if (early_pulse == 0)
                begin pass("T11 FIFODONE silent during FIFOWAIT stall"); end
            else begin
                $display("[FAIL] T11 FIFODONE fired %0d times before ready (expected 0)",
                          early_pulse);
                fail_cnt = fail_cnt + 1;
            end
        end

        // Release stall
        @(negedge clk); fifo_data_ready = 1'b1;
        $display("[INFO] D: fifo_data_ready=1 at t=%0t", $time);

        // Now watch for FIFODONE to fire
        monitor_fifodone(60);

        @(negedge clk); run = 1'b0;
        fifo_data_ready = 1'b0;
        repeat(3) @(posedge clk);

        if (fd_pulse_count >= 1)
            begin pass("T12 FIFODONE pulsed after stall released"); end
        else begin
            $display("[FAIL] T12 FIFODONE never pulsed after ready=1");
            fail_cnt = fail_cnt + 1;
        end

        if (fd_max_width == 1)
            begin pass("T13 FIFODONE pulse width = 1 cycle (after stall)"); end
        else begin
            $display("[FAIL] T13 FIFODONE pulse width=%0d (expected 1)",
                      fd_max_width);
            fail_cnt = fail_cnt + 1;
        end

        // =====================================================================
        // Summary
        // =====================================================================
        $display("\n========================================");
        $display("  TEST SUMMARY");
        $display("  PASS: %0d   FAIL: %0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("  *** ALL TESTS PASSED ***");
        else
            $display("  *** %0d TEST(S) FAILED ***", fail_cnt);
        $display("========================================\n");

        $finish;
    end

    // =========================================================================
    // Waveform dump
    // =========================================================================
    initial begin
        $dumpfile("tb_fifo_instrs.vcd");
        $dumpvars(0, tb_fifo_instrs);
    end

    // =========================================================================
    // Watchdog
    // =========================================================================
    initial begin
        #500_000;
        $display("[WATCHDOG] Simulation timeout at 500 us — aborting.");
        $finish;
    end

endmodule