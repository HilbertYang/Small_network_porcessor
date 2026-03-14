`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date:    15:53:20 03/09/2026 
// Design Name: 
// Module Name:    GPU_interface 
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
module GPU_interface (
    input clk,
    input reset,
	 input pc_reset_pulse,
	 input run,
    input step,
    input ex_gpu_start,
    input gpu_done,
    output gpu_run,
	 output gpu_mem_access,
    output reg advance
    );
    reg step_d, gpu_st;

    always @(posedge clk) begin
        if (reset || pc_reset_pulse) step_d <= 1'b0;
        else                         step_d <= step;
       
        if (reset || pc_reset_pulse) gpu_st <= 1'b0;
        else begin
            if (ex_gpu_start) gpu_st <= 1'b1;
            if (gpu_done && gpu_st) gpu_st <= 1'b0;
        end
    end
    wire step_pulse = step & ~step_d;
    assign gpu_run = gpu_st;
	 assign gpu_mem_access = gpu_run;
    //assign advance    = run || step_pulse || ~(gpu_st);
	 
	 always @(*) begin
	   advance = 1'b1;
		if (~(run || step_pulse)) begin advance = 1'b0; end
		if (gpu_st) begin advance = 1'b0; end
	 
	 end


endmodule
