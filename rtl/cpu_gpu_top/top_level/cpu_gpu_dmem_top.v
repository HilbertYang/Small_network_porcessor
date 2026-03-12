// cpu_gpu_dmem_top.v
// Top-level wrapper that pairs data_process_unit (CPU + GPU) with the shared
// DMEM (D_M_64bit_256).
//
//   Port A of the BRAM → dmem_prog_* (external programming / future FIFO writes)
//   Port B of the BRAM → data_process_unit (GPU priority, CPU shared)
`timescale 1ns/1ps
module cpu_gpu_dmem_top (
    input  wire        clk,
    input  wire        reset,

    // Run control
    input  wire        run,
    input  wire        step,
    input  wire        pc_reset,
    output wire        done,

    // IMEM programming (imem_sel: 0 = GPU IMEM, 1 = CPU IMEM)
    input  wire        imem_sel,
    input  wire        imem_prog_we,
    input  wire [8:0]  imem_prog_addr,
    input  wire [31:0] imem_prog_wdata,

    // DMEM Port A — external programming (future: shared with FIFO for packet store)
    input  wire        dmem_prog_en,
    input  wire        dmem_prog_we,
    input  wire [7:0]  dmem_prog_addr,
    input  wire [63:0] dmem_prog_wdata,
    output wire [63:0] dmem_prog_rdata,

    // FIFO interface (passed through to data_process_unit → cpu_mt)
    input  wire [7:0]  fifo_start_offset,
    input  wire [7:0]  fifo_end_offset,
    input  wire        fifo_data_ready,
    output wire        fifo_data_done,

    // Debug
    output wire [8:0]  cpu_pc_dbg,
    output wire [31:0] cpu_instr_dbg,
    output wire [8:0]  gpu_pc_dbg,
    output wire [31:0] gpu_instr_dbg
);

    // -----------------------------------------------------------------------
    // Internal wires: data_process_unit ↔ BRAM Port B
    // -----------------------------------------------------------------------
    wire [7:0]  compute_dmem_addr;
    wire        compute_dmem_en;
    wire        compute_dmem_we;
    wire [63:0] compute_dmem_din;
    wire [63:0] compute_dmem_dout;

    // -----------------------------------------------------------------------
    // data_process_unit — CPU + GPU with external Port B
    // -----------------------------------------------------------------------
    data_process_unit u_dpu (
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
        
        .dmem_addr        (compute_dmem_addr),
        .dmem_en          (compute_dmem_en),
        .dmem_we          (compute_dmem_we),
        .dmem_din         (compute_dmem_din),
        .dmem_dout        (compute_dmem_dout),

        .fifo_start_offset(fifo_start_offset),
        .fifo_end_offset  (fifo_end_offset),
        .fifo_data_ready  (fifo_data_ready),
        .fifo_data_done   (fifo_data_done),

        .cpu_pc_dbg       (cpu_pc_dbg),
        .cpu_instr_dbg    (cpu_instr_dbg),
        .gpu_pc_dbg       (gpu_pc_dbg),
        .gpu_instr_dbg    (gpu_instr_dbg)
    );

    // -----------------------------------------------------------------------
    // Shared Data Memory
    //   Port A → external programming (dmem_prog_*)
    //   Port B → compute unit (GPU priority / CPU shared)
    // -----------------------------------------------------------------------
    D_M_64bit_256 u_dmem (
        // Port A: programming / future FIFO writes
        .clka  (clk),
        .ena   (dmem_prog_en),
        .wea   (dmem_prog_we),
        .addra (dmem_prog_addr),
        .dina  (dmem_prog_wdata),
        .douta (dmem_prog_rdata),

        // Port B: compute unit
        .clkb  (clk),
        .enb   (compute_dmem_en),
        .web   (compute_dmem_we),
        .addrb (compute_dmem_addr),
        .dinb  (compute_dmem_din),
        .doutb (compute_dmem_dout)
    );

endmodule
