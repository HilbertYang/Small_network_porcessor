`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date:    18:25:18 03/07/2026 
// Design Name: 
// Module Name:    cpu_top_with_Mem 
// Project Name: 
// Target Devices: 
// Tool versions: 
// Description: 
//
// Dependencies: 
//
// Revision: 
// Revision 0.01 - File Created
// Additional Comments: 
//
//////////////////////////////////////////////////////////////////////////////////
module cpu_top_with_Mem(

  input  wire        clk,
  input  wire        reset,

  input  wire        run,
  input  wire        step,
  input  wire        pc_reset_pulse,

  input  wire        imem_prog_we,
  input  wire [8:0]  imem_prog_addr,
  input  wire [31:0] imem_prog_wdata,

  input  wire        dmem_prog_en,
  input  wire        dmem_prog_we,
  input  wire [7:0]  dmem_prog_addr,
  input  wire [63:0] dmem_prog_wdata,
  output wire [63:0] dmem_prog_rdata,

  output wire [8:0]  pc_dbg,
  output wire [31:0] if_instr_dbg,
  
  output wire gpu_run,
  input wire gpu_done,
  
  output wire gpu_mem_access,
  
  input wire [7:0] fifo_start_offset,
  input wire [7:0] fifo_end_offset,
  input wire fifo_data_ready
  
    );
	 
	 wire [7:0] cpu_dmem_addr;
	 wire [2:0] gpu_param_addr;
	 wire cpu_dmem_en, cpu_dmem_wen, gpu_param_wen;
	 wire [63:0] cpu_dmem_data_wr, cpu_dmem_data_rd, gpu_param_data;
	 wire fifo_data_done;

  D_M_64bit_256 u_dmem (
    .addra (cpu_dmem_addr),
    .clka  (clk),
    .ena   (cpu_dmem_en),
    .wea   (cpu_dmem_wen),
    .dina  (cpu_dmem_data_wr),
    .douta (cpu_dmem_data_rd),

    .addrb (dmem_prog_addr),
    .clkb  (clk),
    .enb   (dmem_prog_en),
    .web   (dmem_prog_we),
    .dinb  (dmem_prog_wdata),
    .doutb (dmem_prog_rdata)
  );

  cpu_mt cpu_mt_mt (
    .clk            (clk),
    .reset          (reset),
    .run            (run),
    .step           (step),
    .pc_reset_pulse (pc_reset_pulse),
    .imem_prog_we   (imem_prog_we),
    .imem_prog_addr (imem_prog_addr),
    .imem_prog_wdata(imem_prog_wdata),
	 
	 .cpu_dmem_addr(cpu_dmem_addr),
    .cpu_dmem_en(cpu_dmem_en),
    .cpu_dmem_wen(cpu_dmem_wen),
    .cpu_dmem_data_wr(cpu_dmem_data_wr),
    .cpu_dmem_data_rd(cpu_dmem_data_rd),
	 
    .pc_dbg         (pc_dbg),
    .if_instr_dbg   (if_instr_dbg),
	 
	  .gpu_run(gpu_run),
	  .gpu_done(gpu_done),
  
	   .gpu_mem_access(gpu_mem_access),
  
		.fifo_start_offset(fifo_start_offset),
		.fifo_end_offset(fifo_end_offset),
		.fifo_data_ready(fifo_data_ready),
		.fifo_data_done(fifo_data_done),
		
		.gpu_param_wr_en(gpu_param_wen),
		.gpu_param_wr_data(gpu_param_data),
		.gpu_param_wr_addr(gpu_param_addr)
  
  );

endmodule

