`timescale 1ns/1ps
// =============================================================================
// GPU_interface.v
// Controls pipeline advance for two independent stall sources:
//
//   1. GPURUN   (gpu_st)  — set by GPURUN reaching EX (ex_gpu_start),
//                           cleared when gpu_done is asserted.
//
//   2. FIFOWAIT (fifo_st) — set by FIFOWAIT reaching EX (ex_fifowait_start),
//                           cleared when fifo_data_ready is asserted.
//
// advance is suppressed (0) whenever either stall is active, or when
// neither run nor step_pulse is asserted.
// Both stalls are mutually exclusive in normal use but the logic handles
// simultaneous assertion safely — both must individually clear.
// =============================================================================
module GPU_interface (
    input  wire clk,
    input  wire reset,
    input  wire pc_reset_pulse,
    input  wire run,
    input  wire step,

    // GPU stall ports
    input  wire ex_gpu_start,      // GPURUN has reached EX stage
    input  wire gpu_done,          // GPU kernel finished
    output wire gpu_run,           // 1 while GPU is executing
    output wire gpu_mem_access,    // same as gpu_run (DMEM arbitration)

    // FIFO stall ports
    input  wire ex_fifowait_start, // FIFOWAIT has reached EX stage
    input  wire fifo_data_ready,   // release condition for FIFOWAIT

    // Pipeline advance
    output reg  advance
);

    reg step_d;
    reg gpu_st;   // 1 while waiting for gpu_done
    reg fifo_st;  // 1 while waiting for fifo_data_ready

    always @(posedge clk) begin
        if (reset || pc_reset_pulse) begin
            step_d  <= 1'b0;
            gpu_st  <= 1'b0;
            fifo_st <= 1'b0;
        end else begin
            step_d <= step;

            // GPU stall: set on GPURUN in EX, clear when gpu_done
            if (ex_gpu_start)        gpu_st <= 1'b1;
            if (gpu_done && gpu_st)  gpu_st <= 1'b0;

            // FIFO stall: set on FIFOWAIT in EX, clear when fifo_data_ready
            if (ex_fifowait_start)            fifo_st <= 1'b1;
            if (fifo_data_ready && fifo_st)   fifo_st <= 1'b0;
        end
    end

    wire step_pulse   = step & ~step_d;

    assign gpu_run        = gpu_st;
    assign gpu_mem_access = gpu_st;

    // Advance when run or step_pulse, and no stall is active
    always @(*) begin
        advance = 1'b1;
        if (~(run || step_pulse)) advance = 1'b0;
        if (gpu_st)               advance = 1'b0;
        if (fifo_st)              advance = 1'b0;
    end

endmodule
