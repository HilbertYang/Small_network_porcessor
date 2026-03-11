`timescale 1ns/1ps
// =============================================================================
// tb_cpu_gpu.v  ?  Testbench for cpu_mt
//
// Tests:
//   TEST 1 ? WRP: write CPU register to GPU param regs (addr 0-7)
//     Program:
//       addr 0: MOV R3, #0xAB        ? R0 = 0xAB
//       addr 1: MOV R1, #0xCD        ? R1 = 0xCD
//       addr 2: MOV R2, #0x12        ? R2 = 0x12
//       addr 3: NOP  (pipeline fill)
//       addr 4: NOP
//       addr 5: WRP R3, #0           ? gpu_param_data=0xAB, gpu_param_addr=0, wen=1
//       addr 6: NOP
//       addr 7: NOP
//       addr 8: WRP R1, #3           ? gpu_param_data=0xCD, gpu_param_addr=3, wen=1
//       addr 9: NOP
//       addr10: NOP
//       addr11: WRP R2, #7           ? gpu_param_data=0x12, gpu_param_addr=7, wen=1
//       addr12: NOP
//       addr13: NOP
//       addr14: NOP
//
//   TEST 2 ? GPU_RUN: CPU stalls until gpu_done is asserted
//     Program:
//       addr 0: MOV R4, #0x55        ? R4 = 0x55
//       addr 1: NOP
//       addr 2: NOP
//       addr 3: NOP  (fill pipeline so MOV reaches EX)
//       addr 4: GPU_RUN              ? cpu stalls, gpu_run goes high
//       addr 5: NOP  (executed after gpu_done)
//       addr 6: NOP
//
// Instruction encodings used:
//   MOV Rd,#imm8  : {4'hE, 2'b00, 1'b1, 4'b1101, 1'b0, 4'b0000, Rd[3:0], 8'b0, imm8}
//                   cond[31:28]=E  op[27:26]=00  I[25]=1  opc[24:21]=1101
//                   S[20]=0  Rn[19:16]=0000  Rd[15:12]=Rd  rot[11:8]=0000  imm8[7:0]
//   NOP           : 32'hE000_0000
//   WRP Rs,#imm3  : {8'hAE, 4'b0000, Rs[3:0], 17'b0, imm3[2:0]}
//                   inst[31:24]=AE  inst[23:20]=Rs  inst[19:3]=0  inst[2:0]=imm3
//   GPU_RUN       : {8'hAD, 24'h000000}   (inst[31:24]=8'b10101101)
// =============================================================================

module tb_cpu_gpu_param;

// ---------------------------------------------------------------------------
// Clock & reset
// ---------------------------------------------------------------------------
reg clk, reset, run, step, pc_reset_pulse;

initial clk = 0;
always #5 clk = ~clk;   // 100 MHz

// ---------------------------------------------------------------------------
// CPU I/O
// ---------------------------------------------------------------------------
reg         imem_prog_we;
reg  [8:0]  imem_prog_addr;
reg  [31:0] imem_prog_wdata;

wire [7:0]  cpu_dmem_addr;
wire        cpu_dmem_en;
wire        cpu_dmem_wen;
wire [63:0] cpu_dmem_data_wr;
reg  [63:0] cpu_dmem_data_rd;

wire [8:0]  pc_dbg;
wire [31:0] if_instr_dbg;

wire        gpu_run;
reg         gpu_done;

wire        gpu_mem_access;

reg  [7:0]  fifo_start_offset;
reg  [7:0]  fifo_end_offset;
reg         fifo_data_ready;
wire        fifo_data_done;

wire        gpu_param_wen;
wire [63:0] gpu_param_data;
wire [2:0]  gpu_param_addr;

// ---------------------------------------------------------------------------
// DUT
// ---------------------------------------------------------------------------
cpu_mt dut (
    .clk               (clk),
    .reset             (reset),
    .run               (run),
    .step              (step),
    .pc_reset_pulse    (pc_reset_pulse),
    .imem_prog_we      (imem_prog_we),
    .imem_prog_addr    (imem_prog_addr),
    .imem_prog_wdata   (imem_prog_wdata),
    .cpu_dmem_addr     (cpu_dmem_addr),
    .cpu_dmem_en       (cpu_dmem_en),
    .cpu_dmem_wen      (cpu_dmem_wen),
    .cpu_dmem_data_wr  (cpu_dmem_data_wr),
    .cpu_dmem_data_rd  (cpu_dmem_data_rd),
    .pc_dbg            (pc_dbg),
    .if_instr_dbg      (if_instr_dbg),
    .gpu_run           (gpu_run),
    .gpu_done          (gpu_done),
    .gpu_mem_access    (gpu_mem_access),
    .fifo_start_offset (fifo_start_offset),
    .fifo_end_offset   (fifo_end_offset),
    .fifo_data_ready   (fifo_data_ready),
    .fifo_data_done    (fifo_data_done),
    .gpu_param_wr_en     (gpu_param_wen),
    .gpu_param_wr_data    (gpu_param_data),
    .gpu_param_wr_addr    (gpu_param_addr)
);

// ---------------------------------------------------------------------------
// Simple GPU param register file model (64-bit × 8)
// Used to verify WRP writes land correctly
// ---------------------------------------------------------------------------
reg [63:0] gpu_param_regfile [0:7];
integer pi;
initial begin
    for (pi = 0; pi < 8; pi = pi + 1)
        gpu_param_regfile[pi] = 64'hDEAD_BEEF_DEAD_BEEF;
end

always @(posedge clk) begin
    if (gpu_param_wen)
        gpu_param_regfile[gpu_param_addr] <= gpu_param_data;
end

// ---------------------------------------------------------------------------
// Instruction encoding helpers
// ---------------------------------------------------------------------------
// MOV Rd, #imm8  :  cond=E op=00 I=1 opcode=1101 S=0 Rn=0000 Rd imm8
function [31:0] encode_MOV;
    input [3:0] Rd;
    input [7:0] imm8;
    encode_MOV = {4'hE, 2'b00, 1'b1, 4'b1101, 1'b0, 4'b0000, Rd, 4'b0000, imm8};
endfunction

// NOP : AND R0,R0,R0
localparam NOP = 32'hE000_0000;

// WRP Rs, #imm3 :  inst[31:24]=AE  inst[23:20]=Rs  inst[19:3]=0  inst[2:0]=imm3
function [31:0] encode_WRP;
    input [3:0] Rs;
    input [2:0] imm3;
    encode_WRP = {8'hAE, Rs, 17'b0, imm3};
endfunction

// GPU_RUN : inst[31:24]=AD
localparam GPU_RUN_INST = 32'hAD000000;

// ---------------------------------------------------------------------------
// Task: load a single instruction word into IMEM
// ---------------------------------------------------------------------------
task load_instr;
    input [8:0]  addr;
    input [31:0] instr;
    begin
        @(negedge clk);
        imem_prog_we    = 1'b1;
        imem_prog_addr  = addr;
        imem_prog_wdata = instr;
        @(negedge clk);
        imem_prog_we    = 1'b0;
    end
endtask

// ---------------------------------------------------------------------------
// Task: reset the CPU and hold for N cycles
// ---------------------------------------------------------------------------
task do_reset;
    input integer n;
    integer i;
    begin
        reset          = 1'b1;
        pc_reset_pulse = 1'b0;
        run            = 1'b0;
        step           = 1'b0;
        gpu_done       = 1'b0;
        imem_prog_we   = 1'b0;
        repeat (n) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
    end
endtask

// ---------------------------------------------------------------------------
// Task: pulse pc_reset so the PC goes back to 0 without full reset
// ---------------------------------------------------------------------------
task pc_reset;
    begin
        @(negedge clk);
        pc_reset_pulse = 1'b1;
        @(negedge clk);
        pc_reset_pulse = 1'b0;
    end
endtask

// ---------------------------------------------------------------------------
// Pass / fail tracking
// ---------------------------------------------------------------------------
integer pass_cnt, fail_cnt;

task check;
    input        cond;
    input [255:0] msg;
    begin
        if (cond) begin
            $display("  PASS: %s", msg);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: %s", msg);
            fail_cnt = fail_cnt + 1;
        end
    end
endtask

// ---------------------------------------------------------------------------
// Waveform dump
// ---------------------------------------------------------------------------
initial begin
    $dumpfile("tb_cpu_gpu_param.vcd");
    $dumpvars(0, tb_cpu_gpu_param);
end

// ---------------------------------------------------------------------------
// Stimulus
// ---------------------------------------------------------------------------
integer cyc;

initial begin
    pass_cnt = 0;
    fail_cnt = 0;

    // Default tie-offs
    cpu_dmem_data_rd  = 64'h0;
    fifo_start_offset = 8'h0;
    fifo_end_offset   = 8'h0;
    fifo_data_ready   = 1'b0;
    step              = 1'b0;

    // =========================================================================
    // TEST 1 ? WRP: Write CPU registers to GPU param regs
    // =========================================================================
    $display("\n========================================");
    $display(" TEST 1: WRP instruction");
    $display("========================================");

    do_reset(4);

    // --- Program IMEM (CPU is held in reset / not running) ---
    //  addr 0 : MOV R3, #0xAB
    //  addr 1 : MOV R1, #0xCD
    //  addr 2 : MOV R2, #0x12
    //  addr 3 : NOP  (3 NOPs so MOVs fully retire before WRP enters ID)
    //  addr 4 : NOP
    //  addr 5 : NOP
    //  addr 6 : WRP R3, #0
    //  addr 7 : NOP
    //  addr 8 : NOP
    //  addr 9 : WRP R1, #3
    //  addr10 : NOP
    //  addr11 : NOP
    //  addr12 : WRP R2, #7
    //  addr13 : NOP  (tail NOPs to drain WRP through pipeline)
    //  addr14 : NOP
    //  addr15 : NOP
    load_instr(9'd0,  encode_MOV(4'd3, 8'hAB));
    load_instr(9'd1,  encode_MOV(4'd1, 8'hCD));
    load_instr(9'd2,  encode_MOV(4'd2, 8'h12));
    load_instr(9'd3,  NOP);
    load_instr(9'd4,  NOP);
    load_instr(9'd5,  NOP);
    load_instr(9'd6,  encode_WRP(4'd3, 3'd0));   // WRP R3, #0
    load_instr(9'd7,  NOP);
    load_instr(9'd8,  NOP);
    load_instr(9'd9,  encode_WRP(4'd1, 3'd3));   // WRP R1, #3
    load_instr(9'd10, NOP);
    load_instr(9'd11, NOP);
    load_instr(9'd12, encode_WRP(4'd2, 3'd7));   // WRP R2, #7
    load_instr(9'd13, NOP);
    load_instr(9'd14, NOP);
    load_instr(9'd15, NOP);

    $display("\n  Instruction encodings:");
    $display("    MOV R0,#0xAB  = %08h", encode_MOV(4'd0, 8'hAB));
    $display("    MOV R1,#0xCD  = %08h", encode_MOV(4'd1, 8'hCD));
    $display("    MOV R2,#0x12  = %08h", encode_MOV(4'd2, 8'h12));
    $display("    WRP R0,#0     = %08h", encode_WRP(4'd0, 3'd0));
    $display("    WRP R1,#3     = %08h", encode_WRP(4'd1, 3'd3));
    $display("    WRP R2,#7     = %08h", encode_WRP(4'd2, 3'd7));

    // Run CPU
    @(negedge clk);
    run = 1'b1;

    // --- Monitor gpu_param_wen pulses ---
    // We run for enough cycles to let all three WRP instructions reach EX
    // Pipeline depth is 4 stages (IF?ID?EX), so WRP at addr6 reaches EX ~6+4=10 clocks after start.
    // Run 30 cycles to be safe, watching for the 3 expected WRP pulses.

    $display("\n  Cycle-by-cycle WRP output monitoring:");
    $display("  %6s  %4s  %12s  %4s  %4s", "Cycle", "PC", "INSTR", "WEN", "ADDR");

    begin : wrp_monitor
        integer wrp_seen;
        reg [63:0] wrp_data_log [0:2];
        reg [2:0]  wrp_addr_log [0:2];
        wrp_seen = 0;

        repeat (60) begin
            @(posedge clk);
            #1; // sample just after rising edge
            $display("  %6t  %4d  %08h    %b    %d",
                     $time, pc_dbg, if_instr_dbg, gpu_param_wen, gpu_param_addr);
            if (gpu_param_wen) begin
                wrp_data_log[wrp_seen] = gpu_param_data;
                wrp_addr_log[wrp_seen] = gpu_param_addr;
                wrp_seen = wrp_seen + 1;
            end
        end

        $display("\n  WRP pulses captured: %0d (expected 3)", wrp_seen);
        check(wrp_seen == 3, "WRP: exactly 3 write pulses seen");

        if (wrp_seen >= 1) begin
            $display("  WRP[0]: addr=%0d data=0x%016h (expect addr=0 data=0xAB)",
                     wrp_addr_log[0], wrp_data_log[0]);
            check(wrp_addr_log[0] == 3'd0,  "WRP[0]: gpu_param_addr == 0");
            check(wrp_data_log[0] == 64'hAB,"WRP[0]: gpu_param_data == 0xAB");
        end
        if (wrp_seen >= 2) begin
            $display("  WRP[1]: addr=%0d data=0x%016h (expect addr=3 data=0xCD)",
                     wrp_addr_log[1], wrp_data_log[1]);
            check(wrp_addr_log[1] == 3'd3,  "WRP[1]: gpu_param_addr == 3");
            check(wrp_data_log[1] == 64'hCD,"WRP[1]: gpu_param_data == 0xCD");
        end
        if (wrp_seen >= 3) begin
            $display("  WRP[2]: addr=%0d data=0x%016h (expect addr=7 data=0x12)",
                     wrp_addr_log[2], wrp_data_log[2]);
            check(wrp_addr_log[2] == 3'd7,  "WRP[2]: gpu_param_addr == 7");
            check(wrp_data_log[2] == 64'h12,"WRP[2]: gpu_param_data == 0x12");
        end
    end

    // Verify gpu_param register file model
    $display("\n  GPU param regfile after WRP writes:");
    $display("    [0] = 0x%016h  (expect 0x00000000000000AB)", gpu_param_regfile[0]);
    $display("    [3] = 0x%016h  (expect 0x00000000000000CD)", gpu_param_regfile[3]);
    $display("    [7] = 0x%016h  (expect 0x0000000000000012)", gpu_param_regfile[7]);
    check(gpu_param_regfile[0] == 64'hAB, "Param regfile[0] == 0xAB");
    check(gpu_param_regfile[3] == 64'hCD, "Param regfile[3] == 0xCD");
    check(gpu_param_regfile[7] == 64'h12, "Param regfile[7] == 0x12");

    // WRP must NOT write to unrelated param regs
    check(gpu_param_regfile[1] === 64'hDEAD_BEEF_DEAD_BEEF, "Param regfile[1] untouched");
    check(gpu_param_regfile[5] === 64'hDEAD_BEEF_DEAD_BEEF, "Param regfile[5] untouched");

    run = 1'b0;

    // =========================================================================
    // TEST 2 ? GPU_RUN: CPU stalls and gpu_run asserted until gpu_done
    // =========================================================================
    $display("\n========================================");
    $display(" TEST 2: GPU_RUN stall / handshake");
    $display("========================================");

    // Reset and reload IMEM with GPU_RUN test program
    do_reset(4);
    pc_reset;

    //  addr 0: NOP  (pipeline flush padding after pc_reset)
    //  addr 1: NOP
    //  addr 2: NOP
    //  addr 3: GPU_RUN
    //  addr 4: NOP  (should only execute after gpu_done)
    //  addr 5: NOP
    //  addr 6: NOP
    load_instr(9'd0, NOP);
    load_instr(9'd1, NOP);
    load_instr(9'd2, NOP);
    load_instr(9'd3, GPU_RUN_INST);
    load_instr(9'd4, NOP);
    load_instr(9'd5, NOP);
    load_instr(9'd6, NOP);

    $display("\n  GPU_RUN encoding = %08h", GPU_RUN_INST);

    @(negedge clk);
    run = 1'b1;

    // --- Wait for gpu_run to go high ---
    $display("\n  Waiting for gpu_run to assert...");
    cyc = 0;
    while (!gpu_run && cyc < 50) begin
        @(posedge clk); #1;
        cyc = cyc + 1;
    end

    if (gpu_run) begin
        $display("  gpu_run asserted at cycle %0d after run=1", cyc);
        check(1'b1, "GPU_RUN: gpu_run asserted");
    end else begin
        $display("  ERROR: gpu_run never asserted within 50 cycles!");
        check(1'b0, "GPU_RUN: gpu_run asserted");
    end

    // --- While stalled, confirm advance is 0 (CPU is frozen) ---
    // Sample for a few cycles and make sure PC does not advance
    begin : stall_check
        reg [8:0] pc_snap1, pc_snap2;
        @(posedge clk); #1; pc_snap1 = pc_dbg;
        @(posedge clk); #1; pc_snap2 = pc_dbg;
        $display("  PC snapshot during stall: %0d -> %0d (should be equal)", pc_snap1, pc_snap2);
        check(pc_snap1 == pc_snap2, "GPU_RUN: CPU PC frozen while gpu_run=1");
    end

    check(gpu_run == 1'b1, "GPU_RUN: gpu_run still high before gpu_done");

    // --- Assert gpu_done after a few cycles (simulate GPU finishing) ---
    $display("\n  Asserting gpu_done after 5 GPU 'work' cycles...");
    repeat (5) @(posedge clk);
    @(negedge clk);
    gpu_done = 1'b1;
    @(negedge clk);
    gpu_done = 1'b0;

    // --- Wait for gpu_run to deassert ---
    @(posedge clk); #1;
    begin : done_check
        integer wait_cyc;
        wait_cyc = 0;
        while (gpu_run && wait_cyc < 10) begin
            @(posedge clk); #1;
            wait_cyc = wait_cyc + 1;
        end
        $display("  gpu_run deasserted %0d cycle(s) after gpu_done", wait_cyc);
        check(!gpu_run, "GPU_RUN: gpu_run deasserts after gpu_done");
    end

    // --- CPU should resume: PC should be incrementing again ---
    $display("\n  Checking CPU resumes after gpu_done...");
    begin : resume_check
        reg [8:0] pc_before, pc_after;
        @(posedge clk); #1; pc_before = pc_dbg;
        repeat (3) @(posedge clk);
        #1; pc_after = pc_dbg;
        $display("  PC before resume check: %0d,  after 3 cycles: %0d", pc_before, pc_after);
        check(pc_after > pc_before, "GPU_RUN: CPU resumes (PC increments after stall)");
    end

    // --- Confirm no spurious gpu_param_wen during GPU_RUN test ---
    // (gpu_param_wen should have been 0 throughout this test)
    $display("\n  Confirming no spurious WRP pulses during GPU_RUN test...");
    // We just sample for a few cycles; since the program has no WRP, wen must stay low.
    begin : no_wrp_check
        integer spurious;
        spurious = 0;
        repeat (10) begin
            @(posedge clk); #1;
            if (gpu_param_wen) spurious = spurious + 1;
        end
        check(spurious == 0, "GPU_RUN test: no spurious gpu_param_wen");
    end

    run = 1'b0;

    // =========================================================================
    // TEST 3 ? WRP followed immediately by GPU_RUN (combined scenario)
    // =========================================================================
    $display("\n========================================");
    $display(" TEST 3: WRP then GPU_RUN combined");
    $display("========================================");

    do_reset(4);
    pc_reset;

    // Reinitialise param regfile model for clean check
    for (pi = 0; pi < 8; pi = pi + 1)
        gpu_param_regfile[pi] = 64'hDEAD_BEEF_DEAD_BEEF;

    //  addr 0: MOV R5, #0x77
    //  addr 1: NOP
    //  addr 2: NOP
    //  addr 3: NOP   (ensure MOV reaches WB before WRP enters EX)
    //  addr 4: WRP R5, #2
    //  addr 5: NOP
    //  addr 6: NOP
    //  addr 7: GPU_RUN
    //  addr 8: NOP
    //  addr 9: NOP
    load_instr(9'd0, encode_MOV(4'd5, 8'h77));
    load_instr(9'd1, NOP);
    load_instr(9'd2, NOP);
    load_instr(9'd3, NOP);
    load_instr(9'd4, encode_WRP(4'd5, 3'd2));
    load_instr(9'd5, NOP);
    load_instr(9'd6, NOP);
    load_instr(9'd7, GPU_RUN_INST);
    load_instr(9'd8, NOP);
    load_instr(9'd9, NOP);

    @(negedge clk);
    run = 1'b1;

    // Capture WRP pulse
    begin : combined_wrp
        integer wrp_ok;
        reg [63:0] cap_data;
        reg [2:0]  cap_addr;
        wrp_ok = 0;
        repeat (25) begin
            @(posedge clk); #1;
            if (gpu_param_wen && !wrp_ok) begin
                cap_data = gpu_param_data;
                cap_addr = gpu_param_addr;
                wrp_ok = 1;
            end
        end
        $display("\n  Combined WRP: addr=%0d data=0x%016h (expect addr=2 data=0x77)",
                 cap_addr, cap_data);
        check(wrp_ok == 1,          "Combined: WRP pulse seen");
        check(cap_addr == 3'd2,     "Combined: gpu_param_addr == 2");
        check(cap_data == 64'h77,   "Combined: gpu_param_data == 0x77");
    end

    // Now wait for gpu_run
    cyc = 0;
    while (!gpu_run && cyc < 50) begin
        @(posedge clk); #1;
        cyc = cyc + 1;
    end
    $display("  Combined: gpu_run asserted at cycle %0d", cyc);
    check(gpu_run, "Combined: gpu_run asserts after WRP");

    // Release GPU
    repeat (3) @(posedge clk);
    @(negedge clk); gpu_done = 1'b1;
    @(negedge clk); gpu_done = 1'b0;

    @(posedge clk); #1;
    begin : combined_done
        integer w;
        w = 0;
        while (gpu_run && w < 10) begin @(posedge clk); #1; w = w + 1; end
        check(!gpu_run, "Combined: gpu_run deasserts after gpu_done");
    end

    run = 1'b0;

    // =========================================================================
    // Summary
    // =========================================================================
    $display("\n========================================");
    $display(" RESULTS:  %0d passed,  %0d failed", pass_cnt, fail_cnt);
    $display("========================================\n");

    if (fail_cnt == 0)
        $display("ALL TESTS PASSED\n");
    else
        $display("SOME TESTS FAILED ? review output above\n");

    $finish;
end

// ---------------------------------------------------------------------------
// Timeout watchdog
// ---------------------------------------------------------------------------
initial begin
    #50000;
    $display("WATCHDOG TIMEOUT ? simulation exceeded 50us");
    $finish;
end

endmodule
