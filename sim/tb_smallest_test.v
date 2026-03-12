
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
    // Run pipeline until done pulses (or timeout)
    // =========================================================================
    task run_until_done;
        input integer timeout_cycles;
        integer cnt;
        begin
            cnt = 0;
            @(negedge clk); run = 1'b1;
            @(posedge clk); #1;
            while (!done && cnt < timeout_cycles) begin
                @(posedge clk); #1;
                cnt = cnt + 1;
            end
            if (done)
                $display("[INFO] done after %0d cycles", cnt);
            else
                $display("[FAIL] timeout (%0d cycles)", timeout_cycles);
            @(negedge clk); run = 1'b0;
            repeat(4) @(posedge clk);  // drain pipeline
            $stop;
        end
    endtask

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
    function [31:0] cpu_mov;
        input [3:0]  rd;
        input [7:0]  imm8;
		begin cpu_mov = {4'hE, 3'b001, 4'b1101, 1'b0, 4'h0, rd, 4'h0, imm8}; end
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

    // B off24   {4'hE, 8'hEA, off24}   ? off24 is signed offset from PC+2
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
        //  Program GPU IMEM (imem_sel = 0)
        // =====================================================================

        $display("\n=== PHASE 1: Program GPU IMEM ===");
        imem_sel = 1'b0;  // GPU IMEM

        // imem_write(9'd0,    gpu_ld_param(4'd1, 3'd1));            // R1 = param[1] #0
        // imem_write(9'd1,    gpu_ld_param(4'd2, 3'd2));            // R2 = param[2] #10
        // imem_write(9'd2,    gpu_ld_param(4'd3, 3'd3));            // R3 = param[3] #20
        // imem_write(9'd3,    gpu_mov(4'd4, 15'd15));               // R4 = 11  (limit)  #4(times) * 4(num_lanes) - 1 =15
        // imem_write(9'd4,    gpu_mov(4'd5, 15'd0));                // R5 = Counter

        // imem_write(9'd5,    gpu_nop(1'b0));                      
        // imem_write(9'd6,    gpu_nop(1'b0));

        // imem_write(9'd7,    gpu_setp_ge(4'd5, 4'd4));
        // imem_write(9'd8,    gpu_bpr(9'd18)); 
        // imem_write(9'd9,    gpu_ld64 (4'd10, 4'd1, 15'd0));
        // imem_write(9'd10,   gpu_ld64 (4'd11, 4'd2, 15'd0));
        // imem_write(9'd11,   gpu_addi64(4'd1, 4'd1, 15'd1));
        // imem_write(9'd12,   gpu_addi64(4'd2, 4'd2, 15'd1));
        // imem_write(9'd13,   gpu_add_i16(4'd12, 4'd10, 4'd11));
        // imem_write(9'd14,   gpu_br(9'd7));
        // imem_write(9'd15,   gpu_addi64(4'd5, 4'd5, 15'd4));
        // imem_write(9'd16,   gpu_st64 (4'd12, 4'd3, 15'd0));
        // imem_write(9'd17,   gpu_addi64(4'd3, 4'd3, 15'd1));
        
        // imem_write(9'd18,   gpu_ret(1'b0));
        // imem_write(9'd19,   gpu_nop(1'b0));

        
        imem_write(9'd1,    gpu_mov(4'd5, 15'd0)); 
        imem_write(9'd2,    gpu_nop(1'b0));
        imem_write(9'd3,    gpu_nop(1'b0));
        imem_write(9'd4 ,   gpu_st64 (4'd5, 4'd0, 15'd1));
        imem_write(9'd5,    gpu_nop(1'b0));
        imem_write(9'd6,    gpu_nop(1'b0));
        imem_write(9'd7 ,   gpu_ret(1'b0));
        imem_write(9'd8,    gpu_nop(1'b0));


        repeat(2) @(posedge clk);
        $display("[INFO] GPU IMEM programmed (20 instructions).");

        // =====================================================================
        // Program CPU IMEM (imem_sel = 1)
        // =====================================================================

        $display("\n=== PHASE 2: Program CPU IMEM ===");
        imem_sel = 1'b1;  // CPU IMEM

        imem_write(9'd0,  cpu_nop(1'b0));
        imem_write(9'd1,  cpu_mov(4'd3, 8'd0));         // MOV R3, #0
        imem_write(9'd2,  cpu_wrp(4'd3, 3'd1));         // WRP R3, #1  param[1]=0
        imem_write(9'd3,  cpu_mov(4'd4, 8'd10));        // MOV R4, #10
        imem_write(9'd4,  cpu_wrp(4'd4, 3'd2));         // WRP R4, #2  param[2]=10
        imem_write(9'd5,  cpu_mov(4'd5, 8'd20));        // MOV R5, #14
        imem_write(9'd6,  cpu_wrp(4'd5, 3'd3));         // WRP R5, #3  param[3]=14
        imem_write(9'd7,  cpu_nop(1'b0));
        imem_write(9'd8,  cpu_gpurun(1'b0));            // GPURUN
        imem_write(9'd9,  cpu_nop(1'b0));
        imem_write(9'd10, cpu_nop(1'b0));
        imem_write(9'd11, cpu_b(24'hFFFFFE));           // B -2  (loop forever)
		  
        imem_write(9'd128, cpu_nop(1'b0));
        imem_write(9'd129, cpu_nop(1'b0));
        imem_write(9'd130, cpu_nop(1'b0));
        imem_write(9'd131, cpu_nop(1'b0));
        imem_write(9'd132, cpu_nop(1'b0));
        imem_write(9'd133, cpu_nop(1'b0));
        imem_write(9'd134, cpu_nop(1'b0));
        imem_write(9'd135, cpu_nop(1'b0));
        imem_write(9'd136, cpu_nop(1'b0));
        imem_write(9'd137, cpu_nop(1'b0));
        imem_write(9'd138, cpu_nop(1'b0));
        imem_write(9'd139, cpu_nop(1'b0));
        imem_write(9'd140, cpu_nop(1'b0));
        imem_write(9'd141, cpu_nop(1'b0));
        imem_write(9'd142, cpu_nop(1'b0));
        imem_write(9'd143, cpu_nop(1'b0));
        imem_write(9'd144, cpu_nop(1'b0));
        imem_write(9'd145, cpu_nop(1'b0));
        imem_write(9'd146, cpu_nop(1'b0));
        imem_write(9'd147, cpu_nop(1'b0));
        imem_write(9'd148, cpu_nop(1'b0));
        imem_write(9'd149, cpu_nop(1'b0));


        imem_write(9'd256, cpu_nop(1'b0));
        imem_write(9'd257, cpu_nop(1'b0));
        imem_write(9'd258, cpu_nop(1'b0));
        imem_write(9'd259, cpu_nop(1'b0));
        imem_write(9'd260, cpu_nop(1'b0));
        imem_write(9'd261, cpu_nop(1'b0));
        imem_write(9'd262, cpu_nop(1'b0));
        imem_write(9'd263, cpu_nop(1'b0));
        imem_write(9'd264, cpu_nop(1'b0));
        imem_write(9'd265, cpu_nop(1'b0));
        imem_write(9'd266, cpu_nop(1'b0));
        imem_write(9'd267, cpu_nop(1'b0));
        imem_write(9'd268, cpu_nop(1'b0));
        imem_write(9'd269, cpu_nop(1'b0));
        imem_write(9'd270, cpu_nop(1'b0));
        imem_write(9'd271, cpu_nop(1'b0));
        imem_write(9'd272, cpu_nop(1'b0));
        imem_write(9'd273, cpu_nop(1'b0));
        imem_write(9'd274, cpu_nop(1'b0));
        imem_write(9'd275, cpu_nop(1'b0));


        imem_write(9'd384, cpu_nop(1'b0));
        imem_write(9'd385, cpu_nop(1'b0));
        imem_write(9'd386, cpu_nop(1'b0));
        imem_write(9'd387, cpu_nop(1'b0));
        imem_write(9'd388, cpu_nop(1'b0));
        imem_write(9'd389, cpu_nop(1'b0));
        imem_write(9'd390, cpu_nop(1'b0));
        imem_write(9'd391, cpu_nop(1'b0));
        imem_write(9'd392, cpu_nop(1'b0));
        imem_write(9'd393, cpu_nop(1'b0));
        imem_write(9'd394, cpu_nop(1'b0));
        imem_write(9'd395, cpu_nop(1'b0));
        imem_write(9'd396, cpu_nop(1'b0));
        imem_write(9'd397, cpu_nop(1'b0));
        imem_write(9'd398, cpu_nop(1'b0));
        imem_write(9'd399, cpu_nop(1'b0));
        imem_write(9'd400, cpu_nop(1'b0));
        imem_write(9'd401, cpu_nop(1'b0));
        imem_write(9'd402, cpu_nop(1'b0));
        imem_write(9'd403, cpu_nop(1'b0));
		  

        repeat(2) @(posedge clk);
        $display("[INFO] CPU IMEM programmed (31 words).");

        // =====================================================================
        //  Initialise DMEM via Port-A
        // =====================================================================
        $display("\n=== PHASE 3: Initialise DMEM ===");

        dmem_write(8'd10, 64'h0001_0002_0003_0004);
        dmem_write(8'd11, 64'h0005_0006_0007_0008);
        dmem_write(8'd12, 64'h0009_000A_000B_000C);
        dmem_write(8'd13, 64'h000D_000E_000F_0010);

        dmem_write(8'd0, 64'h0001_0001_0001_0001);
        dmem_write(8'd1, 64'h0001_0001_0001_0001);
        dmem_write(8'd2, 64'h0001_0001_0001_0001);
        dmem_write(8'd3, 64'h0001_0001_0001_0001);

        // Clear output region
        dmem_write(8'd20, 64'h0);
        dmem_write(8'd21, 64'h0);
        dmem_write(8'd22, 64'h0);
        dmem_write(8'd23, 64'h0);

        repeat(2) @(posedge clk);
        $display("[INFO] DMEM initialised.");
        $stop;

        // =====================================================================
        // run
        // =====================================================================
		  
        $display("\n=== PHASE 4: Run CPU+GPU system ===");
        
        run_until_done(300);

        // =====================================================================
        //  Read back DMEM output and verify
        // =====================================================================
        $display("\n=== PHASE 5: Verify DMEM output after GPU kernel ===");

        dmem_read_check(8'd0, 64'h0002_0003_0004_0005, 1);
        dmem_read_check(8'd1, 64'h0006_0007_0008_0009, 2);
        dmem_read_check(8'd2, 64'h000A_000B_000C_000D, 3);
        dmem_read_check(8'd3, 64'h000E_000F_0010_0011, 4);

        dmem_read_check(8'd10, 64'h0002_0003_0004_0005, 1);
        dmem_read_check(8'd11, 64'h0002_0003_0004_0005, 1);
        dmem_read_check(8'd12, 64'h0002_0003_0004_0005, 1);
        dmem_read_check(8'd13, 64'h0002_0003_0004_0005, 1);
        
        dmem_read_check(8'd20, 64'h0002_0003_0004_0005, 1);
        dmem_read_check(8'd21, 64'h0006_0007_0008_0009, 2);
        dmem_read_check(8'd22, 64'h000A_000B_000C_000D, 3);
        dmem_read_check(8'd23, 64'h000E_000F_0010_0011, 4);

        $finish;
    end

endmodule
