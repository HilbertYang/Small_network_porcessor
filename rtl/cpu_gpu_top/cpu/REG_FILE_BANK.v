module REG_FILE_BANK #(
    parameter data_width = 64, 
    parameter addr_width = 4,
    parameter th_id_width = 2
)(
    input clk, wena,
    input [th_id_width-1:0] rd_th_id, w_th_id, 
    input [addr_width-1:0] r0addr, r1addr, waddr, 
    input [data_width-1:0] wdata,
    output [data_width-1:0] r0data, r1data
);

    reg [data_width-1:0] regFile [0:(1 << th_id_width)-1][0:(1 << addr_width)-1];

    // --- Synchronous Write ---
    always @(posedge clk) begin
        if (wena && (waddr != 0))
            regFile[w_th_id][waddr] <= wdata;
    end

    // --- Forwarding Logic ---
    // We forward ONLY if:
    // 1. Write is enabled (wena)
    // 2. We are not writing to Register 0 (waddr != 0)
    // 3. The Write Thread matches the Read Thread
    // 4. The Write Address matches the Read Address
    
    wire forward0 = wena && (waddr != 0) && (w_th_id == rd_th_id) && (waddr == r0addr);
    wire forward1 = wena && (waddr != 0) && (w_th_id == rd_th_id) && (waddr == r1addr);

    // --- Asynchronous Read with Bypass Mux ---
    // Priority: Hardwired Zero > Write Forwarding > Memory Array
    assign r0data = (r0addr == 0) ? {data_width{1'b0}} : 
                    (forward0)    ? wdata : 
                                    regFile[rd_th_id][r0addr];

    assign r1data = (r1addr == 0) ? {data_width{1'b0}} : 
                    (forward1)    ? wdata : 
                                    regFile[rd_th_id][r1addr];

endmodule
