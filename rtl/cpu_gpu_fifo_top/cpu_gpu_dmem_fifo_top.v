// cpu_gpu_dmem_top.v
// Top-level wrapper that pairs data_process_unit (CPU + GPU) with the shared
// DMEM (D_M_64bit_256).
//
//   Port A of the BRAM -> dmem_prog_* (external programming / future FIFO writes)
//   Port B of the BRAM -> data_process_unit (GPU priority, CPU shared)
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


    wire [71:0]  mem_ids_word;
    wire [71:0]  ids_mem_word;
    wire [7:0]   ids_mem_addr;
    wire         ids_mem_wen;

    wire [7:0]  dmem_prog_ctrl_in;
    wire [7:0]  dmem_prog_ctrl_out;



    wire          dmem_ena;
    wire [7:0]    dmem_addra;
    wire [71:0]   dmem_dina;
    wire [71:0]   dmem_douta;
    wire          dmem_wea

    assign dmem_ena =  1'b1; // always 1
    assign dmem_addra = dmem_prog_en ? dmem_prog_addr : ids_mem_addr;
    assign dmem_dina = dmem_prog_en ? {dmem_prog_ctrl_in, dmem_prog_wdata} : ids_mem_word;
    assign dmem_wea = dmem_prog_en ? dmem_prog_we : ids_mem_wen;
    assign mem_ids_word = dmem_douta;
    assign {dmem_prog_ctrl_out, dmem_prog_rdata} = mem_ids_word;

    // FIFO interface (passed through to data_process_unit -> cpu_mt)
    input  wire [7:0]  fifo_start_offset,
    input  wire [7:0]  fifo_end_offset,
    input  wire        fifo_data_ready,
    output wire        fifo_data_done,

    // Debug
    output wire [8:0]  cpu_pc_dbg,
    output wire [31:0] cpu_instr_dbg,
    output wire [8:0]  gpu_pc_dbg,
    output wire [31:0] gpu_instr_dbg,


    // external  interface
    input  [63:0] in_data,
    input  [7:0]  in_ctrl,
    input         in_wr,
    output        in_rdy,
    
    output [63:0] out_data,
    output [7:0]  out_ctrl,
    output        out_wr,
    input         out_rdy
);

    // -----------------------------------------------------------------------
    // Internal wires: data_process_unit - BRAM Port B
    // -----------------------------------------------------------------------
    wire [7:0]  compute_dmem_addr;
    wire        compute_dmem_en;
    wire        compute_dmem_we;
    wire [63:0] compute_dmem_din;
    wire [63:0] compute_dmem_dout;

   

    // -----------------------------------------------------------------------
    // Internal wires: fifo - data_process_unit
    // -----------------------------------------------------------------------
    wire         finish;
    assign       fifo_start_offset = 8'h00;



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
    //   Port A -> external programming (dmem_prog_*)
    //   Port B -> compute unit (GPU priority / CPU shared)
    // -----------------------------------------------------------------------
    D_M_64bit_256 u_dmem (
        // Port A: programming / future FIFO writes
        .clka  (clk),
        .ena   (dmem_en),
        .wea   (dmem_wea),
        .addra (dmem_addra),
        .dina  (dmem_dina),
        .douta (dmem_douta),

        // Port B: compute unit
        .clkb  (clk),
        .enb   (compute_dmem_en),
        .web   (compute_dmem_we),
        .addrb (compute_dmem_addr),
        .dinb  (compute_dmem_din),
        .doutb (compute_dmem_dout)
    );


     ids_fifo ids_fifo_inst (
    .clk             (clk),
    .reset           (reset),
    .in_data         (in_data),
    .in_ctrl         (in_ctrl),
    .in_wr           (in_wr),
    .in_rdy          (in_rdy),
    .out_data        (out_data),
    .out_ctrl        (out_ctrl),
    .out_wr          (out_wr),
    .out_rdy         (out_rdy),

    .CPU_ctrl        (fifo_data_done), // input, pulse
    .head_addr       (fifo_start_offset),
    .tail_addr       (fifo_end_offset),
    .finish          (finish),
    .CPU_START         (fifo_data_ready),            // output, level

    // Memory interface
    .mem_ids_word     (mem_ids_word),
    .ids_mem_word     (ids_mem_word),
    .ids_mem_addr     (ids_mem_addr),
    .ids_mem_wen      (ids_mem_wen)
);

endmodule
