// gpu_core.v
// 5-Stage Pipelined GPU Core
//
// Pipeline: IF -> ID -> EX -> MEM -> WB
//
// Instruction Memory: I_M_32bit_512depth (32-bit wide, 512 deep)
// Data Memory:        D_M_64bit_256      (64-bit wide, 256 deep)
// Regfile    :        regfile            (64-bit wide, 16 deep )
// Paramreg    :       param_regs         (64-bit wide, 8 deep  )
//
// Thread Model:
//   - TID register starts at 0, increments by 4 each iteration
//   - 4 lanes of 16-bit data packed in one 64-bit register
//   - 64-bit load/store address uses word offset = TID/4
//     (since each 64-bit word contains 4 × i16 elements)
//
// ISA (5-bit opcode, 32-bit instruction):
//   [31:27]=OPCODE [26:23]=RD [22:19]=RS1 [18:15]=RS2 [14:0]=IMM15
//
// Opcodes:
//   NOP      = 5'h00
//   ADD_I16  = 5'h01  RD[4xi16] = RS1[4xi16] + RS2[4xi16]
//   SUB_I16  = 5'h02  RD[4xi16] = RS1[4xi16] - RS2[4xi16]
//   MAX_I16  = 5'h03  RD[4xi16] = max(RS1[4xi16], RS2[4xi16])
//   ADD64    = 5'h04  RD = RS1 + RS2 (64-bit)
//   ADDI64   = 5'h05  RD = RS1 + sign_ext(imm15)
//   SETP_GE  = 5'h06  PRED = (RS1[31:0] >= RS2[31:0])
//   SHIFTL16 = 5'h07  RD = RS1 << 16  (fixed 16-bit left shift)
//   SHIFTR16 = 5'h08  RD = RS1 >> 16  (fixed 16-bit logical right shift)
//   MAC_BF16 = 5'h09  RD[4xbf16] = RS1 * RS2 + RS3(=RD)
//   MUL_BF16 = 5'h0a  RD[4xbf16] = RS1 * RS2
//   LD64     = 5'h10  RD = DMEM[RS1 + imm15]
//   ST64     = 5'h11  DMEM[RS1 + imm15] = RD
//   MOV      = 5'h12  RD = signed extend(imm15)
//   BPR      = 5'h13  if PRED: PC = imm15[8:0]
//   BR       = 5'h14  Directly jump to pc = imm15[8:0]
//   RET      = 5'h15  halt
//   LD_PARAM = 5'h16  RD = PARAM[imm3]
`timescale 1ns/1ps
module gpu_core (
    input  wire        clk,
    input  wire        reset,

    input  wire        run,           
    input  wire        step,          
    input  wire        pc_reset, 
    output wire        done,

   //param_interface
    input  wire        param_wr_en,
    input  wire [2:0]  param_wr_addr,
    input  wire [63:0] param_wr_data,

    //I-mem programming interface
    input  wire        imem_prog_we,
    input  wire [8:0]  imem_prog_addr,
    input  wire [31:0] imem_prog_wdata,

    // External DMEM port (Port B of shared BRAM in cpu_gpu_top)
    output wire [7:0]  dmem_addr,   // MEM-stage address
    output wire        dmem_en,     // access enable
    output wire        dmem_we,     // write enable
    output wire [63:0] dmem_din,    // write data (from RS3/RD)
    input  wire [63:0] dmem_dout,   // read data  (to WB)

    output wire [8:0]  pc_dbg,
    output wire [31:0] if_instr_dbg
);
    //=========================================================
    // Opcode definitions
    //=========================================================
    localparam OP_NOP      = 5'h00;
    localparam OP_ADD_I16  = 5'h01;
    localparam OP_SUB_I16  = 5'h02;
    localparam OP_MAX_I16  = 5'h03;
    localparam OP_ADD64    = 5'h04;
    localparam OP_ADDI64   = 5'h05;
    localparam OP_SETP_GE  = 5'h06;
    localparam OP_SHIFTL16 = 5'h07;
    localparam OP_SHIFTR16 = 5'h08;
    localparam OP_MAC_BF16 = 5'h09;
    localparam OP_MUL_BF16 = 5'h0a;
    localparam OP_LD64     = 5'h10;
    localparam OP_ST64     = 5'h11;
    localparam OP_MOV      = 5'h12;
    localparam OP_BPR      = 5'h13;
    localparam OP_BR       = 5'h14;
    localparam OP_RET      = 5'h15;
    localparam OP_LD_PARAM = 5'h16;

    //==========================================================
    // Pipeline control signal
    //==========================================================
    reg step_d;

    always @(posedge clk) begin
        if (reset || pc_reset) begin
            step_d <= 1'b0;
        end else begin       
            step_d <= step;
        end
    end
    
    wire step_pulse  = step & ~step_d; // Step pulse is generated when step goes from 0 to 1
    wire pre_advance = run | step_pulse;

    // TC stall: hold pipeline for TC_LATENCY cycles after TC enters EX,
    // giving the free-running 2-stage TC pipeline time to produce its result.
    localparam TC_LATENCY = 6;
    reg        tc_active;
    reg [2:0]  tc_counter;  // must be wide enough to hold TC_LATENCY-1

    wire        id_use_tc;
    always @(posedge clk) begin
        if (reset || pc_reset) begin
            tc_active  <= 1'b0;
            tc_counter <= 2'd0;
        end else if (id_use_tc & pre_advance & ~tc_active) begin
            // TC instruction transitioning ID→EX: start stall counter
            tc_active  <= 1'b1;
            tc_counter <= TC_LATENCY - 1;   // counts TC_LATENCY-1 -> 0
        end else if (tc_active & pre_advance) begin
            if (tc_counter == 0)
                tc_active <= 1'b0;          // release stall
            else
                tc_counter <= tc_counter - 1;
        end
    end

    wire tc_stall = tc_active;
    wire advance  = pre_advance & ~tc_stall;

    reg  [8:0]  pc; 
    assign      pc_dbg = pc;
    wire        branch_taken;
    wire [8:0]  branch_target;
    wire [8:0]  pc_next;
    assign      pc_next = branch_taken ? branch_target : pc + 9'd1;

    //pc update
    always @(posedge clk) begin
        if (reset || pc_reset) begin
            pc <= 9'd0;
        end else if (advance) begin
            pc <= pc_next;
        end
    end
    
    reg        memwb_is_ret;
    assign done = memwb_is_ret;

    //==========================================================
    // IF stage
    //==========================================================

    // I-mem instance with programming interface
    wire [8:0]  imem_addr_mux = imem_prog_we ? imem_prog_addr : pc;
    wire [31:0] imem_din_mux  = imem_prog_wdata;
    wire        imem_we_mux   = imem_prog_we;
    wire [31:0] imem_dout;
  
    //----------------------------------------------------------------------------------
    // Instruction Memory: 512x32-bit, single port, with separate programming interface
    //  Inputs:
    //   - addr: 9-bit address (for 512 depth)
    //   - clk: clock signal
    //   - din: 32-bit data input (for programming)
    //   - en: enable signal (always 1 for now)
    //   - we: write enable (1 for programming, 0 for normal read)
    //  Output:
    //   - dout: 32-bit data output (instruction data)
    //  Instruction format (32 bits):
    //   - [31] WMemEn, [30] WRegEn, [29:27] Reg1, [26:24] Reg2, [23:21] WReg1, rest unused
    //-----------------------------------------------------------------------------------
    I_M_32bit_512depth u_imem (
        .addr(imem_addr_mux),
        .clk (clk),
        .din (imem_din_mux),
        .dout(imem_dout),
        .en  (advance | imem_prog_we),
        .we  (imem_we_mux)
    );
    assign if_instr_dbg = imem_dout;//output for debug

    // --- IF/ID Pipeline Register ---
    reg [31:0] ifid_instr;

    always @(posedge clk) begin
        if (reset || pc_reset) begin
            ifid_instr <= 32'd0;
        end else if(advance) begin
            ifid_instr <= imem_dout;
        end
    end

    //==========================================================
    // ID stage
    //==========================================================
    wire [4:0]  id_op  = ifid_instr[31:27];

    //control unit
    wire [3:0]  id_rs3_addr_cu;
    wire [3:0]  id_rs1_addr_cu;
    wire [3:0]  id_rs2_addr_cu;
    wire [14:0] id_imm15_cu;
    wire [2:0]  id_param_addr;

    wire [4:0]  id_op_alu;
    // wire        id_use_tc;
    wire        id_op_tc;
    wire        id_use_imm;
    wire        id_mem_rd_en;
    wire        id_mem_wr_en;
    wire        id_rf_wr_en;
    wire [1:0]  id_wb_sel;
    wire        id_pred_wr_en;
    wire        id_is_bpr;
    wire        id_is_branch;
    wire        id_is_ret;

    control_unit CU(
        .instr      (ifid_instr),
        // Decoded register addresses
        .rd_addr    (id_rs3_addr_cu),
        .rs1_addr   (id_rs1_addr_cu),
        .rs2_addr   (id_rs2_addr_cu),
        .imm15      (id_imm15_cu),
        .param_addr (id_param_addr),
        // EX stage control
        .op_alu     (id_op_alu),
        .use_tc     (id_use_tc),
        .op_tc      (id_op_tc),
        .use_imm    (id_use_imm),
        // MEM stage control
        .mem_rd_en  (id_mem_rd_en),
        .mem_wr_en  (id_mem_wr_en),
        // WB stage control
        .rf_wr_en   (id_rf_wr_en),
        .wb_sel     (id_wb_sel),
        // Special / branch control
        .pred_wr_en (id_pred_wr_en),
        .is_bpr     (id_is_bpr),
        .is_branch  (id_is_branch),
        .is_ret     (id_is_ret)
    );

    //RF
    wire [63:0] wb_data;
    wire [3:0]  wb_addr;
    wire        wb_wr_en;

    wire [63:0] id_rs1_data;   // RS1 read result
    wire [63:0] id_rs2_data;   // RS2 read result
    wire [63:0] id_rs3_data;   // RS3 read result (RD)

    wire [3:0]  id_rs1_addr = id_rs1_addr_cu; 
    wire [3:0]  id_rs2_addr = id_rs2_addr_cu; 
    wire [3:0]  id_rs3_addr = id_rs3_addr_cu;

    regfile RF(
        .clk      (clk),
        .reset    (reset),
        .rs1_addr (id_rs1_addr),
        .rs1_data (id_rs1_data),
        .rs2_addr (id_rs2_addr),
        .rs2_data (id_rs2_data),
        .rs3_addr (id_rs3_addr),
        .rs3_data (id_rs3_data),
        .wr_en    (wb_wr_en),
        .wr_addr  (wb_addr),
        .wr_data  (wb_data)
    );

    //Param RF
    wire [63:0] id_param_rd_data;   // param read result

    param_regs PARAMS(
        .clk      (clk),
        .reset    (reset),
        .wr_en    (param_wr_en),
        .wr_addr  (param_wr_addr),
        .wr_data  (param_wr_data),
        .rd_addr  (id_param_addr),
        .rd_data  (id_param_rd_data)
    );

    // --- ID/EX Pipeline Register ---
    reg [4:0]  idex_op;
    reg [3:0]  idex_rs3_addr;
    reg [14:0] idex_imm15;
    reg [63:0] idex_rs1_val, idex_rs2_val, idex_rs3_val;
    reg [63:0] idex_param_val;
    // Control signals from CU
    reg [4:0]  idex_op_alu;
    reg        idex_use_tc;
    reg        idex_op_tc;
    reg        idex_use_imm;
    reg        idex_mem_rd_en;
    reg        idex_mem_wr_en;
    reg        idex_rf_wr_en;
    reg [1:0]  idex_wb_sel;
    reg        idex_pred_wr_en;
    reg        idex_is_bpr;
    reg        idex_is_branch;
    reg        idex_is_ret;

    always @(posedge clk) begin
        if (reset || pc_reset) begin
            idex_op         <= 5'd0;
            idex_rs3_addr   <= 4'd0;
            idex_imm15      <= 15'd0;
            idex_rs1_val    <= 64'd0;
            idex_rs2_val    <= 64'd0;
            idex_rs3_val    <= 64'd0;
            idex_param_val  <= 64'd0;
            idex_op_alu     <= 5'd0;
            idex_use_tc     <= 1'b0;
            idex_op_tc      <= 1'b0;
            idex_use_imm    <= 1'b0;
            idex_mem_rd_en  <= 1'b0;
            idex_mem_wr_en  <= 1'b0;
            idex_rf_wr_en   <= 1'b0;
            idex_wb_sel     <= 2'd0;
            idex_pred_wr_en <= 1'b0;
            idex_is_bpr     <= 1'b0;
            idex_is_branch  <= 1'b0;
            idex_is_ret     <= 1'b0;
        end else if (advance) begin
            idex_op         <= id_op;
            idex_rs3_addr   <= id_rs3_addr;
            idex_imm15      <= id_imm15_cu;
            idex_rs1_val    <= id_rs1_data;
            idex_rs2_val    <= id_rs2_data;
            idex_rs3_val    <= id_rs3_data;
            idex_param_val  <= id_param_rd_data;
            idex_op_alu     <= id_op_alu;
            idex_use_tc     <= id_use_tc;
            idex_op_tc      <= id_op_tc;
            idex_use_imm    <= id_use_imm;
            idex_mem_rd_en  <= id_mem_rd_en;
            idex_mem_wr_en  <= id_mem_wr_en;
            idex_rf_wr_en   <= id_rf_wr_en;
            idex_wb_sel     <= id_wb_sel;
            idex_pred_wr_en <= id_pred_wr_en;
            idex_is_bpr     <= id_is_bpr;
            idex_is_branch  <= id_is_branch;
            idex_is_ret     <= id_is_ret;
        end
    end
    //==========================================================
    // EX stage
    //==========================================================
    // sign-extend imm15 to 64 bits for ADDI64
    wire [63:0] ex_imm64 = {{49{idex_imm15[14]}}, idex_imm15};

    //tensor core x4
    wire [63:0] tc_a    = idex_rs1_val;
    wire [63:0] tc_b    = idex_rs2_val;
    wire [63:0] tc_c    = idex_rs3_val;   // RD for MAC accumulation
    wire        tc_op_mac = idex_op_tc;
    wire [63:0] tc_y;
    tensor_core_bf16x4 TC(
        .clk         (clk),
        .reset       (reset),
        .pc_reset    (pc_reset),
        .op_mac      (tc_op_mac),
        .A           (tc_a),
        .B           (tc_b),
        .C           (tc_c),
        .Y           (tc_y)
    );

    //alu x4
    wire [63:0] alu_a  = idex_rs1_val;
    wire [63:0] alu_b  = idex_use_imm ? ex_imm64 : idex_rs2_val;
    wire [4:0]  alu_op = idex_op_alu;
    wire [63:0] alu_y;
    wire        alu_pred;

    alu_i16x4 ALU(
        .a        (alu_a),
        .b        (alu_b),
        .op       (alu_op),
        .y        (alu_y),
        .pred_out (alu_pred)
    );

    // Predicate
    reg pred_reg;
    always @(posedge clk) begin
        if (reset || pc_reset)
            pred_reg <= 1'b0;
        else if (idex_pred_wr_en)
            pred_reg <= alu_pred;
    end

    // Branch
    assign  branch_taken  = idex_is_branch || (idex_is_bpr && pred_reg);
    assign  branch_target = idex_imm15[8:0];

    // --- EX/MEM Pipeline Register ---
    reg [3:0]  exmem_rs3_addr;
    reg [63:0] exmem_alu_y;
    reg [63:0] exmem_tc_y;
    reg [63:0] exmem_rs3_val;   // ST64 store data (RD field)
    reg [63:0] exmem_imm_or_param; // MOV / LD_PARAM writeback data
    reg        exmem_mem_rd_en;
    reg        exmem_mem_wr_en;
    reg        exmem_rf_wr_en;
    reg [1:0]  exmem_wb_sel;
    reg        exmem_is_ret;

    // IMM/PARAM mux: MOV uses sign-ext imm15, LD_PARAM uses param value
    wire [63:0] ex_imm_or_param = idex_use_imm ? ex_imm64 : idex_param_val;

    always @(posedge clk) begin
        if (reset || pc_reset) begin
            exmem_rs3_addr     <= 4'd0;
            exmem_alu_y        <= 64'd0;
            exmem_tc_y         <= 64'd0;
            exmem_rs3_val      <= 64'd0;
            exmem_imm_or_param <= 64'd0;
            exmem_mem_rd_en    <= 1'b0;
            exmem_mem_wr_en    <= 1'b0;
            exmem_rf_wr_en     <= 1'b0;
            exmem_wb_sel       <= 2'd0;
            exmem_is_ret       <= 1'b0;
        end else if (advance) begin
            exmem_rs3_addr     <= idex_rs3_addr;
            exmem_alu_y        <= alu_y;
            exmem_tc_y         <= tc_y;
            exmem_rs3_val      <= idex_rs3_val;   // RD value for ST64
            exmem_imm_or_param <= ex_imm_or_param;
            exmem_mem_rd_en    <= idex_mem_rd_en;
            exmem_mem_wr_en    <= idex_mem_wr_en;
            exmem_rf_wr_en     <= idex_rf_wr_en;
            exmem_wb_sel       <= idex_wb_sel;
            exmem_is_ret       <= idex_is_ret;
        end
    end

    //==========================================================
    // MEM stage
    //==========================================================
    // DMEM address comes from ALU (RS1 + imm15 already computed in EX)
    // Drive external DMEM port (Port B of shared BRAM in cpu_gpu_top)
    assign dmem_addr = exmem_alu_y[7:0];
    assign dmem_din  = exmem_rs3_val;
    assign dmem_en   = advance & (exmem_mem_rd_en | exmem_mem_wr_en);
    assign dmem_we   = advance & exmem_mem_wr_en;

    // --- MEM/WB Pipeline Register ---
    reg [3:0]  memwb_rs3_addr;
    reg [63:0] memwb_alu_y;
    reg [63:0] memwb_tc_y;
    reg [63:0] memwb_imm_or_param;
    reg        memwb_rf_wr_en;
    reg [1:0]  memwb_wb_sel;
    

    always @(posedge clk) begin
        if (reset || pc_reset) begin
            memwb_rs3_addr      <= 4'd0;
            memwb_alu_y        <= 64'd0;
            memwb_tc_y         <= 64'd0;
            memwb_imm_or_param <= 64'd0;
            memwb_rf_wr_en     <= 1'b0;
            memwb_wb_sel       <= 2'd0;
            memwb_is_ret <= 1'b0;
        end else if (advance) begin
            memwb_rs3_addr      <= exmem_rs3_addr;
            memwb_alu_y        <= exmem_alu_y;
            memwb_tc_y         <= exmem_tc_y;
            memwb_imm_or_param <= exmem_imm_or_param;
            memwb_rf_wr_en     <= exmem_rf_wr_en;
            memwb_wb_sel       <= exmem_wb_sel;
            memwb_is_ret       <= exmem_is_ret;
        end
    end

    //==========================================================
    // WB stage
    //==========================================================
    localparam WB_ALU = 2'd0;
    localparam WB_TC  = 2'd1;
    localparam WB_MEM = 2'd2;
    localparam WB_IMM = 2'd3;

    reg [63:0] wb_data_mux;
    always @(*) begin
        case (memwb_wb_sel)
            WB_ALU:  wb_data_mux = memwb_alu_y;
            WB_TC:   wb_data_mux = memwb_tc_y;
            WB_MEM:  wb_data_mux = dmem_dout;
            WB_IMM:  wb_data_mux = memwb_imm_or_param;
            default: wb_data_mux = memwb_alu_y;
        endcase
    end

    assign wb_data  = wb_data_mux;
    assign wb_addr  = memwb_rs3_addr;
    assign wb_wr_en = memwb_rf_wr_en;

endmodule