`timescale 1ns/1ps
module gpu_top_regs #(
  parameter DATA_WIDTH        = 64,
  parameter CTRL_WIDTH        = DATA_WIDTH/8,
  parameter UDP_REG_SRC_WIDTH = 2
)(
  input  wire                         clk,
  input  wire                         reset,

  input  wire                         reg_req_in,
  input  wire                         reg_ack_in,
  input  wire                         reg_rd_wr_L_in,
  input  wire [`UDP_REG_ADDR_WIDTH-1:0]   reg_addr_in,
  input  wire [`CPCI_NF2_DATA_WIDTH-1:0]  reg_data_in,
  input  wire [UDP_REG_SRC_WIDTH-1:0]     reg_src_in,

  output wire                         reg_req_out,
  output wire                         reg_ack_out,
  output wire                         reg_rd_wr_L_out,
  output wire [`UDP_REG_ADDR_WIDTH-1:0]   reg_addr_out,
  output wire [`CPCI_NF2_DATA_WIDTH-1:0]  reg_data_out,
  output wire [UDP_REG_SRC_WIDTH-1:0]     reg_src_out,

  output wire [8:0]                   pc_dbg,
  output wire [31:0]                  if_instr_dbg

);


//===================SW REGS===================
  wire [31:0] sw_ctrl;
  wire [31:0] sw_imem_addr;
  wire [31:0] sw_imem_wdata;
  wire [31:0] sw_dmem_addr;
  wire [31:0] sw_dmem_wdata_lo;
  wire [31:0] sw_dmem_wdata_hi;
  wire [31:0] sw_param_addr;                                           
  wire [31:0] sw_param_data_lo;                                      
  wire [31:0] sw_param_data_hi;                                        
  wire [9*32-1:0] software_regs_bus;

  wire run_level      =  sw_ctrl[0];
  wire step           =  sw_ctrl[1];
  wire pc_reset       =  sw_ctrl[2];
  wire imem_prog_we   =  sw_ctrl[3];
  wire dmem_prog_en   =  sw_ctrl[4];
  wire dmem_prog_we   =  sw_ctrl[5];
  wire param_wr_en    =  sw_ctrl[6];                                   
  wire [8:0]  imem_prog_addr  = sw_imem_addr[8:0];
  wire [31:0] imem_prog_wdata = sw_imem_wdata;
  wire [7:0]  dmem_prog_addr  = sw_dmem_addr[7:0];
  wire [63:0] dmem_prog_wdata = {sw_dmem_wdata_hi, sw_dmem_wdata_lo};
  wire [2:0]  param_wr_addr   = sw_param_addr[2:0];                    
  wire [63:0] param_wr_data   = {sw_param_data_hi, sw_param_data_lo};  

//=============================HW REGS========================================
  wire [63:0] dmem_prog_rdata;
  wire        done;                                                      

  reg [31:0] hb;
  always @(posedge clk) begin
    if (reset) hb <= 0;
    else hb <= hb + 1;
  end
  
  wire [31:0] hw_pc_dbg        = {23'h0, pc_dbg}; 
  wire [31:0] hw_if_instr      = if_instr_dbg;
  wire [31:0] hw_dmem_rdata_lo = dmem_prog_rdata[31:0];
  wire [31:0] hw_dmem_rdata_hi = dmem_prog_rdata[63:32];
  wire [31:0] hw_done          = {31'h0, done};                         
  wire [31:0] hw_hb            = hb;                                 
  wire [6*32-1:0] hardware_regs_bus;



//=============================PACK BUS============================================

  assign hardware_regs_bus = {hw_hb,
                              hw_done,
                              hw_dmem_rdata_hi,
                              hw_dmem_rdata_lo,
                              hw_if_instr,
                              hw_pc_dbg};

  assign sw_ctrl            = software_regs_bus[ 31:  0];
  assign sw_imem_addr       = software_regs_bus[ 63: 32];
  assign sw_imem_wdata      = software_regs_bus[ 95: 64];
  assign sw_dmem_addr       = software_regs_bus[127: 96];
  assign sw_dmem_wdata_lo   = software_regs_bus[159:128];
  assign sw_dmem_wdata_hi   = software_regs_bus[191:160];
  assign sw_param_addr      = software_regs_bus[223:192];
  assign sw_param_data_lo   = software_regs_bus[255:224];
  assign sw_param_data_hi   = software_regs_bus[287:256];

//=============================PIPELINE=============================
    gpu_core u_gpu_core (
        .clk             (clk),
        .reset           (reset),

        .run             (run_level),
        .step            (step),
        .pc_reset        (pc_reset),
        .done            (done),

        .param_wr_en     (param_wr_en),
        .param_wr_addr   (param_wr_addr),
        .param_wr_data   (param_wr_data),

        .imem_prog_we    (imem_prog_we),
        .imem_prog_addr  (imem_prog_addr),
        .imem_prog_wdata (imem_prog_wdata),
        
        .dmem_prog_en    (dmem_prog_en),
        .dmem_prog_we    (dmem_prog_we),
        .dmem_prog_addr  (dmem_prog_addr),
        .dmem_prog_wdata (dmem_prog_wdata),
        .dmem_prog_rdata (dmem_prog_rdata),

        .pc_dbg          (pc_dbg),
        .if_instr_dbg    (if_instr_dbg)
    );

  //=========================
  // CPU request:
  // reg_reg         ->    1
  // reg_rd_wr_L     ->    1 for read, 0 for write
  // reg_addr        ->    {tag, addr}
  // reg_data        ->    data
  // regeric response:
  // reg_rd_wr_L     ->    same as request
  // reg_addr        ->    same as request
  // reg_data        ->    data to be read when reg_rd_wr_L is 1, ignored otherwise
  // reg_ack         ->    1 when the request is done
  //==========================
  generic_regs #(
    .UDP_REG_SRC_WIDTH (UDP_REG_SRC_WIDTH),
    .TAG               (`GPU_BLOCK_ADDR),// Only the address with this tag will be decoded and sent to this module
    .REG_ADDR_WIDTH    (`GPU_REG_ADDR_WIDTH),// Only the lower REG_ADDR_WIDTH bits of the address will be decoded
    .NUM_COUNTERS      (0),
    .NUM_SOFTWARE_REGS (9),
    .NUM_HARDWARE_REGS (6)
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
