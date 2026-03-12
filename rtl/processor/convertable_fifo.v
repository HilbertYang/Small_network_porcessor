////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 1995-2008 Xilinx, Inc.  All rights reserved.
////////////////////////////////////////////////////////////////////////////////
//   ____  ____ 
//  /   /\/   / 
// /___/  \  /    Vendor: Xilinx 
// \   \   \/     Version : 10.1
//  \   \         Application : sch2verilog
//  /   /         Filename : convertable_fifo.vf
// /___/   /\     Timestamp : 03/12/2026 04:10:57
// \   \  /  \ 
//  \___\/\___\ 
//
//Command: C:\Xilinx\10.1\ISE\bin\nt\unwrapped\sch2verilog.exe -intstyle ise -family virtex2p -w C:/f8/f2/f3/convertable_fifo.sch convertable_fifo.vf
//Design Name: convertable_fifo
//Device: virtex2p
//Purpose:
//    This verilog netlist is translated from an ECS schematic.It can be 
//    synthesized and simulated, but it should not be modified. 
//
`timescale 1ns / 1ps

module M2_1_MXILINX_convertable_fifo(D0, 
                                     D1, 
                                     S0, 
                                     O);

    input D0;
    input D1;
    input S0;
   output O;
   
   wire M0;
   wire M1;
   
   AND2B1 I_36_7 (.I0(S0), 
                  .I1(D0), 
                  .O(M0));
   OR2 I_36_8 (.I0(M1), 
               .I1(M0), 
               .O(O));
   AND2 I_36_9 (.I0(D1), 
                .I1(S0), 
                .O(M1));
endmodule
`timescale 1ns / 1ps

module FTCLEX_MXILINX_convertable_fifo(C, 
                                       CE, 
                                       CLR, 
                                       D, 
                                       L, 
                                       T, 
                                       Q);

    input C;
    input CE;
    input CLR;
    input D;
    input L;
    input T;
   output Q;
   
   wire MD;
   wire TQ;
   wire Q_DUMMY;
   
   assign Q = Q_DUMMY;
   M2_1_MXILINX_convertable_fifo I_36_30 (.D0(TQ), 
                                          .D1(D), 
                                          .S0(L), 
                                          .O(MD));
   // synthesis attribute HU_SET of I_36_30 is "I_36_30_0"
   XOR2 I_36_32 (.I0(T), 
                 .I1(Q_DUMMY), 
                 .O(TQ));
   FDCE I_36_35 (.C(C), 
                 .CE(CE), 
                 .CLR(CLR), 
                 .D(MD), 
                 .Q(Q_DUMMY));
   // synthesis attribute RLOC of I_36_35 is "X0Y0"
   defparam I_36_35.INIT = 1'b0;
endmodule
`timescale 1ns / 1ps

module CB8CLE_MXILINX_convertable_fifo(C, 
                                       CE, 
                                       CLR, 
                                       D, 
                                       L, 
                                       CEO, 
                                       Q, 
                                       TC);

    input C;
    input CE;
    input CLR;
    input [7:0] D;
    input L;
   output CEO;
   output [7:0] Q;
   output TC;
   
   wire OR_CE_L;
   wire T2;
   wire T3;
   wire T4;
   wire T5;
   wire T6;
   wire T7;
   wire XLXN_1;
   wire [7:0] Q_DUMMY;
   wire TC_DUMMY;
   
   assign Q[7:0] = Q_DUMMY[7:0];
   assign TC = TC_DUMMY;
   FTCLEX_MXILINX_convertable_fifo I_Q0 (.C(C), 
                                         .CE(OR_CE_L), 
                                         .CLR(CLR), 
                                         .D(D[0]), 
                                         .L(L), 
                                         .T(XLXN_1), 
                                         .Q(Q_DUMMY[0]));
   // synthesis attribute HU_SET of I_Q0 is "I_Q0_1"
   FTCLEX_MXILINX_convertable_fifo I_Q1 (.C(C), 
                                         .CE(OR_CE_L), 
                                         .CLR(CLR), 
                                         .D(D[1]), 
                                         .L(L), 
                                         .T(Q_DUMMY[0]), 
                                         .Q(Q_DUMMY[1]));
   // synthesis attribute HU_SET of I_Q1 is "I_Q1_2"
   FTCLEX_MXILINX_convertable_fifo I_Q2 (.C(C), 
                                         .CE(OR_CE_L), 
                                         .CLR(CLR), 
                                         .D(D[2]), 
                                         .L(L), 
                                         .T(T2), 
                                         .Q(Q_DUMMY[2]));
   // synthesis attribute HU_SET of I_Q2 is "I_Q2_3"
   FTCLEX_MXILINX_convertable_fifo I_Q3 (.C(C), 
                                         .CE(OR_CE_L), 
                                         .CLR(CLR), 
                                         .D(D[3]), 
                                         .L(L), 
                                         .T(T3), 
                                         .Q(Q_DUMMY[3]));
   // synthesis attribute HU_SET of I_Q3 is "I_Q3_4"
   FTCLEX_MXILINX_convertable_fifo I_Q4 (.C(C), 
                                         .CE(OR_CE_L), 
                                         .CLR(CLR), 
                                         .D(D[4]), 
                                         .L(L), 
                                         .T(T4), 
                                         .Q(Q_DUMMY[4]));
   // synthesis attribute HU_SET of I_Q4 is "I_Q4_5"
   FTCLEX_MXILINX_convertable_fifo I_Q5 (.C(C), 
                                         .CE(OR_CE_L), 
                                         .CLR(CLR), 
                                         .D(D[5]), 
                                         .L(L), 
                                         .T(T5), 
                                         .Q(Q_DUMMY[5]));
   // synthesis attribute HU_SET of I_Q5 is "I_Q5_6"
   FTCLEX_MXILINX_convertable_fifo I_Q6 (.C(C), 
                                         .CE(OR_CE_L), 
                                         .CLR(CLR), 
                                         .D(D[6]), 
                                         .L(L), 
                                         .T(T6), 
                                         .Q(Q_DUMMY[6]));
   // synthesis attribute HU_SET of I_Q6 is "I_Q6_7"
   FTCLEX_MXILINX_convertable_fifo I_Q7 (.C(C), 
                                         .CE(OR_CE_L), 
                                         .CLR(CLR), 
                                         .D(D[7]), 
                                         .L(L), 
                                         .T(T7), 
                                         .Q(Q_DUMMY[7]));
   // synthesis attribute HU_SET of I_Q7 is "I_Q7_8"
   AND3 I_36_8 (.I0(Q_DUMMY[5]), 
                .I1(Q_DUMMY[4]), 
                .I2(T4), 
                .O(T6));
   AND2 I_36_11 (.I0(Q_DUMMY[4]), 
                 .I1(T4), 
                 .O(T5));
   VCC I_36_12 (.P(XLXN_1));
   AND2 I_36_19 (.I0(Q_DUMMY[1]), 
                 .I1(Q_DUMMY[0]), 
                 .O(T2));
   AND3 I_36_21 (.I0(Q_DUMMY[2]), 
                 .I1(Q_DUMMY[1]), 
                 .I2(Q_DUMMY[0]), 
                 .O(T3));
   AND4 I_36_23 (.I0(Q_DUMMY[3]), 
                 .I1(Q_DUMMY[2]), 
                 .I2(Q_DUMMY[1]), 
                 .I3(Q_DUMMY[0]), 
                 .O(T4));
   AND4 I_36_25 (.I0(Q_DUMMY[6]), 
                 .I1(Q_DUMMY[5]), 
                 .I2(Q_DUMMY[4]), 
                 .I3(T4), 
                 .O(T7));
   AND5 I_36_29 (.I0(Q_DUMMY[7]), 
                 .I1(Q_DUMMY[6]), 
                 .I2(Q_DUMMY[5]), 
                 .I3(Q_DUMMY[4]), 
                 .I4(T4), 
                 .O(TC_DUMMY));
   AND2 I_36_33 (.I0(CE), 
                 .I1(TC_DUMMY), 
                 .O(CEO));
   OR2 I_36_49 (.I0(CE), 
                .I1(L), 
                .O(OR_CE_L));
endmodule
`timescale 1ns / 1ps

module FD8CE_MXILINX_convertable_fifo(C, 
                                      CE, 
                                      CLR, 
                                      D, 
                                      Q);

    input C;
    input CE;
    input CLR;
    input [7:0] D;
   output [7:0] Q;
   
   
   FDCE I_Q0 (.C(C), 
              .CE(CE), 
              .CLR(CLR), 
              .D(D[0]), 
              .Q(Q[0]));
   defparam I_Q0.INIT = 1'b0;
   FDCE I_Q1 (.C(C), 
              .CE(CE), 
              .CLR(CLR), 
              .D(D[1]), 
              .Q(Q[1]));
   defparam I_Q1.INIT = 1'b0;
   FDCE I_Q2 (.C(C), 
              .CE(CE), 
              .CLR(CLR), 
              .D(D[2]), 
              .Q(Q[2]));
   defparam I_Q2.INIT = 1'b0;
   FDCE I_Q3 (.C(C), 
              .CE(CE), 
              .CLR(CLR), 
              .D(D[3]), 
              .Q(Q[3]));
   defparam I_Q3.INIT = 1'b0;
   FDCE I_Q4 (.C(C), 
              .CE(CE), 
              .CLR(CLR), 
              .D(D[4]), 
              .Q(Q[4]));
   defparam I_Q4.INIT = 1'b0;
   FDCE I_Q5 (.C(C), 
              .CE(CE), 
              .CLR(CLR), 
              .D(D[5]), 
              .Q(Q[5]));
   defparam I_Q5.INIT = 1'b0;
   FDCE I_Q6 (.C(C), 
              .CE(CE), 
              .CLR(CLR), 
              .D(D[6]), 
              .Q(Q[6]));
   defparam I_Q6.INIT = 1'b0;
   FDCE I_Q7 (.C(C), 
              .CE(CE), 
              .CLR(CLR), 
              .D(D[7]), 
              .Q(Q[7]));
   defparam I_Q7.INIT = 1'b0;
endmodule
`timescale 1ns / 1ps

module COMP8_MXILINX_convertable_fifo(A, 
                                      B, 
                                      EQ);

    input [7:0] A;
    input [7:0] B;
   output EQ;
   
   wire AB0;
   wire AB1;
   wire AB2;
   wire AB3;
   wire AB4;
   wire AB5;
   wire AB6;
   wire AB7;
   wire AB03;
   wire AB47;
   
   AND4 I_36_32 (.I0(AB7), 
                 .I1(AB6), 
                 .I2(AB5), 
                 .I3(AB4), 
                 .O(AB47));
   XNOR2 I_36_33 (.I0(B[6]), 
                  .I1(A[6]), 
                  .O(AB6));
   XNOR2 I_36_34 (.I0(B[7]), 
                  .I1(A[7]), 
                  .O(AB7));
   XNOR2 I_36_35 (.I0(B[5]), 
                  .I1(A[5]), 
                  .O(AB5));
   XNOR2 I_36_36 (.I0(B[4]), 
                  .I1(A[4]), 
                  .O(AB4));
   AND4 I_36_41 (.I0(AB3), 
                 .I1(AB2), 
                 .I2(AB1), 
                 .I3(AB0), 
                 .O(AB03));
   XNOR2 I_36_42 (.I0(B[2]), 
                  .I1(A[2]), 
                  .O(AB2));
   XNOR2 I_36_43 (.I0(B[3]), 
                  .I1(A[3]), 
                  .O(AB3));
   XNOR2 I_36_44 (.I0(B[1]), 
                  .I1(A[1]), 
                  .O(AB1));
   XNOR2 I_36_45 (.I0(B[0]), 
                  .I1(A[0]), 
                  .O(AB0));
   AND2 I_36_50 (.I0(AB47), 
                 .I1(AB03), 
                 .O(EQ));
endmodule
`timescale 1ns / 1ps

module convertable_fifo(CLK, 
                        CPU_ctrl, 
                        fiforead, 
                        fifowrite, 
                        firstword, 
                        head_addr, 
                        in_fifo, 
                        lastword, 
                        rst, 
                        fifo_raddr, 
                        fifo_waddr, 
                        fifo_word, 
                        fifo_writen, 
                        finish, 
                        tail_addr, 
                        valid_data);

    input CLK;
    input CPU_ctrl;
    input fiforead;
    input fifowrite;
    input firstword;
    input [7:0] head_addr;
    input [71:0] in_fifo;
    input lastword;
    input rst;
   output [7:0] fifo_raddr;
   output [7:0] fifo_waddr;
   output [71:0] fifo_word;
   output fifo_writen;
   output finish;
   output [7:0] tail_addr;
   output valid_data;
   
   wire xlx;
   wire XLXN_3;
   wire XLXN_4;
   wire XLXN_10;
   wire XLXN_73;
   wire XLXN_76;
   wire XLXN_77;
   wire XLXN_80;
   wire finish_DUMMY;
   wire [7:0] fifo_raddr_DUMMY;
   wire fifo_writen_DUMMY;
   wire [7:0] fifo_waddr_DUMMY;
   wire [7:0] tail_addr_DUMMY;
   
   assign fifo_raddr[7:0] = fifo_raddr_DUMMY[7:0];
   assign fifo_waddr[7:0] = fifo_waddr_DUMMY[7:0];
   assign fifo_writen = fifo_writen_DUMMY;
   assign finish = finish_DUMMY;
   assign tail_addr[7:0] = tail_addr_DUMMY[7:0];
   CB8CLE_MXILINX_convertable_fifo sendout_counter (.C(CLK), 
                                                    .CE(xlx), 
                                                    .CLR(rst), 
                                                    .D(head_addr[7:0]), 
                                                    .L(finish_DUMMY), 
                                                    .CEO(), 
                                                    .Q(fifo_raddr_DUMMY[7:0]), 
                                                    .TC());
   // synthesis attribute HU_SET of sendout_counter is "sendout_counter_12"
   CB8CLE_MXILINX_convertable_fifo store_counter (.C(CLK), 
                                                  .CE(fifo_writen_DUMMY), 
                                                  .CLR(rst), 
                                                  .D(head_addr[7:0]), 
                                                  .L(CPU_ctrl), 
                                                  .CEO(), 
                                                  .Q(fifo_waddr_DUMMY[7:0]), 
                                                  .TC());
   // synthesis attribute HU_SET of store_counter is "store_counter_9"
   FD8CE_MXILINX_convertable_fifo tailer_reg (.C(CLK), 
                                              .CE(XLXN_77), 
                                              .CLR(rst), 
                                              .D(fifo_waddr_DUMMY[7:0]), 
                                              .Q(tail_addr_DUMMY[7:0]));
   // synthesis attribute HU_SET of tailer_reg is "tailer_reg_11"
   FD XLXI_1 (.C(CLK), 
              .D(firstword), 
              .Q(XLXN_3));
   defparam XLXI_1.INIT = 1'b0;
   FD XLXI_2 (.C(CLK), 
              .D(lastword), 
              .Q(XLXN_4));
   defparam XLXI_2.INIT = 1'b0;
   FD XLXI_3 (.C(CLK), 
              .D(fifowrite), 
              .Q(fifo_writen_DUMMY));
   defparam XLXI_3.INIT = 1'b0;
   OR2 XLXI_4 (.I0(XLXN_4), 
               .I1(XLXN_3), 
               .O(XLXN_80));
   COMP8_MXILINX_convertable_fifo XLXI_5 (.A(fifo_raddr_DUMMY[7:0]), 
                                          .B(tail_addr_DUMMY[7:0]), 
                                          .EQ(finish_DUMMY));
   // synthesis attribute HU_SET of XLXI_5 is "XLXI_5_10"
   VCC XLXI_7 (.P(XLXN_10));
   AND2B1 XLXI_11 (.I0(CPU_ctrl), 
                   .I1(fiforead),  
                   .O(xlx));
   FDC XLXI_14 (.C(CLK), 
                .CLR(rst), 
                .D(xlx), 
                .Q(valid_data));
   defparam XLXI_14.INIT = 1'b0;
   FD XLXI_28 (.C(CLK), 
               .D(XLXN_80), 
               .Q(XLXN_73));
   defparam XLXI_28.INIT = 1'b0;
   INV XLXI_29 (.I(XLXN_73), 
                .O(XLXN_76));
   AND2 XLXI_30 (.I0(XLXN_76), 
                 .I1(XLXN_80), 
                 .O(XLXN_77));
   reg9B XLXI_31 (.CE(XLXN_10), 
                  .CLK(CLK), 
                  .CLR(rst), 
                  .d(in_fifo[71:0]), 
                  .q(fifo_word[71:0]));
endmodule
