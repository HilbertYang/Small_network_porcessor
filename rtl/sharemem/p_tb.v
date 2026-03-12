`timescale 1ns/1ps

`define UDP_REG_ADDR_WIDTH 16
`define CPCI_NF2_DATA_WIDTH 16
`define IDS_BLOCK_TAG 1
`define IDS_REG_ADDR_WIDTH 16

module top_tb();
   reg clk;
   reg reset;
   reg [63:0] in_data;
   reg [7:0] in_ctrl;
   reg in_wr;
   wire in_rdy;
   
   wire [63:0] out_data;
   wire [7:0] out_ctrl;
   wire out_wr;
   reg out_rdy;

   // Register Interface Signals (Required by top_processor_system)
   reg                               reg_req_in;
   reg                               reg_ack_in;
   reg                               reg_rd_wr_L_in;
   reg  [15:0]                       reg_addr_in; // Based on UDP_REG_ADDR_WIDTH
   reg  [15:0]                       reg_data_in; // Based on CPCI_NF2_DATA_WIDTH
   reg  [1:0]                        reg_src_in;

   wire                              reg_req_out;
   wire                              reg_ack_out;
   wire                              reg_rd_wr_L_out;
   wire [15:0]                       reg_addr_out;
   wire [15:0]                       reg_data_out;
   wire [1:0]                        reg_src_out;

   // Instantiate Top Module
   top_processor_system uut (
      .clk(clk),
      .reset(reset),
      .in_data(in_data),
      .in_ctrl(in_ctrl),
      .in_wr(in_wr),
      .in_rdy(in_rdy),
      .out_data(out_data),
      .out_ctrl(out_ctrl),
      .out_wr(out_wr),
      .out_rdy(out_rdy),
      // Register interface connections
      .reg_req_in(reg_req_in),
      .reg_ack_in(reg_ack_in),
      .reg_rd_wr_L_in(reg_rd_wr_L_in),
      .reg_addr_in(reg_addr_in),
      .reg_data_in(reg_data_in),
      .reg_src_in(reg_src_in),
      .reg_req_out(reg_req_out),
      .reg_ack_out(reg_ack_out),
      .reg_rd_wr_L_out(reg_rd_wr_L_out),
      .reg_addr_out(reg_addr_out),
      .reg_data_out(reg_data_out),
      .reg_src_out(reg_src_out)
   );

   // Clock Generation
   initial clk = 0;
   always #5 clk = ~clk;

   initial begin
      // Initialize Signals
      reset = 1;
      in_data = 0;
      in_ctrl = 0;
      in_wr = 0;
      out_rdy = 1;
      reg_req_in = 0;
      reg_ack_in = 0;
      reg_rd_wr_L_in = 0;
      reg_addr_in = 0;
      reg_data_in = 0;
      reg_src_in = 0;

      #100;
      reset = 0;
      #20;

      // --- STEP 1: Send Packet ---
      // This sequence triggers the ids_ff which eventually asserts cpu_ack
      
      // Word 0: Module Header (Ctrl != 0)
      @(posedge clk);
      in_wr = 1;
      in_ctrl = 8'hFF; 
      in_data = 64'hAAAA_AAAA_AAAA_AAAA;

      // Ethernet/IP/UDP Headers (Logic from your data flow)
      @(posedge clk); in_ctrl = 8'h00; in_data = 64'h1122_3344_5566_AABB; 
      @(posedge clk); in_data = 64'hCCDDEE_FF08_0045_00; 
      @(posedge clk); in_data = 64'h0034_0000_0000_4011; 
      @(posedge clk); in_data = 64'hF7D5_C0A8_0101_C0A8; 
      @(posedge clk); in_data = 64'h0102_04D2_162E_0020; 

      // Payload Data (Target for +1 processing)
      @(posedge clk); in_data = 64'h0000_0000_0000_0001; // Expected: 2
      @(posedge clk); in_data = 64'h0000_0000_0000_000A; // Expected: B
      @(posedge clk); in_data = 64'h0000_0000_0000_00FF; // Expected: 100

      // Word 9: Trailer (Ctrl != 0) - Triggers end of packet
      @(posedge clk);
      in_ctrl = 8'h01;
      in_data = 64'hEEEE_EEEE_EEEE_EEEE;

      @(posedge clk);
      in_wr = 0;
      in_ctrl = 0;

      // --- STEP 2: Wait for CPU ---
      // The CPU starts when the FIFO sends cpu_ack after the trailer
      wait(uut.cpu_working); 
      $display("CPU Started Processing...");
      
      wait(uut.cpu_done);
      $display("CPU Processing Finished at Address: %h", uut.tail_addr);

      // --- STEP 3: Monitor Output ---
      #1000;

   end

   // Simple Monitor
   always @(posedge clk) begin
      if (out_wr) begin
         $display("TIME: %t | OUT_DATA: %h | OUT_CTRL: %h", $time, out_data, out_ctrl);
      end
   end

endmodule