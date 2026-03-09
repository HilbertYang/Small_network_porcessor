// cpu_gpu_top.v
// Top-level wrapper that owns the shared DMEM (D_M_64bit_256) and instantiates
// the GPU core (gpu_core3.v).
//
// Port A of the BRAM → external programming interface (dmem_prog_*)
//   back results after completion.  Mirrors the old gpu_core dmem_prog_*
//
// Port B of the BRAM → GPU pipeline
//   Connected to the dmem_addr/en/we/din/dout ports of gpu_core.
//   Reserved for a future CPU data-path connection.

`timescale 1ns/1ps
module cpu_gpu_top (
    input  wire        clk,
    input  wire        reset,

    // Run / step / halt
    input  wire        run,
    input  wire        step,
    input  wire        pc_reset,
    output wire        done,

    // Param register programming
    input  wire        param_wr_en,
    input  wire [2:0]  param_wr_addr,
    input  wire [63:0] param_wr_data,

    // Instruction memory programming
    input  wire        imem_prog_we,
    input  wire [8:0]  imem_prog_addr,
    input  wire [31:0] imem_prog_wdata,

    // Data memory programming (Port A — host / future CPU)
    input  wire        dmem_prog_en,
    input  wire        dmem_prog_we,
    input  wire [7:0]  dmem_prog_addr,
    input  wire [63:0] dmem_prog_wdata,
    output wire [63:0] dmem_prog_rdata,

    // Debug outputs
    output wire [8:0]  pc_dbg,
    output wire [31:0] if_instr_dbg
);

    // -----------------------------------------------------------------------
    // Internal wires: GPU core ↔ DMEM Port B
    // -----------------------------------------------------------------------
    wire [7:0]  gpu_dmem_addr;
    wire        gpu_dmem_en;
    wire        gpu_dmem_we;
    wire [63:0] gpu_dmem_din;
    wire [63:0] gpu_dmem_dout;

    // -----------------------------------------------------------------------
    // GPU core
    // -----------------------------------------------------------------------
    gpu_core u_gpu_core (
        .clk            (clk),
        .reset          (reset),
        .run            (run),
        .step           (step),
        .pc_reset       (pc_reset),
        .done           (done),
        .param_wr_en    (param_wr_en),
        .param_wr_addr  (param_wr_addr),
        .param_wr_data  (param_wr_data),
        .imem_prog_we   (imem_prog_we),
        .imem_prog_addr (imem_prog_addr),
        .imem_prog_wdata(imem_prog_wdata),
        // External DMEM port (Port B)
        .dmem_addr      (gpu_dmem_addr),
        .dmem_en        (gpu_dmem_en),
        .dmem_we        (gpu_dmem_we),
        .dmem_din       (gpu_dmem_din),
        .dmem_dout      (gpu_dmem_dout),
        .pc_dbg         (pc_dbg),
        .if_instr_dbg   (if_instr_dbg)
    );


    cpu_mt cpu_mt_mt (
        
        .clk            (clk),
        .reset          (reset),
        .run            (run),
        .step           (step),
        .pc_reset_pulse (pc_reset_pulse),
        .imem_prog_we   (imem_prog_we),
        .imem_prog_addr (imem_prog_addr),
        .imem_prog_wdata(imem_prog_wdata),
	 
	    .cpu_dmem_addr(cpu_dmem_addr),
        .cpu_dmem_en(cpu_dmem_en),
        .cpu_dmem_wen(cpu_dmem_wen),
        .cpu_dmem_data_wr(cpu_dmem_data_wr),
        .cpu_dmem_data_rd(cpu_dmem_data_rd),
	 
        .pc_dbg         (pc_dbg),
        .if_instr_dbg   (if_instr_dbg),
	 
	    .gpu_run(gpu_run),
	    .gpu_done(gpu_done),
  
	    .gpu_mem_access(gpu_mem_access),
  
		.fifo_start_offset(fifo_start_offset),
		.fifo_end_offset(fifo_end_offset),
		.fifo_data_ready(fifo_data_ready)
  
  );

    
    // -----------------------------------------------------------------------
    // Shared Data Memory
    //   Port A → host programming
    //   Port B → GPU pipeline / Future CPU(shared)
    // -----------------------------------------------------------------------

    wire [63:0] portb_doutb, portb_din;
    wire [7:0] portb_addr;
    wire portb_en, portb_we;
    
    assign portb_addr = gpu_mem_access ? gpu_dmem_addr : cpu_dmem_addr ;
    assign portb_din = gpu_mem_access ? gpu_dmem_din : cpu_dmem_data_wr;
    assign gpu_dmem_dout = portb_doutb;
    assign cpu_dmem_data_rd = portb_doutb;
    assign portb_en = gpu_mem_access ? gpu_dmem_en : cpu_dmem_en;
    assign portb_we = gpu_mem_access ? gpu_dmem_we : cpu_dmem_wen;
    
    D_M_64bit_256 u_dmem (
        // Port A: programming
        .addra(dmem_prog_addr),
        .clka (clk),
        .ena  (dmem_prog_en),
        .wea  (dmem_prog_we),
        .dina (dmem_prog_wdata),
        .douta(dmem_prog_rdata),

        // Port B: GPU pipeline / Future CPU (shared)
        .addrb(portb_addr),
        .clkb (clk),
        .enb  (portb_en),
        .web  (portb_we),
        .dinb (portb_din),
        .doutb(portb_doutb)
    );

endmodule

