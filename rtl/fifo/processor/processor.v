`include "timescale.vh"

// `define UDP_REG_ADDR_WIDTH 16
// `define CPCI_NF2_DATA_WIDTH 16
// `define IDS_BLOCK_TAG 1
// `define IDS_REG_ADDR_WIDTH 16

module top_processor_system #(
      parameter DATA_WIDTH = 64,
      parameter CTRL_WIDTH = DATA_WIDTH/8,
      parameter UDP_REG_SRC_WIDTH = 2
   )
   (
    input clk,
    input reset,
    
    // external 
    input  [63:0] in_data,
    input  [7:0]  in_ctrl,
    input         in_wr,
    output        in_rdy,
    
    output [63:0] out_data,
    output [7:0]  out_ctrl,
    output        out_wr,
    input         out_rdy,


     // --- Register interface
      input                               reg_req_in,
      input                               reg_ack_in,
      input                               reg_rd_wr_L_in,
      input  [`UDP_REG_ADDR_WIDTH-1:0]    reg_addr_in,
      input  [`CPCI_NF2_DATA_WIDTH-1:0]   reg_data_in,
      input  [UDP_REG_SRC_WIDTH-1:0]      reg_src_in,

      output                              reg_req_out,
      output                              reg_ack_out,
      output                              reg_rd_wr_L_out,
      output  [`UDP_REG_ADDR_WIDTH-1:0]   reg_addr_out,
      output  [`CPCI_NF2_DATA_WIDTH-1:0]  reg_data_out,
      output  [UDP_REG_SRC_WIDTH-1:0]     reg_src_out
);

 


    //singals for sharedmem
    //port A:
    wire [7:0]      ids_mem_addr;
    wire [71:0]     ids_mem_word;
    wire            ids_mem_wen;
    wire [71:0]     mem_ids_word;

    

    // Signals for ids_ff
    wire        cpu_start;      // Signals end of packet 
    wire [7:0]  tail_addr;    // End of data boundary 
    wire [7:0]  head_addr ; 
    wire         finish;

    assign head_addr = 8'h00; // Start of data boundary, fixed at 0 for simplicity


    //signals for CPU logic
    //please modify this part!!!
    wire       cpu_ctrl; // Single control signal for CPU operation, from software reg
    wire [71:0]      mem_cpu_word;
    wire [71:0]     cpu_mem_word;
    wire [63:0]      mem_cpu_data;
    wire [63:0]      cpu_mem_data;   
    wire [7:0]      cpu_mem_addr;
    wire [7:0]      end_addr; // Tail address from ids_ff, indicating end of data
	 wire [7:0]      mem_ctrl;

    reg            cpu_mem_write;

    assign {mem_ctrl, mem_cpu_data }= mem_cpu_word; 
    assign cpu_mem_word = {mem_ctrl , cpu_mem_data}; // Data to write to memory, from CPU logic
    assign end_addr = tail_addr; // Tail address from ids_ff, indicating end of data


    //signals for gpu logic
    //please modify this part!!!




    // other defaults
    reg  [7:0]  header_offset = 8'h07;

     // interface check!
    //=========================================================================================================================
    //=========================================================================================================================
    //=========================================================================================================================
    //=========================================================================================================================
    //=========================================================================================================================
   
    wire [31:0] sw_ctrl;
    wire [31:0] sw_dmem_addr;
    wire [2*32-1:0] software_regs_bus;

    assign sw_ctrl    = software_regs_bus[ 31:  0];  // addr 0
    assign sw_dmem_addr      = software_regs_bus[ 63: 32];  // addr 1

    // //===================HW REGS===================
    wire [31:0] data_high;
    wire [31:0] data_low;
    wire [31:0] data_ctrl;
    wire [3*32-1:0] hardware_regs_bus;

    assign hardware_regs_bus = {data_ctrl,   // addr 2
                                data_high,   // addr 1
                                data_low};   // addr 0

    //=========================================================================================================================
    //=========================================================================================================================
    //=========================================================================================================================
    //=========================================================================================================================
    //=========================================================================================================================







    // shared memory instance
    SMem sharedmem(
        .addra      (ids_mem_addr),
        .clka       (clk),
        .dina       (ids_mem_word),
        .douta      (mem_ids_word),
        .wea        (ids_mem_wen),
    // please modify this part!!!
        .addrb      (cpu_mem_addr),
        .clkb       (clk),
        .dinb       (cpu_mem_word),
        .doutb      (mem_cpu_word),
        .web        (cpu_mem_write)
    );


    //ids_fifo instance

    ids_fifo ids_fifo_inst (
    .clk             (clk),
    .reset           (reset),
    .in_data         (in_data),
    .in_ctrl         (in_ctrl),
    .in_wr           (in_wr),
    .in_rdy          (in_rdy),
    .out_data        (out_data),
    .out_ctrl        (out_ctrl),
    .out_wr          (out_wr),
    .out_rdy         (out_rdy),

    .CPU_ctrl        (cpu_ctrl), // Single control signal, from CPU
    .head_addr       (head_addr),
    .tail_addr       (tail_addr),
    .finish          (finish),
    .CPU_START         (cpu_start),            // Handshake

    // Memory interface
    .mem_ids_word     (mem_ids_word),
    .ids_mem_word     (ids_mem_word),
    .ids_mem_addr     (ids_mem_addr),
    .ids_mem_wen      (ids_mem_wen)
);
    

    // CPU instance
    // access to memery: 
    // mem_cpu_data: data read from memory, input to CPU logic
    // cpu_mem_data: data to write to memory, output from CPU logic
    // cpu_mem_addr: address for memory access, output from CPU logic
    // cpu_write_en: write enable signal for memory access, output from CPU logic
    // control signal:  
    // cpu_ctrl: control signal for CPU operation, currently 1 for cpu is taking over, 0 for idle
    // cpu_start: signal from ids_fifo to indicate start of CPU processing, input to CPU logic
    //
    // Please implement your CPU logic here.
    //=========================================================================================================================
    //=========================================================================================================================
    //=========================================================================================================================
    //=========================================================================================================================
    //=========================================================================================================================

    reg         cpu_working;
	 reg         cpu_working_next;
	 reg         cpu_working_next_next;
    reg  [7:0]  cpu_addr_cnt;
    
    wire         cpu_done_next;
    reg         cpu_done;

    wire [63:0] cpu_data_out;
	 
	//  assign sw_ctrl = 0;

    assign cpu_ctrl = sw_ctrl[0] | cpu_working; // Combined control signal for CPU operation
    assign cpu_mem_addr = sw_ctrl[0]? sw_dmem_addr[7:0]:( cpu_addr_cnt + header_offset); // Address from counter
    assign cpu_done_next = (cpu_mem_addr == end_addr); // Done when address reaches tail
   // assign sw_dmem_addr[7:0] = cpu_mem_addr; 
    assign data_ctrl[7:0] = mem_cpu_word[71:64]; // Control data for hardware reg
    assign data_high = mem_cpu_word[63:32]; // High 32 bits of data for hardware reg
    assign data_low = mem_cpu_word[31:0]; // Low 32 bits of    

    wire [63:0] cpu_data_in  = mem_cpu_data; // Data read from memory, to be processed by CPU logic
    assign cpu_data_out = cpu_data_in + 64'h0000000000000001; 
	 assign cpu_mem_data = cpu_data_out;
   
    
	 
    always @(posedge clk) begin
	     
        cpu_done <= cpu_done_next;
		  
        if (reset) begin
            cpu_working <= 0;
            cpu_addr_cnt <= 0;
            cpu_mem_write <= 0;
        end  else if (cpu_done) begin
            cpu_working <= 0; 
            cpu_addr_cnt <= 0; 
            cpu_mem_write <= 0;
        end else if (cpu_working) begin
            //read and write, 2 cycles per word
            if (cpu_mem_write == 0 ) begin
                cpu_mem_write <= 1; // Write during processing
              //  cpu_data_out <= cpu_data_in ; // Increment data
            end else begin
                 cpu_mem_write <= 0; // Write during processing
                 cpu_addr_cnt <= cpu_addr_cnt + 1; // Increment address counter
            end
        end else if (cpu_start) begin
            cpu_working <= 1;             
        end
        
    end

    //=========================================================================================================================
    //=========================================================================================================================
    //=========================================================================================================================
    //=========================================================================================================================
    //=========================================================================================================================


    // GPU instance
    // Please implement your GPU logic here, and connect it to the shared memory and hardware registers as needed.
    //=========================================================================================================================
    //=========================================================================================================================
    //=========================================================================================================================
    //=========================================================================================================================
    //=========================================================================================================================

    //gpu

    //=========================================================================================================================
    //=========================================================================================================================
    //=========================================================================================================================
    //=========================================================================================================================
    //=========================================================================================================================




    // interface registers instance

    generic_regs
   #( 
      .UDP_REG_SRC_WIDTH   (UDP_REG_SRC_WIDTH),
      .TAG                 (`IDS_BLOCK_ADDR),          // Tag -- eg. MODULE_TAG
      .REG_ADDR_WIDTH      (`IDS_REG_ADDR_WIDTH),     // Width of block addresses -- eg. MODULE_REG_ADDR_WIDTH
      .NUM_COUNTERS        (0),                 // Number of counters
      .NUM_SOFTWARE_REGS   (2),                 // Number of sw regs
      .NUM_HARDWARE_REGS   (3)                  // Number of hw regs
   ) module_regs (
      .reg_req_in       (reg_req_in),
      .reg_ack_in       (reg_ack_in),
      .reg_rd_wr_L_in   (reg_rd_wr_L_in),
      .reg_addr_in      (reg_addr_in),
      .reg_data_in      (reg_data_in),
      .reg_src_in       (reg_src_in),

      .reg_req_out      (reg_req_out),
      .reg_ack_out      (reg_ack_out),
      .reg_rd_wr_L_out  (reg_rd_wr_L_out),
      .reg_addr_out     (reg_addr_out),
      .reg_data_out     (reg_data_out),
      .reg_src_out      (reg_src_out),

      // --- counters interface
      .counter_updates  (),
      .counter_decrement(),

      // --- SW regs interface
      .software_regs    (software_regs_bus),

      // --- HW regs interface
      .hardware_regs    (hardware_regs_bus),

      .clk              (clk),
      .reset            (reset)
    );






endmodule
