///////////////////////////////////////////////////////////////////////////////
// vim:set shiftwidth=3 softtabstop=3 expandtab:
// Module: ids_sim.v
// Project: NF2.1
// Description: Defines a simple ids module for the user data path.  The
// modules reads a 64-bit register that contains a pattern to match and
// counts how many packets match.  The register contents are 7 bytes of
// pattern and one byte of mask.  The mask bits are set to one for each
// byte of the pattern that should be included in the mask -- zero bits
// mean "don't care".
//
///////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps



`define UDP_REG_ADDR_WIDTH 16
`define CPCI_NF2_DATA_WIDTH 16
`define IDS_BLOCK_TAG 1
`define IDS_REG_ADDR_WIDTH 16

module fifo 
   #(
      parameter DATA_WIDTH = 64,
      parameter CTRL_WIDTH = DATA_WIDTH/8,
      parameter UDP_REG_SRC_WIDTH = 2
   )
   (
      input  [DATA_WIDTH-1:0]             in_data,
      input  [CTRL_WIDTH-1:0]             in_ctrl,
      input                               in_wr,
      output                              in_rdy,

      output [DATA_WIDTH-1:0]             out_data,
      output [CTRL_WIDTH-1:0]             out_ctrl,
      output                              out_wr,
      input                               out_rdy,
      
      // --- Register interface
      // input                               reg_req_in,
      // input                               reg_ack_in,
      // input                               reg_rd_wr_L_in,
      // input  [`UDP_REG_ADDR_WIDTH-1:0]    reg_addr_in,
      // input  [`CPCI_NF2_DATA_WIDTH-1:0]   reg_data_in,
      // input  [UDP_REG_SRC_WIDTH-1:0]      reg_src_in,

      // output                              reg_req_out,
      // output                              reg_ack_out,
      // output                              reg_rd_wr_L_out,
      // output  [`UDP_REG_ADDR_WIDTH-1:0]   reg_addr_out,
      // output  [`CPCI_NF2_DATA_WIDTH-1:0]  reg_data_out,
      // output  [UDP_REG_SRC_WIDTH-1:0]     reg_src_out,

      // misc
      input                                reset,
      input                                clk,

      // new inputs
      input                                CPU_ctrl,
      input  [7:0]                         CPU_MEM_ADDR,
      input  [71:0]                        CPU_MEM_DATA,
      input                                CPU_MEM_WRITE,
      input  [7:0]                         head_addr,
      // new outputs
      output [7:0]                         tail_addr,
      output                               finish,
      output                               CPU_ack
   );

   // Define the log2 function
   // `LOG2_FUNC

   //------------------------- Signals-------------------------------
   
   wire [DATA_WIDTH-1:0]         in_fifo_data_p;
   wire [CTRL_WIDTH-1:0]         in_fifo_ctrl_p;
	
   reg [DATA_WIDTH-1:0]         in_fifo_data;
   reg [CTRL_WIDTH-1:0]         in_fifo_ctrl;

   wire                          in_fifo_nearly_full;
   wire                          in_fifo_empty;

   reg                           in_fifo_rd_en;
   reg                           out_wr_int;

   reg			         out_wr_int_next;

   // software registers 
   // wire [31:0]                   pattern_high;
   // wire [31:0]                   pattern_low;
   wire [31:0]                   ids_cmd;
   // hardware registers
   // reg [31:0]                    matches;

   // internal state
   reg [2:0]                     state, state_next;
   // reg [31:0]                    matches_next;
   reg                           in_pkt_body, in_pkt_body_next;
   reg                           end_of_pkt, end_of_pkt_next;
   reg                           begin_pkt, begin_pkt_next;
   reg [2:0]                     header_counter, header_counter_next;

   // local parameter
   parameter                     START = 3'b000;
   parameter                     HEADER = 3'b001;
   parameter                     PAYLOAD = 3'b010;
   parameter                     CPU     = 3'b011;
   parameter                     PULLBACK = 3'b100;
   // parameter                  EMPTY = 4'b0001;
   // parameter                  FILLING = 4'b0010;
   // parameter                  FULL = 4'b0100;
   // parameter                  DRAINING = 4'b1000;


   reg                           stall_fifo;
   reg                           stall_fifo_next;
   reg                           fifo_read_en;
 
   //------------------------- Local assignments -------------------------------

   assign in_rdy     = !in_fifo_nearly_full;
   assign CPU_ack    =  end_of_pkt;   //  this is the clk that all data is ready, and the input cpu_ctrl should be synounized
    
//   assign out_wr     = out_wr_int;
//   assign out_data   = in_fifo_data;
//   assign out_ctrl   = in_fifo_ctrl;
   // assign matcher_en = (!in_fifo_empty && out_rdy && in_pkt_body);
   // assign matcher_ce = (!in_fifo_empty && out_rdy);
   // assign matcher_reset = (reset || ids_cmd[0] || end_of_pkt);

   //------------------------- Modules-------------------------------

   fallthrough_small_fifo #(
      .WIDTH(CTRL_WIDTH+DATA_WIDTH),
      .MAX_DEPTH_BITS(2)
   ) input_fifo (
      .din           ({in_ctrl, in_data}),   // Data in
      .wr_en         (in_wr),                // Write enable
      .rd_en         (in_fifo_rd_en),        // Read the next word 
      .dout          ({in_fifo_ctrl_p, in_fifo_data_p}),
      .full          (),
      .nearly_full   (in_fifo_nearly_full),
      .empty         (in_fifo_empty),
      .reset         (reset),
      .clk           (clk)
   );

//    detect7B matcher (
//       .ce            (matcher_ce),           // data enable
//       .match_en      (matcher_en),           // match enable
//       .clk           (clk),
//       .pipe1         ({in_fifo_ctrl, in_fifo_data}),   // Data in
// //      .hwregA        ({pattern_high, pattern_low}),   // pattern in
//       .hwregA        (64'b0111111100000000000000000000000000000000000000000000000000000111),   // pattern in
//       .match         (matcher_match),        // match out
//       .mrst          (matcher_reset)         // reset in
   // );

   // dropfifo drop_fifo (
   //    .clk           (clk), 
   //    .drop_pkt      (matcher_match && end_of_pkt),    // why do we need to store the end of pkt addr?
   //    .fiforead      (out_rdy), 
   //    .fifowrite     (out_wr_int), 
   //    .firstword     (begin_pkt), 
   //    .in_fifo       ({in_fifo_ctrl,in_fifo_data}), 
   //    .lastword      (end_of_pkt), 
   //    .rst           (reset), 
   //    .out_fifo      ({out_ctrl,out_data}), 
   //    .valid_data    (out_wr)
   // );
   cvfifo cv_fifo (
      .CLK           (clk), 
      .fiforead      (fifo_read_en), 
      .fifowrite     (out_wr_int), 
      .firstword     (begin_pkt), 
      .in_fifo       ({in_fifo_ctrl,in_fifo_data}), 
      .lastword      (end_of_pkt), 
      .rst           (reset), 
      .out_fifo      ({out_ctrl,out_data}), 
      .valid_data    (out_wr),
      // new inputs
      .CPU_ctrl      (CPU_ctrl) ,
      .CPU_MEM_ADDR   (CPU_MEM_ADDR) ,
      .CPU_MEM_DATA   (CPU_MEM_DATA) ,
      .CPU_MEM_WRITE  (CPU_MEM_WRITE),
      .head_addr     (head_addr),
      // new outputs
      .tail_addr     (tail_addr),
      .finish        (finish)


   );

   // generic_regs
   // #( 
   //    .UDP_REG_SRC_WIDTH   (UDP_REG_SRC_WIDTH),
   //    .TAG                 (`IDS_BLOCK_TAG),          // Tag -- eg. MODULE_TAG
   //    .REG_ADDR_WIDTH      (`IDS_REG_ADDR_WIDTH),     // Width of block addresses -- eg. MODULE_REG_ADDR_WIDTH
   //    .NUM_COUNTERS        (0),                 // Number of counters
   //    .NUM_SOFTWARE_REGS   (3),                 // Number of sw regs
   //    .NUM_HARDWARE_REGS   (1)                  // Number of hw regs
   // ) module_regs (
   //    .reg_req_in       (reg_req_in),
   //    .reg_ack_in       (reg_ack_in),
   //    .reg_rd_wr_L_in   (reg_rd_wr_L_in),
   //    .reg_addr_in      (reg_addr_in),
   //    .reg_data_in      (reg_data_in),
   //    .reg_src_in       (reg_src_in),

   //    .reg_req_out      (reg_req_out),
   //    .reg_ack_out      (reg_ack_out),
   //    .reg_rd_wr_L_out  (reg_rd_wr_L_out),
   //    .reg_addr_out     (reg_addr_out),
   //    .reg_data_out     (reg_data_out),
   //    .reg_src_out      (reg_src_out),

   //    // --- counters interface
   //    .counter_updates  (),
   //    .counter_decrement(),

   //    // --- SW regs interface
   //    .software_regs    ({ids_cmd,pattern_low,pattern_high}),

   //    // --- HW regs interface
   //    .hardware_regs    (matches),

   //    .clk              (clk),
   //    .reset            (reset)
   //  );

   //------------------------- Logic-------------------------------
   
   always @(*) begin
      state_next = state;
      // matches_next = matches;
      header_counter_next = header_counter;
      in_fifo_rd_en = 0;
      fifo_read_en = 0;
      out_wr_int_next = 0;
      //out_data = 0;
      end_of_pkt_next = end_of_pkt;
      in_pkt_body_next = in_pkt_body;
      begin_pkt_next = begin_pkt;
      stall_fifo_next = stall_fifo;
      
      // if (out_rdy) begin  
         
      //    if (!stall_fifo) begin 
      //       out_wr_int_next = 1;
      //       in_fifo_rd_en = 1;
      //    end
      //    if(in_fifo_empty) begin
      //       stall_fifo_next = 1;
      //       in_fifo_rd_en = 0;
      //    end
         //out_data = in_fifo_data;
       if (!in_fifo_empty && out_rdy) begin        
         out_wr_int_next = 1;
         in_fifo_rd_en = 1;
       end

       if (stall_fifo) begin
          in_fifo_rd_en = 0;
          out_wr_int_next = 0;
       end
         
      case(state)
         START: begin
            if (in_fifo_ctrl_p != 0 && in_fifo_rd_en) begin
               state_next = HEADER;
               begin_pkt_next = 1;
               end_of_pkt_next = 0;   // takes matcher out of reset
            end
         end
         HEADER: begin
            begin_pkt_next = 0;
            if (in_fifo_ctrl_p == 0) begin
               header_counter_next = header_counter + 1'b1;
               if (header_counter_next == 3) begin
                  state_next = PAYLOAD;
               end
            end
         end
         PAYLOAD: begin
            if (in_fifo_ctrl_p != 0) begin    //trailer
               state_next = CPU;
               header_counter_next = 0;
               stall_fifo_next = 1;
                  // stall the fifo when we are in the CPU state, until we get the finish signal
               // if (matcher_match) begin
               //    matches_next = matches + 1;
               // end
               end_of_pkt_next = 1;   // will reset matcher
               in_pkt_body_next = 0;
            end
            else begin
               in_pkt_body_next = 1;
            end
         end
         CPU: begin
            end_of_pkt_next = 0;
            if (CPU_ctrl == 0 && CPU_ack == 0) begin
               state_next = PULLBACK;
            end
         end
         PULLBACK: begin
            fifo_read_en = 1;
            if (finish) begin
               state_next = START;
               stall_fifo_next = 0;
            end
         end
      endcase // case(state)
   end
    // always @ (*)
   
   always @(posedge clk) begin
      if(reset) begin
         // matches <= 0;
         header_counter <= 0;
         state <= START;
         begin_pkt <= 0;
         end_of_pkt <= 0;
         in_pkt_body <= 0;
			in_fifo_ctrl <= 0;
			in_fifo_data <= 0;
         stall_fifo <= 0;
      end
      else begin
         // if (ids_cmd[0]) matches <= 0;
         // else matches <= matches_next;
         header_counter <= header_counter_next;
         state <= state_next;
         begin_pkt <= begin_pkt_next;
         end_of_pkt <= end_of_pkt_next;
         in_pkt_body <= in_pkt_body_next;
			in_fifo_ctrl <= in_fifo_ctrl_p;
			in_fifo_data <= in_fifo_data_p;
			out_wr_int <= out_wr_int_next;
         stall_fifo <= stall_fifo_next;
      end // else: !if(reset)
   end // always @ (posedge clk)   

endmodule 
