// data_process_unit.v
// CPU + GPU compute unit with DMEM Port B exposed as external ports.
// No internal BRAM â connects to an external D_M_64bit_256 via dmem_* ports.
// FIFO boundary hints (fifo_start_offset, fifo_end_offset, fifo_data_ready)
// are top-level ports forwarded to the CPU.
`timescale 1ns/1ps
module data_process_unit #(parameter DMEM_ADDR_WDITH = 10) (
    input  wire        clk,
    input  wire        reset,

    // Run control
    input  wire        run,
    input  wire        step,
    input  wire        pc_reset,
    output wire        done,

    // IMEM programming mux (imem_sel: 0 = GPU IMEM, 1 = CPU IMEM)
    input  wire        imem_sel,
    input  wire        imem_prog_we,
    input  wire [8:0]  imem_prog_addr,
    input  wire [31:0] imem_prog_wdata,

    // DMEM Port B interface (connects to external BRAM Port B)
    output wire [DMEM_ADDR_WDITH-1:0]  dmem_addr,
    output wire        dmem_en,
    output wire        dmem_we,
    output wire [63:0] dmem_din,
    input  wire [63:0] dmem_dout,

    // FIFO interface (CPU reads packet boundaries from here)
    input  wire [DMEM_ADDR_WDITH-1:0]  fifo_start_offset,
    input  wire [DMEM_ADDR_WDITH-1:0]  fifo_end_offset,
    input  wire        fifo_data_ready,
    output wire        fifo_data_done,

    // Debug
    output wire [8:0]  cpu_pc_dbg,
    output wire [31:0] cpu_instr_dbg,
    output wire [8:0]  gpu_pc_dbg,
    output wire [31:0] gpu_instr_dbg
);

    // -----------------------------------------------------------------------
    // CPU -> GPU param write  (driven by cpu_mt)
    // -----------------------------------------------------------------------
    wire        cpu_param_wr_en;
    wire [3:0]  cpu_param_wr_addr;
    wire [63:0] cpu_param_wr_data;

    // -----------------------------------------------------------------------
    // IMEM programming mux
    //   addr and wdata broadcast to both; only the selected one gets we=1
    // -----------------------------------------------------------------------
    wire gpu_imem_we = imem_prog_we & ~imem_sel;
    wire cpu_imem_we = imem_prog_we &  imem_sel;

    // -----------------------------------------------------------------------
    // GPU core - Port B arbitration wires
    // -----------------------------------------------------------------------
    wire [DMEM_ADDR_WDITH-1:0]  gpu_dmem_addr;
    wire        gpu_dmem_en;
    wire        gpu_dmem_we;
    wire [63:0] gpu_dmem_din;
    wire [63:0] gpu_dmem_dout;

    // -----------------------------------------------------------------------
    // CPU core - Port B arbitration wires
    // -----------------------------------------------------------------------
    wire [DMEM_ADDR_WDITH-1:0]  cpu_dmem_addr;
    wire        cpu_dmem_en;
    wire        cpu_dmem_wen;
    wire [63:0] cpu_dmem_data_wr;
    wire [63:0] cpu_dmem_data_rd;

    // -----------------------------------------------------------------------
    // CPUâGPU control wires
    // -----------------------------------------------------------------------
    wire pc_reset_pulse = pc_reset;   // simple tie-off; no edge detection
    wire gpu_run;
    wire gpu_done;
    wire gpu_mem_access;

    assign gpu_done = done;           // GPU done feeds back to CPU input


    // -----------------------------------------------------------------------
    // GPU core
    // -----------------------------------------------------------------------
    gpu_core u_gpu_core (
        .clk             (clk),
        .reset           (reset),

        .run             (gpu_run),
        .step            (step),
        .pc_reset        (pc_reset),
        .done            (done),

        .param_wr_en     (cpu_param_wr_en),
        .param_wr_addr   (cpu_param_wr_addr),
        .param_wr_data   (cpu_param_wr_data),

        .imem_prog_we    (gpu_imem_we),
        .imem_prog_addr  (imem_prog_addr),
        .imem_prog_wdata (imem_prog_wdata),

        .dmem_addr       (gpu_dmem_addr),
        .dmem_en         (gpu_dmem_en),
        .dmem_we         (gpu_dmem_we),
        .dmem_din        (gpu_dmem_din),
        .dmem_dout       (gpu_dmem_dout),

        .pc_dbg          (gpu_pc_dbg),
        .if_instr_dbg    (gpu_instr_dbg)
    );

    // -----------------------------------------------------------------------
    // CPU core
    // -----------------------------------------------------------------------
    cpu_mt cpu_mt_inst (
        .clk              (clk),
        .reset            (reset),

        .run              (run),
        .step             (step),
        .pc_reset_pulse   (pc_reset_pulse),
        .imem_prog_we     (cpu_imem_we),
        .imem_prog_addr   (imem_prog_addr),
        .imem_prog_wdata  (imem_prog_wdata),
        .cpu_dmem_addr    (cpu_dmem_addr),
        .cpu_dmem_en      (cpu_dmem_en),
        .cpu_dmem_wen     (cpu_dmem_wen),
        .cpu_dmem_data_wr (cpu_dmem_data_wr),
        .cpu_dmem_data_rd (cpu_dmem_data_rd),
        .pc_dbg           (cpu_pc_dbg),
        .if_instr_dbg     (cpu_instr_dbg),

        .gpu_run          (gpu_run),
        .gpu_done         (gpu_done),
        .gpu_mem_access   (gpu_mem_access),
        .gpu_param_wr_en  (cpu_param_wr_en),
        .gpu_param_wr_addr(cpu_param_wr_addr),
        .gpu_param_wr_data(cpu_param_wr_data),

        .fifo_start_offset(fifo_start_offset),
        .fifo_end_offset  (fifo_end_offset),
        .fifo_data_ready  (fifo_data_ready),
        .fifo_data_done   (fifo_data_done)
    );

    // -----------------------------------------------------------------------
    // Port B arbitration: GPU has priority when gpu_mem_access asserted
    // -----------------------------------------------------------------------
    wire [DMEM_ADDR_WDITH-1:0]  portb_addr = gpu_mem_access ? gpu_dmem_addr    : cpu_dmem_addr;
    wire        portb_en   = gpu_mem_access ? gpu_dmem_en      : cpu_dmem_en;
    wire        portb_we   = gpu_mem_access ? gpu_dmem_we      : cpu_dmem_wen;
    wire [63:0] portb_din  = gpu_mem_access ? gpu_dmem_din     : cpu_dmem_data_wr;

    // Both GPU and CPU read from the same Port B return data
    assign gpu_dmem_dout    = dmem_dout;
    assign cpu_dmem_data_rd = dmem_dout;

    // -----------------------------------------------------------------------
    // Drive external DMEM Port B
    // -----------------------------------------------------------------------
    assign dmem_addr = portb_addr;
    assign dmem_en   = portb_en;
    assign dmem_we   = portb_we;
    assign dmem_din  = portb_din;

endmodule
