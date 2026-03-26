///////////////////////////////////////////////////////////////////////////////
// vim:set shiftwidth=3 softtabstop=3 expandtab:
// Module: ids_sim.v
// Project: NF2.1
// Description: Packet FIFO front-end used in the user data path.
///////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps

module ids_fifo #(
   parameter DATA_WIDTH = 64,
   parameter CTRL_WIDTH = DATA_WIDTH/8,
   parameter UDP_REG_SRC_WIDTH = 2
) (
   input  [DATA_WIDTH-1:0] in_data,
   input  [CTRL_WIDTH-1:0] in_ctrl,
   input                   in_wr,
   output                  in_rdy,

   output [DATA_WIDTH-1:0] out_data,
   output [CTRL_WIDTH-1:0] out_ctrl,
   output                  out_wr,
   input                   out_rdy,

   input                   reset,
   input                   clk,

   input                   CPU_ctrl,
   input  [7:0]            head_addr,
   input  [71:0]           mem_ids_word,
   output [7:0]            tail_addr,
   output                  finish,
   output                  CPU_START,

   output [7:0]            ids_mem_addr,
   output                  ids_mem_wen,
   output [71:0]           ids_mem_word,
   output [7:0]             payload_header_addr
);

   //------------------------- Signals -------------------------------

   wire [DATA_WIDTH-1:0] in_fifo_data_p;
   wire [CTRL_WIDTH-1:0] in_fifo_ctrl_p;

   reg [DATA_WIDTH-1:0] in_fifo_data;
   reg [CTRL_WIDTH-1:0] in_fifo_ctrl;

   wire in_fifo_nearly_full;
   wire in_fifo_empty;

   reg in_fifo_rd_en;
   reg out_wr_int;
   reg out_wr_int_next;

   reg [2:0] state;
   reg [2:0] state_next;
   reg       in_pkt_body;
   reg       in_pkt_body_next;
   reg       end_of_pkt;
   reg       end_of_pkt_next;
   reg       begin_pkt;
   reg       begin_pkt_next;
   reg [2:0] header_counter;
   reg [2:0] header_counter_next;

   parameter START    = 3'b000;
   parameter HEADER   = 3'b001;
   parameter PAYLOAD  = 3'b010;
   parameter CPU      = 3'b011;
   parameter PULLBACK = 3'b100;

   reg        stall_fifo;
   reg        stall_fifo_next;
   reg        fifo_read_en;
   wire [7:0] ids_mem_waddr;
   wire [7:0] ids_mem_raddr;
   wire [7:0] udp_payload_offset;

   //------------------------- Local assignments -------------------------------

   assign in_rdy       = !in_fifo_nearly_full;
   assign CPU_START    = end_of_pkt;
   assign {out_ctrl, out_data} = mem_ids_word;
   assign ids_mem_addr = ids_mem_wen ? ids_mem_waddr : ids_mem_raddr;
   assign udp_payload_offset = 8'h07; // UDP header is 12 bytes long
   assign payload_header_addr = head_addr + udp_payload_offset;

   //------------------------- Modules -------------------------------

   fallthrough_small_fifo #(
      .WIDTH(CTRL_WIDTH + DATA_WIDTH),
      .MAX_DEPTH_BITS(2)
   ) input_fifo (
      .din         ({in_ctrl, in_data}),
      .wr_en       (in_wr),
      .rd_en       (in_fifo_rd_en),
      .dout        ({in_fifo_ctrl_p, in_fifo_data_p}),
      .full        (),
      .nearly_full (in_fifo_nearly_full),
      .empty       (in_fifo_empty),
      .reset       (reset),
      .clk         (clk)
   );

   convertable_fifo cv_fifo (
      .CLK        (clk),
      .fiforead   (fifo_read_en),
      .fifowrite  (out_wr_int),
      .firstword  (begin_pkt),
      .in_fifo    ({in_fifo_ctrl, in_fifo_data}),
      .lastword   (end_of_pkt),
      .rst        (reset),
      .valid_data (out_wr),
      .CPU_ctrl   (CPU_ctrl),
      .head_addr  (head_addr),
      .tail_addr  (tail_addr),
      .finish     (finish),
      .fifo_word  (ids_mem_word),
      .fifo_writen(ids_mem_wen),
      .fifo_waddr (ids_mem_waddr),
      .fifo_raddr (ids_mem_raddr)
   );

   //------------------------- Logic -------------------------------

   always @(*) begin
      state_next          = state;
      header_counter_next = header_counter;
      in_fifo_rd_en       = 0;
      fifo_read_en        = 0;
      out_wr_int_next     = 0;
      end_of_pkt_next     = end_of_pkt;
      in_pkt_body_next    = in_pkt_body;
      begin_pkt_next      = begin_pkt;
      stall_fifo_next     = stall_fifo;

      if (!in_fifo_empty && out_rdy) begin
         out_wr_int_next = 1;
         in_fifo_rd_en   = 1;
      end

      if (stall_fifo) begin
         in_fifo_rd_en   = 0;
         out_wr_int_next = 0;
      end

      case (state)
         START: begin
            if (in_fifo_ctrl_p != 0 && in_fifo_rd_en) begin
               state_next      = HEADER;
               begin_pkt_next  = 1;
               end_of_pkt_next = 0;
            end
         end

         HEADER: begin
            begin_pkt_next = 0;
            if (in_fifo_ctrl_p == 0) begin
               header_counter_next = header_counter + 1'b1;
               if (header_counter_next == 6) begin
                  state_next = PAYLOAD;
               end
            end
         end

         PAYLOAD: begin
            header_counter_next = 0;
            if (in_fifo_ctrl_p != 0) begin
               state_next      = CPU;
               stall_fifo_next = 1;
               end_of_pkt_next = 1;
               in_pkt_body_next = 0;
            end else begin
               in_pkt_body_next = 1;
            end
         end

         CPU: begin
            end_of_pkt_next = 0;
            if (CPU_ctrl == 1) begin
               state_next = PULLBACK;
            end
         end

         PULLBACK: begin
            fifo_read_en = 1;
            if (finish) begin
               state_next      = START;
               stall_fifo_next = 0;
            end
         end
      endcase
   end

   always @(posedge clk) begin
      if (reset) begin
         header_counter <= 0;
         state          <= START;
         begin_pkt      <= 0;
         end_of_pkt     <= 0;
         in_pkt_body    <= 0;
         in_fifo_ctrl   <= 0;
         in_fifo_data   <= 0;
         stall_fifo     <= 0;
      end else begin
         header_counter <= header_counter_next;
         state          <= state_next;
         begin_pkt      <= begin_pkt_next;
         end_of_pkt     <= end_of_pkt_next;
         in_pkt_body    <= in_pkt_body_next;
         in_fifo_ctrl   <= in_fifo_ctrl_p;
         in_fifo_data   <= in_fifo_data_p;
         out_wr_int     <= out_wr_int_next;
         stall_fifo     <= stall_fifo_next;
      end
   end

endmodule
