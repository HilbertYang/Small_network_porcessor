// param_regs.v
// Kernel parameter registers
// Stores up to 8 Ã 64-bit parameters loaded before kernel launch
// Maps to PTX: ld.param.u64 %rd1, [kernel_param_0]
//              ld.param.u32 %r2,  [kernel_param_3]
//
// Internal forwarding:
//   If the read address matches the write address in the same cycle
//   and wr_en is asserted, wr_data is forwarded directly to rd_data
//   without waiting for the register array to be updated.

module param_regs(
    input  wire        clk,
    input  wire        reset,
    // Write interface (from host/ARM before kernel launch)
    input  wire        wr_en,
    input  wire [3:0]  wr_addr,   // param index 0-7
    input  wire [63:0] wr_data,
    // Read interface (from GPU decode stage)
    input  wire [3:0]  rd_addr,
    output wire [63:0] rd_data
);

    reg [63:0] params [0:15];

    // Forwarding: same-cycle write to same address
    wire fwd = wr_en && (wr_addr == rd_addr);

    integer i;
    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < 16; i = i + 1)
                params[i] <= 64'd0;
        end else if (wr_en) begin
            params[wr_addr] <= wr_data;
        end
    end

    assign rd_data = fwd ? wr_data : params[rd_addr];

endmodule
