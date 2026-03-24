`timescale 1ns/1ps
// smartnic_top_regs.v
// Register ring wrapper for cpu_gpu_dmem_top (CPU + GPU + shared DMEM).
// Analogous to gpu_top_regs.v but wraps the full CPU+GPU subsystem.
//
// SW register map (8 regs):
//   0  sw_ctrl          [0]=run [1]=step [2]=pc_reset [3]=imem_prog_we
//                       [4]=dmem_prog_en [5]=dmem_prog_we [6]=imem_sel
//   1  sw_imem_addr     [8:0]  IMEM program address
//   2  sw_imem_wdata    [31:0] IMEM program write data
//   3  sw_dmem_addr     [7:0]  DMEM Port-A program address
//   4  sw_dmem_wdata_lo [31:0] DMEM write data [31:0]
//   5  sw_dmem_wdata_hi [31:0] DMEM write data [63:32]
//   6  sw_fifo_ctrl     [7:0]=fifo_start_offset  [15:8]=fifo_end_offset
//                       [16]=fifo_data_ready
//   7  (reserved / spare)
//
// HW register map (9 regs):
//   0  hw_cpu_pc_dbg      CPU current PC [8:0]
//   1  hw_cpu_if_instr    CPU IF-stage instruction [31:0]
//   2  hw_gpu_pc_dbg      GPU current PC [8:0]
//   3  hw_gpu_if_instr    GPU IF-stage instruction [31:0]
//   4  hw_dmem_rdata_lo   DMEM Port-A read data [31:0]
//   5  hw_dmem_rdata_hi   DMEM Port-A read data [63:32]
//   6  hw_done            GPU kernel done flag [0]
//   7  hw_fifo_data_done  CPU fifo_data_done output [0]
//   8  hw_hb              Heartbeat counter [31:0]
//
// Block address and register-address width must be defined in the
// project registers include (registers.v).  Suggested values:
//   `define CPU_GPU_BLOCK_ADDR       19'h0000d
//   `define CPU_GPU_REG_ADDR_WIDTH   4

module smartnic_top_regs #(
  parameter DATA_WIDTH        = 64,
  parameter CTRL_WIDTH        = DATA_WIDTH/8,
  parameter UDP_REG_SRC_WIDTH = 2
)(
  input  wire                              clk,
  input  wire                              reset,

  // Register ring (in)
  input  wire                              reg_req_in,
  input  wire                              reg_ack_in,
  input  wire                              reg_rd_wr_L_in,
  input  wire [`UDP_REG_ADDR_WIDTH-1:0]    reg_addr_in,
  input  wire [`CPCI_NF2_DATA_WIDTH-1:0]  reg_data_in,
  input  wire [UDP_REG_SRC_WIDTH-1:0]     reg_src_in,

  // Register ring (out)
  output wire                              reg_req_out,
  output wire                              reg_ack_out,
  output wire                              reg_rd_wr_L_out,
  output wire [`UDP_REG_ADDR_WIDTH-1:0]   reg_addr_out,
  output wire [`CPCI_NF2_DATA_WIDTH-1:0]  reg_data_out,
  output wire [UDP_REG_SRC_WIDTH-1:0]     reg_src_out,

  // Debug outputs (optional; tie to () in user_data_path if unused)
  output wire [8:0]                        cpu_pc_dbg,
  output wire [31:0]                       cpu_instr_dbg,
  output wire [8:0]                        gpu_pc_dbg,
  output wire [31:0]                       gpu_instr_dbg,

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

  // =========================================================================
  // SW registers
  // =========================================================================
  wire [31:0] sw_ctrl;
  wire [31:0] sw_imem_addr;
  wire [31:0] sw_imem_wdata;
  wire [31:0] sw_dmem_addr;
  wire [31:0] sw_dmem_wdata_lo;
  wire [31:0] sw_dmem_wdata_hi;
  wire [31:0] sw_fifo_ctrl;
  wire [31:0] sw_reserved;
  wire [8*32-1:0] software_regs_bus;

  // Control bit decode
  wire        run_level     = sw_ctrl[0];
  wire        step          = sw_ctrl[1];
  wire        pc_reset      = sw_ctrl[2];
  wire        imem_prog_we  = sw_ctrl[3];
  wire        dmem_prog_en  = sw_ctrl[4];
  wire        dmem_prog_we  = sw_ctrl[5];
  wire        imem_sel      = sw_ctrl[6];   // 0=GPU IMEM, 1=CPU IMEM

  // Field decode
  wire [8:0]  imem_prog_addr       = sw_imem_addr[8:0];
  wire [31:0] imem_prog_wdata      = sw_imem_wdata;
  wire [7:0]  dmem_prog_addr       = sw_dmem_addr[7:0];
  wire [63:0] dmem_prog_wdata      = {sw_dmem_wdata_hi, sw_dmem_wdata_lo};
  wire [7:0]  fifo_start_offset    = sw_fifo_ctrl[7:0];
  wire [7:0]  fifo_end_offset      = sw_fifo_ctrl[15:8];
  wire        fifo_data_ready      = sw_fifo_ctrl[16];

  // =========================================================================
  // HW registers
  // =========================================================================
  wire [63:0] dmem_prog_rdata;
  wire        done;
  wire        fifo_data_done;

  reg [31:0] hb;
  always @(posedge clk) begin
    if (reset) hb <= 0;
    else        hb <= hb + 1;
  end

  wire [31:0] hw_cpu_pc_dbg      = {23'h0, cpu_pc_dbg};
  wire [31:0] hw_cpu_if_instr    = cpu_instr_dbg;
  wire [31:0] hw_gpu_pc_dbg      = {23'h0, gpu_pc_dbg};
  wire [31:0] hw_gpu_if_instr    = gpu_instr_dbg;
  wire [31:0] hw_dmem_rdata_lo   = dmem_prog_rdata[31:0];
  wire [31:0] hw_dmem_rdata_hi   = dmem_prog_rdata[63:32];
  wire [31:0] hw_done            = {31'h0, done};
  wire [31:0] hw_fifo_data_done  = {31'h0, fifo_data_done};
  wire [31:0] hw_hb              = hb;
  wire [9*32-1:0] hardware_regs_bus;

  // =========================================================================
  // Bus pack/unpack
  // =========================================================================
  assign hardware_regs_bus = {hw_hb,
                              hw_fifo_data_done,
                              hw_done,
                              hw_dmem_rdata_hi,
                              hw_dmem_rdata_lo,
                              hw_gpu_if_instr,
                              hw_gpu_pc_dbg,
                              hw_cpu_if_instr,
                              hw_cpu_pc_dbg};

  assign sw_ctrl          = software_regs_bus[ 31:  0];
  assign sw_imem_addr     = software_regs_bus[ 63: 32];
  assign sw_imem_wdata    = software_regs_bus[ 95: 64];
  assign sw_dmem_addr     = software_regs_bus[127: 96];
  assign sw_dmem_wdata_lo = software_regs_bus[159:128];
  assign sw_dmem_wdata_hi = software_regs_bus[191:160];
  assign sw_fifo_ctrl     = software_regs_bus[223:192];
  assign sw_reserved      = software_regs_bus[255:224];

  // =========================================================================
  // smartnic_top instantiation
  // =========================================================================
  smartnic_top u_smartnic_top (
      .clk               (clk),
      .reset             (reset),

      .run               (run_level),
      .step              (step),
      .pc_reset          (pc_reset),
      .done              (done),

      .imem_sel          (imem_sel),
      .imem_prog_we      (imem_prog_we),
      .imem_prog_addr    (imem_prog_addr),
      .imem_prog_wdata   (imem_prog_wdata),

      .dmem_prog_en      (dmem_prog_en),
      .dmem_prog_we      (dmem_prog_we),
      .dmem_prog_addr    (dmem_prog_addr),
      .dmem_prog_wdata   (dmem_prog_wdata),
      .dmem_prog_rdata   (dmem_prog_rdata),

      .fifo_start_offset (fifo_start_offset),
      .fifo_end_offset   (fifo_end_offset),
      .fifo_data_ready   (fifo_data_ready),
      .fifo_data_done    (fifo_data_done),

      .cpu_pc_dbg        (cpu_pc_dbg),
      .cpu_instr_dbg     (cpu_instr_dbg),
      .gpu_pc_dbg        (gpu_pc_dbg),
      .gpu_instr_dbg     (gpu_instr_dbg),

      .in_data           (in_data),
      .in_ctrl           (in_ctrl),
      .in_wr             (in_wr),
      .in_rdy            (in_rdy),
      .out_data          (out_data),
      .out_ctrl          (out_ctrl),
      .out_wr            (out_wr),
      .out_rdy           (out_rdy)


  );

  // =========================================================================
  // generic_regs — NF2 register ring slave
  // =========================================================================
  generic_regs #(
    .UDP_REG_SRC_WIDTH (UDP_REG_SRC_WIDTH),
    .TAG               (`SMARTNIC_BLOCK_ADDR),
    .REG_ADDR_WIDTH    (`SMARTNIC_ADDR_WIDTH),
    .NUM_COUNTERS      (0),
    .NUM_SOFTWARE_REGS (8),
    .NUM_HARDWARE_REGS (9)
  ) u_regs (
    .reg_req_in        (reg_req_in),
    .reg_ack_in        (reg_ack_in),
    .reg_rd_wr_L_in    (reg_rd_wr_L_in),
    .reg_addr_in       (reg_addr_in),
    .reg_data_in       (reg_data_in),
    .reg_src_in        (reg_src_in),

    .reg_req_out       (reg_req_out),
    .reg_ack_out       (reg_ack_out),
    .reg_rd_wr_L_out   (reg_rd_wr_L_out),
    .reg_addr_out      (reg_addr_out),
    .reg_data_out      (reg_data_out),
    .reg_src_out       (reg_src_out),

    .counter_updates   (),
    .counter_decrement (),

    .software_regs     (software_regs_bus),
    .hardware_regs     (hardware_regs_bus),

    .clk               (clk),
    .reset             (reset)
  );

endmodule
