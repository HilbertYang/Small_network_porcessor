`timescale 1ns/1ps

`define UDP_REG_ADDR_WIDTH 16
`define CPCI_NF2_DATA_WIDTH 16
`define IDS_BLOCK_TAG 1
`define IDS_REG_ADDR_WIDTH 16

module top_processor_system #(
      parameter DATA_WIDTH = 64,
      parameter CTRL_WIDTH = DATA_WIDTH/8,
      parameter UDP_REG_SRC_WIDTH = 2
   )
   (
    input clk,
    input reset,
    
    // external 
    input  [63:0] in_data,
    input  [7:0]  in_ctrl,
    input         in_wr,
    output        in_rdy,
    
    output [63:0] out_data,
    output [7:0]  out_ctrl,
    output        out_wr,
    input         out_rdy,


     // --- Register interface
      input                               reg_req_in,
      input                               reg_ack_in,
      input                               reg_rd_wr_L_in,
      input  [`UDP_REG_ADDR_WIDTH-1:0]    reg_addr_in,
      input  [`CPCI_NF2_DATA_WIDTH-1:0]   reg_data_in,
      input  [UDP_REG_SRC_WIDTH-1:0]      reg_src_in,

      output                              reg_req_out,
      output                              reg_ack_out,
      output                              reg_rd_wr_L_out,
      output  [`UDP_REG_ADDR_WIDTH-1:0]   reg_addr_out,
      output  [`CPCI_NF2_DATA_WIDTH-1:0]  reg_data_out,
      output  [UDP_REG_SRC_WIDTH-1:0]     reg_src_out
);

    // internal Signals from fifo.v
    wire        cpu_ack;      // Signals end of packet 
    wire [7:0]  tail_addr;    // End of data boundary 
    wire [7:0]  head_addr = 8'h00; 
    wire         finish;

    //software reg
    wire [31:0]                   ids_cmd;

    //hardware reg
    wire [31:0]                   data_high;
    wire [31:0]                   data_low;
    wire [31:0]                   data_ctrl;
    
    // CPU logic signals
    reg         cpu_working;
    reg  [7:0]  cpu_addr_cnt;
    reg  [7:0]  header_offset = 8'h04;
    wire [7:0]  cpu_mem_addr;
    wire [71:0] cpu_mem_data;
    reg        cpu_mem_write;
    wire         cpu_done;

    wire combined_cpu_ctrl =  cpu_working;
    assign cpu_mem_addr = cpu_addr_cnt + header_offset; // Address from counter
    assign cpu_done = (cpu_mem_addr == tail_addr); // Done when address reaches tail



        fifo fifo_inst (
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
        .CPU_ctrl        (combined_cpu_ctrl), // Single control signal
        .CPU_MEM_ADDR    (cpu_mem_addr),
        .CPU_MEM_DATA    (cpu_mem_data),
        .CPU_MEM_WRITE   (cpu_mem_write),       // Writes only while moving
        .head_addr       (head_addr),
        .tail_addr       (tail_addr),
        .finish          (finish),
        .CPU_ack         (cpu_ack)            // Handshake 
    );

    wire [63:0] cpu_data_in  =  out_data; 


    // CPU LOGIC
    wire [63:0] cpu_data_out = cpu_data_in + 1'b1;   // +1 
    assign cpu_mem_data = { out_ctrl, cpu_data_out };
    

    always @(posedge clk) begin
        if (reset) begin
            cpu_working <= 0;
            cpu_addr_cnt <= 0;
            cpu_mem_write <= 0;
        end  else if (cpu_done) begin
            cpu_working <= 0; 
            cpu_addr_cnt <= 0; 
            cpu_mem_write <= 0;
        end else if (combined_cpu_ctrl) begin
            //read and write, 2 cycles per word
            if (cpu_mem_write == 0 ) begin
                cpu_mem_write <= 1; // Write during processing
                // cpu_data_out <= cpu_data_in + 1'b1; // Increment data
            end else begin
                 cpu_mem_write <= 0; // Write during processing
                 cpu_addr_cnt <= cpu_addr_cnt + 1; // Increment address counter
            end
        end else if (cpu_ack) begin
            cpu_working <= 1; 
            
        end
        
    end


    generic_regs
   #( 
      .UDP_REG_SRC_WIDTH   (UDP_REG_SRC_WIDTH),
      .TAG                 (`IDS_BLOCK_TAG),          // Tag -- eg. MODULE_TAG
      .REG_ADDR_WIDTH      (`IDS_REG_ADDR_WIDTH),     // Width of block addresses -- eg. MODULE_REG_ADDR_WIDTH
      .NUM_COUNTERS        (0),                 // Number of counters
      .NUM_SOFTWARE_REGS   (1),                 // Number of sw regs
      .NUM_HARDWARE_REGS   (3)                  // Number of hw regs
   ) module_regs (
      .reg_req_in       (reg_req_in),
      .reg_ack_in       (reg_ack_in),
      .reg_rd_wr_L_in   (reg_rd_wr_L_in),
      .reg_addr_in      (reg_addr_in),
      .reg_data_in      (reg_data_in),
      .reg_src_in       (reg_src_in),

      .reg_req_out      (reg_req_out),
      .reg_ack_out      (reg_ack_out),
      .reg_rd_wr_L_out  (reg_rd_wr_L_out),
      .reg_addr_out     (reg_addr_out),
      .reg_data_out     (reg_data_out),
      .reg_src_out      (reg_src_out),

      // --- counters interface
      .counter_updates  (),
      .counter_decrement(),

      // --- SW regs interface
      .software_regs    (ids_cmd),

      // --- HW regs interface
      .hardware_regs    ({data_ctrl, data_high, data_low}),

      .clk              (clk),
      .reset            (reset)
    );






endmodule