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

    // -----------------------------------------------------------------------
    // Shared Data Memory
    //   Port A → host programming
    //   Port B → GPU pipeline / Future CPU(shared)
    // -----------------------------------------------------------------------
    D_M_64bit_256 u_dmem (
        // Port A: programming
        .addra(dmem_prog_addr),
        .clka (clk),
        .ena  (dmem_prog_en),
        .wea  (dmem_prog_we),
        .dina (dmem_prog_wdata),
        .douta(dmem_prog_rdata),

        // Port B: GPU pipeline / Future CPU (shared)
        .addrb(gpu_dmem_addr),
        .clkb (clk),
        .enb  (gpu_dmem_en),
        .web  (gpu_dmem_we),
        .dinb (gpu_dmem_din),
        .doutb(gpu_dmem_dout)
    );

endmodule
