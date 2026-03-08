// regfile.v
// 16 × 64-bit register file for custom GPU
// R0 is hardwired to zero
// Supports synchronous write, asynchronous read
// Each 64-bit register is viewed as 4 × 16-bit lanes for SIMD ops
//
// Internal forwarding:
//   If a read port addresses the same register being written this cycle,
//   the write data is forwarded combinationally so the new value is
//   visible on the read port in the same clock cycle (write-before-read).
//   R0 forwarding is suppressed — R0 is always 0.

module regfile(
    input  wire        clk,
    input  wire        reset,
    // Read port A
    input  wire [3:0]  rs1_addr,
    output wire [63:0] rs1_data,
    // Read port B
    input  wire [3:0]  rs2_addr,
    output wire [63:0] rs2_data,
    // Read port C (for store source / MAC accumulator)
    input  wire [3:0]  rs3_addr,
    output wire [63:0] rs3_data,
    // Write port
    input  wire        wr_en,
    input  wire [3:0]  wr_addr,
    input  wire [63:0] wr_data
);

    reg [63:0] regs [0:15];

    // Forwarding condition:
    //   active write  AND  addresses match  AND  not R0
    wire fwd1 = wr_en && (wr_addr == rs1_addr) && (rs1_addr != 4'd0);
    wire fwd2 = wr_en && (wr_addr == rs2_addr) && (rs2_addr != 4'd0);
    wire fwd3 = wr_en && (wr_addr == rs3_addr) && (rs3_addr != 4'd0);

    integer i;
    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < 16; i = i + 1)
                regs[i] <= 64'd0;
        end else if (wr_en && wr_addr != 4'd0) begin
            regs[wr_addr] <= wr_data;
        end
    end

    // Async reads with forwarding; R0 always 0
    assign rs1_data = (rs1_addr == 4'd0) ? 64'd0 :
                      fwd1               ? wr_data : regs[rs1_addr];

    assign rs2_data = (rs2_addr == 4'd0) ? 64'd0 :
                      fwd2               ? wr_data : regs[rs2_addr];

    assign rs3_data = (rs3_addr == 4'd0) ? 64'd0 :
                      fwd3               ? wr_data : regs[rs3_addr];

endmodule