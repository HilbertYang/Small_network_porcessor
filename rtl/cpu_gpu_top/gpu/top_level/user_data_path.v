///////////////////////////////////////////////////////////////////////////////
// vim:set shiftwidth=3 softtabstop=3 expandtab:
// $Id: user_data_path.v 4385 2008-08-05 02:10:01Z grg $
//
// Module: user_data_path.v
// Project: NF2.1 — trimmed for register-only SM GPU use
//
// Packet data path (input_arbiter, output_port_lookup, output_queues, IDS)
// is removed to fit within XC2VP50 slice budget.
// Only the register ring udp_reg_master -> gpu_top_regs -> udp_reg_master
// is instantiated.
///////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps

module user_data_path
  #(parameter DATA_WIDTH = 64,
    parameter CTRL_WIDTH=DATA_WIDTH/8,
    parameter UDP_REG_SRC_WIDTH = 2,
    parameter NUM_OUTPUT_QUEUES = 8,
    parameter NUM_INPUT_QUEUES = 8,
    parameter SRAM_DATA_WIDTH = DATA_WIDTH+CTRL_WIDTH,
    parameter SRAM_ADDR_WIDTH = 19)

   (
    input  [DATA_WIDTH-1:0]            in_data_0,
    input  [CTRL_WIDTH-1:0]            in_ctrl_0,
    input                              in_wr_0,
    output                             in_rdy_0,

    input  [DATA_WIDTH-1:0]            in_data_1,
    input  [CTRL_WIDTH-1:0]            in_ctrl_1,
    input                              in_wr_1,
    output                             in_rdy_1,

    input  [DATA_WIDTH-1:0]            in_data_2,
    input  [CTRL_WIDTH-1:0]            in_ctrl_2,
    input                              in_wr_2,
    output                             in_rdy_2,

    input  [DATA_WIDTH-1:0]            in_data_3,
    input  [CTRL_WIDTH-1:0]            in_ctrl_3,
    input                              in_wr_3,
    output                             in_rdy_3,

    input  [DATA_WIDTH-1:0]            in_data_4,
    input  [CTRL_WIDTH-1:0]            in_ctrl_4,
    input                              in_wr_4,
    output                             in_rdy_4,

    input  [DATA_WIDTH-1:0]            in_data_5,
    input  [CTRL_WIDTH-1:0]            in_ctrl_5,
    input                              in_wr_5,
    output                             in_rdy_5,

    input  [DATA_WIDTH-1:0]            in_data_6,
    input  [CTRL_WIDTH-1:0]            in_ctrl_6,
    input                              in_wr_6,
    output                             in_rdy_6,

    input  [DATA_WIDTH-1:0]            in_data_7,
    input  [CTRL_WIDTH-1:0]            in_ctrl_7,
    input                              in_wr_7,
    output                             in_rdy_7,

    output  [DATA_WIDTH-1:0]           out_data_0,
    output  [CTRL_WIDTH-1:0]           out_ctrl_0,
    output                             out_wr_0,
    input                              out_rdy_0,

    output  [DATA_WIDTH-1:0]           out_data_1,
    output  [CTRL_WIDTH-1:0]           out_ctrl_1,
    output                             out_wr_1,
    input                              out_rdy_1,

    output  [DATA_WIDTH-1:0]           out_data_2,
    output  [CTRL_WIDTH-1:0]           out_ctrl_2,
    output                             out_wr_2,
    input                              out_rdy_2,

    output  [DATA_WIDTH-1:0]           out_data_3,
    output  [CTRL_WIDTH-1:0]           out_ctrl_3,
    output                             out_wr_3,
    input                              out_rdy_3,

    output  [DATA_WIDTH-1:0]           out_data_4,
    output  [CTRL_WIDTH-1:0]           out_ctrl_4,
    output                             out_wr_4,
    input                              out_rdy_4,

    output  [DATA_WIDTH-1:0]           out_data_5,
    output  [CTRL_WIDTH-1:0]           out_ctrl_5,
    output                             out_wr_5,
    input                              out_rdy_5,

    output  [DATA_WIDTH-1:0]           out_data_6,
    output  [CTRL_WIDTH-1:0]           out_ctrl_6,
    output                             out_wr_6,
    input                              out_rdy_6,

    output  [DATA_WIDTH-1:0]           out_data_7,
    output  [CTRL_WIDTH-1:0]           out_ctrl_7,
    output                             out_wr_7,
    input                              out_rdy_7,

     // interface to SRAM
     output [SRAM_ADDR_WIDTH-1:0]       wr_0_addr,
     output                             wr_0_req,
     input                              wr_0_ack,
     output [SRAM_DATA_WIDTH-1:0]       wr_0_data,

     input                              rd_0_ack,
     input  [SRAM_DATA_WIDTH-1:0]       rd_0_data,
     input                              rd_0_vld,
     output [SRAM_ADDR_WIDTH-1:0]       rd_0_addr,
     output                             rd_0_req,

     // register interface
     input                              reg_req,
     output                             reg_ack,
     input                              reg_rd_wr_L,
     input [`UDP_REG_ADDR_WIDTH-1:0]    reg_addr,
     output [`CPCI_NF2_DATA_WIDTH-1:0]  reg_rd_data,
     input [`CPCI_NF2_DATA_WIDTH-1:0]   reg_wr_data,

     // misc
     input                              reset,
     input                              clk);

   //--------------------------------------------------
   // Tie off all packet data path outputs — no packets
   //--------------------------------------------------
   assign in_rdy_0 = 1'b1;
   assign in_rdy_1 = 1'b1;
   assign in_rdy_2 = 1'b1;
   assign in_rdy_3 = 1'b1;
   assign in_rdy_4 = 1'b1;
   assign in_rdy_5 = 1'b1;
   assign in_rdy_6 = 1'b1;
   assign in_rdy_7 = 1'b1;

   assign out_data_0 = {DATA_WIDTH{1'b0}};
   assign out_ctrl_0 = {CTRL_WIDTH{1'b0}};
   assign out_wr_0   = 1'b0;

   assign out_data_1 = {DATA_WIDTH{1'b0}};
   assign out_ctrl_1 = {CTRL_WIDTH{1'b0}};
   assign out_wr_1   = 1'b0;

   assign out_data_2 = {DATA_WIDTH{1'b0}};
   assign out_ctrl_2 = {CTRL_WIDTH{1'b0}};
   assign out_wr_2   = 1'b0;

   assign out_data_3 = {DATA_WIDTH{1'b0}};
   assign out_ctrl_3 = {CTRL_WIDTH{1'b0}};
   assign out_wr_3   = 1'b0;

   assign out_data_4 = {DATA_WIDTH{1'b0}};
   assign out_ctrl_4 = {CTRL_WIDTH{1'b0}};
   assign out_wr_4   = 1'b0;

   assign out_data_5 = {DATA_WIDTH{1'b0}};
   assign out_ctrl_5 = {CTRL_WIDTH{1'b0}};
   assign out_wr_5   = 1'b0;

   assign out_data_6 = {DATA_WIDTH{1'b0}};
   assign out_ctrl_6 = {CTRL_WIDTH{1'b0}};
   assign out_wr_6   = 1'b0;

   assign out_data_7 = {DATA_WIDTH{1'b0}};
   assign out_ctrl_7 = {CTRL_WIDTH{1'b0}};
   assign out_wr_7   = 1'b0;

   //--------------------------------------------------
   // Tie off SRAM interface — not used
   //--------------------------------------------------
   assign wr_0_addr = {SRAM_ADDR_WIDTH{1'b0}};
   assign wr_0_req  = 1'b0;
   assign wr_0_data = {SRAM_DATA_WIDTH{1'b0}};
   assign rd_0_addr = {SRAM_ADDR_WIDTH{1'b0}};
   assign rd_0_req  = 1'b0;

   //--------------------------------------------------
   // Register ring: udp_reg_master -> gpu_top_regs -> udp_reg_master
   //--------------------------------------------------

   // Wires from udp_reg_master output to gpu_top_regs input
   wire                             master_to_gpu_reg_req;
   wire                             master_to_gpu_reg_ack;
   wire                             master_to_gpu_reg_rd_wr_L;
   wire [`UDP_REG_ADDR_WIDTH-1:0]   master_to_gpu_reg_addr;
   wire [`CPCI_NF2_DATA_WIDTH-1:0]  master_to_gpu_reg_data;
   wire [UDP_REG_SRC_WIDTH-1:0]     master_to_gpu_reg_src;

   // Wires from gpu_top_regs output back to udp_reg_master input
   wire                             gpu_to_master_reg_req;
   wire                             gpu_to_master_reg_ack;
   wire                             gpu_to_master_reg_rd_wr_L;
   wire [`UDP_REG_ADDR_WIDTH-1:0]   gpu_to_master_reg_addr;
   wire [`CPCI_NF2_DATA_WIDTH-1:0]  gpu_to_master_reg_data;
   wire [UDP_REG_SRC_WIDTH-1:0]     gpu_to_master_reg_src;

   //--------------------------------------------------
   // gpu_top_regs — GPU register module
   //--------------------------------------------------
   gpu_top_regs #(
      .UDP_REG_SRC_WIDTH(UDP_REG_SRC_WIDTH)
   ) gpu_regs (
      .clk            (clk),
      .reset          (reset),

      .reg_req_in     (master_to_gpu_reg_req),
      .reg_ack_in     (master_to_gpu_reg_ack),
      .reg_rd_wr_L_in (master_to_gpu_reg_rd_wr_L),
      .reg_addr_in    (master_to_gpu_reg_addr),
      .reg_data_in    (master_to_gpu_reg_data),
      .reg_src_in     (master_to_gpu_reg_src),

      .reg_req_out    (gpu_to_master_reg_req),
      .reg_ack_out    (gpu_to_master_reg_ack),
      .reg_rd_wr_L_out(gpu_to_master_reg_rd_wr_L),
      .reg_addr_out   (gpu_to_master_reg_addr),
      .reg_data_out   (gpu_to_master_reg_data),
      .reg_src_out    (gpu_to_master_reg_src),

      .pc_dbg         (),
      .if_instr_dbg   ()
   );

   //--------------------------------------------------
   // udp_reg_master — register ring master
   //--------------------------------------------------
   udp_reg_master #(
      .UDP_REG_SRC_WIDTH (UDP_REG_SRC_WIDTH)
   ) udp_reg_master (
      // Core register interface signals
      .core_reg_req                          (reg_req),
      .core_reg_ack                          (reg_ack),
      .core_reg_rd_wr_L                      (reg_rd_wr_L),
      .core_reg_addr                         (reg_addr),
      .core_reg_rd_data                      (reg_rd_data),
      .core_reg_wr_data                      (reg_wr_data),

      // UDP register interface signals (output) -> to gpu_top_regs
      .reg_req_out                           (master_to_gpu_reg_req),
      .reg_ack_out                           (master_to_gpu_reg_ack),
      .reg_rd_wr_L_out                       (master_to_gpu_reg_rd_wr_L),
      .reg_addr_out                          (master_to_gpu_reg_addr),
      .reg_data_out                          (master_to_gpu_reg_data),
      .reg_src_out                           (master_to_gpu_reg_src),

      // UDP register interface signals (input) <- from gpu_top_regs
      .reg_req_in                            (gpu_to_master_reg_req),
      .reg_ack_in                            (gpu_to_master_reg_ack),
      .reg_rd_wr_L_in                        (gpu_to_master_reg_rd_wr_L),
      .reg_addr_in                           (gpu_to_master_reg_addr),
      .reg_data_in                           (gpu_to_master_reg_data),
      .reg_src_in                            (gpu_to_master_reg_src),

      //
      .clk                                   (clk),
      .reset                                 (reset)
   );


endmodule // user_data_path
