// smartnic.v
//
// Top-level integration of the NF2 packet datapath with the CPU+GPU compute
// engine.  Three major blocks are instantiated here:
//
//   1. data_process_unit  — 5-stage pipelined CPU (cpu_mt, 4-thread ARM-like)
//                           + 5-stage pipelined GPU (gpu_core, BF16 tensor core)
//                           sharing a single 64-bit data memory port (Port B).
//
//   2. Shared DMEM (72-bit × 256 depth, dual-port BRAM)
//        Implemented as two parallel BRAMs:
//          D_M_64bit_256  — 64-bit data payload
//          dmem_8bit_256  — 8-bit per-word control/metadata sidecar
//        Port A: muxed between external host programming (dmem_prog_*)
//                and ids_fifo packet-store writes (ids_mem_*).
//                dmem_prog_en=1 gives priority to the host programmer.
//        Port B: connected exclusively to data_process_unit (GPU priority,
//                CPU shared via arbitration inside data_process_unit).
//
//   3. ids_fifo  — Packet FIFO bridging the NF2 64-bit word-level network
//                  interface (in_data/in_ctrl/out_data/out_ctrl) to the
//                  CPU+GPU compute pipeline.
//                  * Writes received packets into shared DMEM via Port A.
//                  * Asserts CPU_START (-> fifo_data_ready) to notify the CPU
//                    that a new packet window [head_addr, tail_addr] is ready.
//                  * Waits for CPU_ctrl (fifo_data_done pulse) from the CPU
//                    before forwarding the processed packet downstream.
`timescale 1ns/1ps
module smartnic (
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

    // FIFO interface (passed through to data_process_unit -> cpu_mt)
    output  wire [7:0]  fifo_start_offset,
    output  wire [7:0]  fifo_end_offset,
    output  wire        fifo_data_ready,
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
    wire          dmem_wea;

    assign dmem_ena =  1'b1; // always 1
    assign dmem_addra = dmem_prog_en ? dmem_prog_addr : ids_mem_addr;
    assign dmem_dina = dmem_prog_en ? {dmem_prog_ctrl_in, dmem_prog_wdata} : ids_mem_word;
    assign dmem_wea = dmem_prog_en ? dmem_prog_we : ids_mem_wen;
    assign mem_ids_word = dmem_douta;
    assign {dmem_prog_ctrl_out, dmem_prog_rdata} = mem_ids_word;

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
        .dina  (dmem_dina[63:0]),
        .douta (dmem_douta[63:0]),

        // Port B: compute unit
        .clkb  (clk),
        .enb   (compute_dmem_en),
        .web   (compute_dmem_we),
        .addrb (compute_dmem_addr),
        .dinb  (compute_dmem_din),
        .doutb (compute_dmem_dout)
    );
	
	dmem_8bit_256 u_dmem_2 (
        // Port A: programming / future FIFO writes
        .clka  (clk),
        .ena   (dmem_en),
        .wea   (dmem_wea),
        .addra (dmem_addra),
        .dina  (dmem_dina[71:64]),
        .douta (dmem_douta[71:64]),

        // Port B: compute unit
        .clkb  (clk),
        .enb   (1'b0),
        .web   (1'b0),
        .addrb (8'b0),
        .dinb  (8'b0),
        .doutb ()
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
