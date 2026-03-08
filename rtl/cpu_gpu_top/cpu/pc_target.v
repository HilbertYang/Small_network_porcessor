`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date:    12:24:32 02/28/2026 
// Design Name: 
// Module Name:    pc_target 
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
module pc_target( 
	input advance,
	input pc_reset_pulse,
	input clk,
	input reset,
	input ex_branch_taken,
	input [8:0] ex_branch_target,
	input [1:0] ex_thread_id,
	output reg [8:0] pc_target,
	output reg [1:0] thread_id
    );
	 
	 reg [6:0] pc0, pc1, pc2, pc3;
	 //reg [1:0] thread_id;
	 always @(*) begin
		case (thread_id)
				2'b00 : pc_target = {2'b00, pc0};
				2'b01 : pc_target = {2'b01, pc1};
				2'b10 : pc_target = {2'b10, pc2};
				2'b11 : pc_target = {2'b11, pc3};
				default : pc_target = {2'b00, pc0};
		endcase
	 end
	 always @(posedge clk) begin
		if  (reset || pc_reset_pulse) begin 
			pc0 <= 7'b0000000;
			pc1 <= 7'b0000000;
			pc2 <= 7'b0000000;
			pc3 <= 7'b0000000;
			thread_id <= 2'b00;
		end
		else if (advance) begin
			thread_id <= thread_id + 2'b01;
			
			case (thread_id)
				2'b00 : pc0 <= pc0 + 1'b1;
				2'b01 : pc1 <= pc1 + 1'b1;
				2'b10 : pc2 <= pc2 + 1'b1;
				2'b11 : pc3 <= pc3 + 1'b1;
			endcase
			if (ex_branch_taken) begin
				case (ex_thread_id)
					2'b00 : pc0 <= ex_branch_target[6:0];
					2'b01 : pc1 <= ex_branch_target[6:0];
					2'b10 : pc2 <= ex_branch_target[6:0];
					2'b11 : pc3 <= ex_branch_target[6:0];
			endcase
			end

			
		end
	end
			
			

endmodule
