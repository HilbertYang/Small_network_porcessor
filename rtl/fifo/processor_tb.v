`timescale 1ns/1ps

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
      .out_rdy(out_rdy)
   );

   // Clock Generation
   initial clk = 0;
   always #5 clk = ~clk;

   initial begin
      // Initialize
      reset = 1;
      in_data = 0;
      in_ctrl = 0;
      in_wr = 0;
      out_rdy = 1;

      #100;
      reset = 0;
      #20;

      // --- STEP 1: Send Packet ---
      // Word 0: Module Header (Ctrl != 0)
      @(posedge clk);
      in_wr = 1;
      in_ctrl = 8'hFF; 
      in_data = 64'hAAAA_AAAA_AAAA_AAAA;

      // Word 1-3: Protocol Headers (Ctrl == 0)
      repeat(3) begin
         @(posedge clk);
         in_ctrl = 8'h00;
         in_data = 64'hBBBB_BBBB_BBBB_BBBB;
      end

      // Word 4-6: Payload Data (The target for +1)
      @(posedge clk); in_data = 64'h0000_0000_0000_0001; // Should become 2
      @(posedge clk); in_data = 64'h0000_0000_0000_000A; // Should become B
      @(posedge clk); in_data = 64'h0000_0000_0000_00FF; // Should become 100

      // Word 7: Trailer (Ctrl != 0) - Triggers end_of_pkt/cpu_ack
      @(posedge clk);
      in_ctrl = 8'h01;
      in_data = 64'hEEEE_EEEE_EEEE_EEEE;


      // --- STEP 2: Observe CPU Processing ---
     
      
      @(posedge clk);
      in_wr = 0;
      in_ctrl = 0;
      
      wait(uut.cpu_done);
      $display("CPU Processing Finished at Address: %h", uut.tail_addr);

      // --- STEP 3: Monitor Output ---
      // The internal FSM should move to PULLBACK and start reading out.
      // Verify that out_data[4] is 2, out_data[5] is B, etc.
      
      #500;
   end

   // Simple Monitor
   always @(posedge clk) begin
      if (out_wr) begin
         $display("TIME: %t | OUT_DATA: %h | OUT_CTRL: %h", $time, out_data, out_ctrl);
      end
   end

endmodule