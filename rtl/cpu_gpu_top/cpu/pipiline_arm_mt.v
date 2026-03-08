`timescale 1ns/1ps
// =============================================================================
// pipeline_p.v  ?  5-stage ARM-32 pipeline, extended instruction set.
//
// Pipeline stages:  IF ? IF/ID ? ID ? ID/EX ? EX ? EX/MEM ? MEM ? MEM/WB ? WB
// No forwarding / hazard detection ? programmer inserts NOPs.
//
// ??? Original instructions (unchanged) ???????????????????????????????????????
//  NOP  32'hE000_0000   (AND R0,R0,R0, result discarded)
//  MOV  Rd,#imm8        op=00 I=1 opcode=1101
//  ADD  Rd,Rn,Rm/imm8   op=00 opcode=0100
//  SUB  Rd,Rn,Rm/imm8   op=00 opcode=0010
//  AND  Rd,Rn,Rm        op=00 opcode=0000
//  ORR  Rd,Rn,Rm        op=00 opcode=1100
//  EOR  Rd,Rn,Rm        op=00 opcode=0001
//  LDR  Rd,[Rn,#off12]  op=01 L=1
//  STR  Rd,[Rn,#off12]  op=01 L=0
//  B    off24            op=10 [27:25]=101 bit24=0  (unconditional branch)
//  BL   off24            op=10 [27:25]=101 bit24=1  (branch-and-link)
//    Jumps to target; saves return address (BL_word+1) into R14.
//    Encoding: {4'hE, 4'b1011, off24}
//    Return with: JR R14  (= BX R14)
//  BX   Rm              op=00 [27:4]=24'h12FFF1  (jump register = JR)
//
// ??? New instructions ?????????????????????????????????????????????????????????
//
//  SLL  Rd,Rn,Rm        Shift Left  by Rm[5:0]
//    {4'hE, 3'b000, 4'b0110, 1'b0, Rn, Rd, 8'h00, Rm}
//    (I=0 selects variable-shift; I=1 preserves old shift-by-1 behaviour)
//
//  SRL  Rd,Rn,Rm        Shift Right by Rm[5:0]
//    {4'hE, 3'b000, 4'b0111, 1'b0, Rn, Rd, 8'h00, Rm}
//
//  JR   Rm              Jump Register (identical to BX Rm)
//    {4'hE, 24'h12FFF1, Rm[3:0]}
//
//  J    target9         Unconditional absolute jump to 9-bit word address
//    inst[31:26] = 6'b111011  (op=2'b11 sub=2'b11)
//    inst[25:0]  = zero-padded target; lower 9 bits used as new PC
//    {6'b111011, 17'b0, target9[8:0]}
//
//  SLT  Rd,Rn,Rm        Set Less Than (signed): Rd = (Rn < Rm) ? 1 : 0
//    {4'hE, 3'b000, 4'b1011, 1'b0, Rn, Rd, 8'h00, Rm}
//
//  BEQ  Rn,Rm,off16     Branch if Equal (Rn == Rm)
//    inst[31:28]=4'hE  inst[27:24]=4'b1000
//    inst[23:20]=Rn  inst[19:16]=Rm  inst[15:0]=off16
//    branch_target = ifid_pc + 2 + sign_extend(off16)
//    {4'hE, 4'b1000, Rn, Rm, 16'(off16)}
//
//  BNE  Rn,Rm,off16     Branch if Not Equal (Rn != Rm)
//    inst[27:24]=4'b1001
//    {4'hE, 4'b1001, Rn, Rm, 16'(off16)}
//
// ??? Register file:   16 × 64-bit  (R0?R15) ??????????????????????????????????
// ??? ALU:             64-bit ??????????????????????????????????????????????????
// ??? Data memory:     256 × 64-bit  (D_M_64bit_256) ??????????????????????????
// ??? Instruction mem: 512 × 32-bit  (I_M_32bit_512depth) ?????????????????????
// =============================================================================
module pipeline (
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
  output wire [31:0] if_instr_dbg
);

// ===========================================================================
// PIPELINE CONTROL
// ===========================================================================
  reg step_d;
  always @(posedge clk) begin
    if (reset || pc_reset_pulse) step_d <= 1'b0;
    else                         step_d <= step;
  end

  wire step_pulse = step & ~step_d;
  wire advance    = run | step_pulse;

  // Forward declarations ? driven in EX stage below.
  wire        ex_branch_taken;
  wire [8:0]  ex_branch_target;
  wire [1:0]      ex_thread_id;

// ===========================================================================
// IF STAGE
// ===========================================================================
  //reg [8:0] pc [3:0];
  //assign pc_dbg = pc[0];
  //reg [1:0] thread_id;
	wire [8:0] pc;
	wire [1:0] thread_id;
  // wire [8:0]  imem_addr_mux = imem_prog_we ? imem_prog_addr : pc[thread_id];
   pc_target pc_t( 
		.advance(advance),
		.pc_reset_pulse(pc_reset_pulse),
		.clk(clk),
		.reset (reset),
		.ex_branch_taken(ex_branch_taken),
		.ex_branch_target(ex_branch_target),
		.ex_thread_id(ex_thread_id),
		.pc_target(pc),
		.thread_id(thread_id)
    );
	 
  //wire [8:0]  imem_addr_mux = imem_prog_we ? imem_prog_addr : pc[thread_id];
  wire [8:0]  imem_addr_mux = imem_prog_we ? imem_prog_addr : pc;
  assign pc_dbg = imem_addr_mux;
  wire [31:0] imem_dout;

  I_M_32bit_512depth u_imem (
    .addr (imem_addr_mux),
    .clk  (clk),
    .din  (imem_prog_wdata),
    .dout (imem_dout),
    .en   (1'b1),
    .we   (imem_prog_we)
  );
  assign if_instr_dbg = imem_dout;
  
/*
  always @(posedge clk) begin
    if  (reset || pc_reset_pulse) begin 
			pc[0] <= 9'b000000000;
			pc[1] <= 9'b010000000;
			pc[2] <= 9'b100000000;
			pc[3] <= 9'b110000000;
			thread_id <= 2'b00;
			end
    // else if (ex_branch_taken)         pc[ex_thread_id] <= ex_branch_target;
    else if (advance)              
	 begin  
		//pc[if_thread_id] <= pc[if_thread_id] + 9'd1;
		thread_id <= thread_id + 2'b01;
		
		if (ex_branch_taken)   begin
			pc[ex_thread_id] <= ex_branch_target;
		end
		if (pc[thread_id][6:1] == 6'b111111) begin 
			pc[thread_id] <= pc[thread_id]; 
		end else begin  
			pc[thread_id] <= pc[thread_id] + 9'd1; 
		end
	 end
  end
*/
// ===========================================================================
// IF/ID PIPELINE REGISTER
// ===========================================================================
  reg [31:0] ifid_instr;
  //wire [31:0] ifid_instr;
  reg [8:0]  ifid_pc;
  reg [8:0]  pc_delay;
  reg [1:0] thread_id_delay;
  reg [1:0] ifid_thread_id;
  
  always @(posedge clk) begin
    if (reset || pc_reset_pulse) begin
      pc_delay    <= 9'd0;
		thread_id_delay <= 2'b00;
    end else if (advance) begin
      //pc_delay    <= pc[thread_id];
		pc_delay    <= pc;
		thread_id_delay <= thread_id;
    end
  end
	 
	 
	//assign ifid_instr = (reset || pc_reset_pulse) ? 32'h0 : imem_dout;
	
	always @(posedge clk) begin
	//if (reset || pc_reset_pulse || ex_branch_taken) begin
    if (reset || pc_reset_pulse) begin
      ifid_instr <= 32'h0;
      ifid_pc    <= 9'd0;
		ifid_thread_id <= 2'b00;
    end else if (advance) begin
      ifid_instr <= imem_dout;
      //ifid_pc    <= pc;
		ifid_pc <= pc_delay;
		ifid_thread_id <= thread_id_delay;
    end
  end
  

// ===========================================================================
// ID STAGE  ?  Instruction decode + register-file read
// ===========================================================================

  // ---------------------------------------------------------------------------
  // ARM-32 field extraction
  // ---------------------------------------------------------------------------
  wire [1:0]  if_op     = ifid_instr[27:26];
  wire        if_I      = ifid_instr[25];
  wire [3:0]  if_opcode = ifid_instr[24:21];
  wire        if_L      = ifid_instr[20];
  wire [3:0]  if_Rn     = ifid_instr[19:16];
  wire [3:0]  if_Rd     = ifid_instr[15:12];
  wire [3:0]  if_Rm     = ifid_instr[3:0];
  wire [7:0]  if_imm8   = ifid_instr[7:0];
  wire [23:0] if_off24  = ifid_instr[23:0];
  wire        if_U      = ifid_instr[23];
  wire [11:0] if_imm12  = ifid_instr[11:0];

  // wire [1:0] if_thread_id = ifid_thread_id ;
  
  // BEQ/BNE field extraction (custom encoding ? lives in inst[27:24]=1000/1001)
  wire [3:0]  if_beq_type = ifid_instr[27:24];  // 4'b1000=BEQ, 4'b1001=BNE
  wire [3:0]  if_beq_Rn   = ifid_instr[23:20];
  wire [3:0]  if_beq_Rm   = ifid_instr[19:16];
  wire [15:0] if_beq_off  = ifid_instr[15:0];

  // J field extraction (inst[31:26]=6'b111010): inst[25:0]=target26
  wire [25:0] if_j_target = ifid_instr[25:0];

  // ---------------------------------------------------------------------------
  // ALU control constants  (must match ALU.v)
  // ---------------------------------------------------------------------------
  localparam ALU_NOP     = 4'b0000;
  localparam ALU_ADD     = 4'b0001;
  localparam ALU_SUB     = 4'b0010;
  localparam ALU_AND     = 4'b0011;
  localparam ALU_OR      = 4'b0100;
  localparam ALU_XNOR    = 4'b0101;
  localparam ALU_SHIFTL  = 4'b0110;   // shift left  by 1 (immediate)
  localparam ALU_SHIFTR  = 4'b0111;   // shift right by 1 (immediate)
  localparam ALU_SHIFTLV = 4'b1000;   // shift left  by B[5:0] (variable) ? NEW
  localparam ALU_SHIFTRV = 4'b1001;   // shift right by B[5:0] (variable) ? NEW
  localparam ALU_SLT     = 4'b1010;   // set less than (signed)            ? NEW

  // ---------------------------------------------------------------------------
  // Detect BEQ/BNE before normal op decode
  // BEQ: cond=E, [27:24]=4'b1000    BNE: cond=E, [27:24]=4'b1001
  // ---------------------------------------------------------------------------
  wire is_beqbne = (ifid_instr[31:28] == 4'hE) &&
                   ((if_beq_type == 4'b1000) || (if_beq_type == 4'b1001));

  // Detect J instruction: inst[31:26]=6'b111010
  // wire is_j = (ifid_instr[31:26] == 6'b111010);
  wire is_j = (ifid_instr[31:26] == 6'b111011);

  // ---------------------------------------------------------------------------
  // Register-file read port addressing
  //   BEQ/BNE: port0=Rn, port1=Rm  (both comparison operands)
  //   STR:     port0=Rn(base), port1=Rd(data to store)
  //   others:  port0=Rn, port1=Rm
  // ---------------------------------------------------------------------------
  wire [3:0] id_reg1 = is_beqbne ? if_beq_Rn : if_Rn;
  wire [3:0] id_reg2 = is_beqbne ? if_beq_Rm :
                       (if_op == 2'b01 && !if_L) ? if_Rd : if_Rm;

  wire [63:0] rf_r1data;
  wire [63:0] rf_r2data;

  // ---------------------------------------------------------------------------
  // Combinational decoder
  // ---------------------------------------------------------------------------
  reg [3:0]  dec_alu_ctrl;
  reg        dec_use_imm;
  reg [63:0] dec_imm64;
  reg        dec_reg_wen;
  reg        dec_mem_wen;
  reg        dec_is_load;
  reg        dec_is_branch;
  reg        dec_is_jump;
  reg [8:0]  dec_branch_target;
  reg        dec_is_cond_branch; // 1 = BEQ or BNE
  reg        dec_branch_cond;    // 0 = BEQ, 1 = BNE
  reg        dec_is_bl;          // 1 = BL: write return addr (BL_word+1) to R14
		reg signed [9:0] full_branch_calc;

  always @(*) begin
    // Safe defaults
    dec_alu_ctrl      = ALU_NOP;
    dec_use_imm       = 1'b0;
    dec_imm64         = 64'b0;
    dec_reg_wen       = 1'b0;
    dec_mem_wen       = 1'b0;
    dec_is_load       = 1'b0;
    dec_is_branch     = 1'b0;
    dec_is_jump       = 1'b0;
    dec_branch_target = 9'd0;
    dec_is_cond_branch= 1'b0;
    dec_branch_cond   = 1'b0;
    dec_is_bl         = 1'b0;

    // Standard B/BL branch target (may be overridden below)
    // off24 is a signed 24-bit word offset.  Cast it to signed so Verilog
    // sign-extends during the 9-bit addition; the result is automatically
    // truncated to 9 bits by the assignment target width.
    //dec_branch_target = ifid_pc + 9'd2 + if_off24[8:0];

		full_branch_calc = $signed({1'b0, ifid_pc}) + 
                          $signed(10'd2) + 
                          $signed({{1{if_off24[8]}}, if_beq_off});
		dec_branch_target = full_branch_calc[8:0];
		
    // ?? Priority 1: BEQ / BNE ????????????????????????????????????????????????
    if (is_beqbne) begin
      // Use ALU to compute Rn - Rm; branch if zero (BEQ) or nonzero (BNE)
      dec_alu_ctrl       = ALU_SUB;
      dec_use_imm        = 1'b0;
      dec_reg_wen        = 1'b0;
      dec_is_branch      = 1'b1;
      dec_is_cond_branch = 1'b1;
      dec_branch_cond    = (if_beq_type == 4'b1001); // 1=BNE, 0=BEQ
      // Branch target: ifid_pc + 2 + sign_extend(off16), truncated to 9 bits
      // dec_branch_target  = ifid_pc + 9'd2 + if_beq_off[8:0];
		
		full_branch_calc = $signed({1'b0, ifid_pc}) + 
                          $signed(10'd2) + 
                          $signed({{1{if_beq_off[8]}}, if_beq_off});
		dec_branch_target = full_branch_calc[8:0];

    // ?? Priority 2: J (absolute jump) ????????????????????????????????????????
    end else if (is_j) begin
      dec_is_branch     = 1'b1;
      dec_branch_target = if_j_target[8:0];  // lower 9 bits = word address
      dec_reg_wen       = 1'b0;

    // ?? Priority 3: Normal ARM-32 instructions ????????????????????????????????
    end else begin
      case (if_op)

        // ?? op=00: Data-processing, BX, SLT, SLL, SRL ??????????????????????
        2'b00: begin
          // BX Rm  (= JR Rm): inst[27:4] = 24'h12FFF1
          if (ifid_instr[27:4] == 24'h12FFF1) begin
            dec_is_jump = 1'b1;
            // target = rf_r2data[8:0], resolved in EX

          end else begin
            // Immediate operand (I=1): 8-bit zero-extended
            if (if_I) begin
              dec_use_imm = 1'b1;
              dec_imm64   = {56'b0, if_imm8};
            end

            case (if_opcode)
              4'b0100: begin dec_alu_ctrl = ALU_ADD;   dec_reg_wen = 1'b1; end // ADD
              4'b0010: begin dec_alu_ctrl = ALU_SUB;   dec_reg_wen = 1'b1; end // SUB
              4'b0000: begin dec_alu_ctrl = ALU_AND;   dec_reg_wen = 1'b1; end // AND
              4'b1100: begin dec_alu_ctrl = ALU_OR;    dec_reg_wen = 1'b1; end // ORR
              4'b0001: begin dec_alu_ctrl = ALU_XNOR;  dec_reg_wen = 1'b1; end // EOR
              4'b1101: begin dec_alu_ctrl = ALU_ADD;   dec_reg_wen = 1'b1; end // MOV
              4'b1111: begin dec_alu_ctrl = ALU_XNOR;  dec_reg_wen = 1'b1; end // MVN
              4'b1010: begin dec_alu_ctrl = ALU_SUB;   dec_reg_wen = 1'b0; end // CMP
              4'b1000: begin dec_alu_ctrl = ALU_AND;   dec_reg_wen = 1'b0; end // TST
              4'b1001: begin dec_alu_ctrl = ALU_XNOR;  dec_reg_wen = 1'b0; end // TEQ

              // SLL Rd,Rn,Rm: variable left shift (I=0) / shift-by-1 (I=1)
              4'b0110: begin
                dec_reg_wen  = 1'b1;
                dec_alu_ctrl = if_I ? ALU_SHIFTL : ALU_SHIFTLV;
              end

              // SRL Rd,Rn,Rm: variable right shift (I=0) / shift-by-1 (I=1)
              4'b0111: begin
                dec_reg_wen  = 1'b1;
                dec_alu_ctrl = if_I ? ALU_SHIFTR : ALU_SHIFTRV;
              end

              // SLT Rd,Rn,Rm  (opcode=1011, unused in ARM)
              4'b1011: begin dec_alu_ctrl = ALU_SLT;   dec_reg_wen = 1'b1; end

              4'b0101: begin dec_alu_ctrl = ALU_ADD;   dec_reg_wen = 1'b1; end // ADC?ADD
              4'b0011: begin dec_alu_ctrl = ALU_SUB;   dec_reg_wen = 1'b1; end // RSB
              default: begin dec_alu_ctrl = ALU_NOP;   dec_reg_wen = 1'b0; end
            endcase
          end
        end // op=00

        // ?? op=01: Load / Store ?????????????????????????????????????????????
        2'b01: begin
          dec_alu_ctrl = if_U ? ALU_ADD : ALU_SUB;
          dec_use_imm  = 1'b1;
          dec_imm64    = {52'b0, if_imm12};

          if (if_L) begin              // LDR
            dec_is_load = 1'b1;
            dec_reg_wen = 1'b1;
          end else begin               // STR
            dec_mem_wen = 1'b1;
          end
        end // op=01

        // ?? op=10: Branch B / BL ????????????????????????????????????????????
        2'b10: begin
          if (ifid_instr[27:25] == 3'b101) begin
            dec_is_branch = 1'b1;
            if (ifid_instr[24]) begin   // bit24=1 ? BL
              dec_is_bl   = 1'b1;
              dec_reg_wen = 1'b1;       // write return address to R14
              // dec_wreg forced to R14 outside the case (see below)
            end
            // plain B: dec_reg_wen stays 0, dec_is_bl stays 0
          end
        end // op=10

        default: ; // NOP
      endcase
    end
  end // always decoder

  // For BL the destination register is always R14 (link register),
  // regardless of what the instruction's Rd field says.
  wire [3:0] dec_wreg_final = dec_is_bl ? 4'd14 : if_Rd;

  // ---------------------------------------------------------------------------
  // WB bus  (driven from MEM/WB stage; declared here for forward reference)
  // ---------------------------------------------------------------------------
  wire        wb_wen;
  wire [3:0]  wb_waddr;
  wire [63:0] wb_wdata;
  wire [1:0] wb_thread_id;

  // ---------------------------------------------------------------------------
  // Register file
  // ---------------------------------------------------------------------------
  /*
  REG_FILE #(.data_width(64), .addr_width(4)) u_rf (
    .clk    (clk),
    .wena   (wb_wen),
    .r0addr (id_reg1),
    .r1addr (id_reg2),
    .waddr  (wb_waddr),
    .wdata  (wb_wdata),
    .r0data (rf_r1data),
    .r1data (rf_r2data)
  );
  */
REG_FILE_BANK #(.data_width(64), .addr_width(4), .th_id_width(2)) u_rf (
    .clk    (clk),
    .wena   (wb_wen),
	 .rd_th_id (ifid_thread_id),
	 .w_th_id (wb_thread_id),
    .r0addr (id_reg1),
    .r1addr (id_reg2),
    .waddr  (wb_waddr),
    .wdata  (wb_wdata),
    .r0data (rf_r1data),
    .r1data (rf_r2data)
);


  // ---------------------------------------------------------------------------
  // ID ? ID/EX pipeline registers
  // ---------------------------------------------------------------------------
  reg [3:0]  idex_alu_ctrl;
  reg        idex_use_imm;
  reg [63:0] idex_imm64;
  reg        idex_reg_wen;
  reg        idex_mem_wen;
  reg        idex_is_load;
  reg        idex_is_branch;
  reg        idex_is_jump;
  reg [8:0]  idex_branch_target;
  reg [3:0]  idex_wreg;
  reg [63:0] idex_r1data;
  reg [63:0] idex_r2data;
  reg        idex_is_cond_branch; // 1 = BEQ or BNE (condition checked in EX)
  reg        idex_branch_cond;    // 0 = BEQ (take if zero), 1 = BNE (take if nonzero)
  reg        idex_is_bl;          // 1 = BL: EX writes return address instead of ALU result
  reg [8:0]  idex_pc;             // word address of the BL instruction itself
  reg [1:0] idex_thread_id;

  always @(posedge clk) begin
    if (reset || pc_reset_pulse ) begin
      idex_alu_ctrl       <= ALU_NOP;
      idex_use_imm        <= 1'b0;
      idex_imm64          <= 64'b0;
      idex_reg_wen        <= 1'b0;
      idex_mem_wen        <= 1'b0;
      idex_is_load        <= 1'b0;
      idex_is_branch      <= 1'b0;
      idex_is_jump        <= 1'b0;
      idex_branch_target  <= 9'd0;
      idex_wreg           <= 4'h0;
      idex_r1data         <= 64'h0;
      idex_r2data         <= 64'h0;
      idex_is_cond_branch <= 1'b0;
      idex_branch_cond    <= 1'b0;
      idex_is_bl          <= 1'b0;
      idex_pc             <= 9'd0;
		idex_thread_id 		<= 2'b00;
    end else if (advance) begin
      idex_alu_ctrl       <= dec_alu_ctrl;
      idex_use_imm        <= dec_use_imm;
      idex_imm64          <= dec_imm64;
      idex_reg_wen        <= dec_reg_wen;
      idex_mem_wen        <= dec_mem_wen;
      idex_is_load        <= dec_is_load;
      idex_is_branch      <= dec_is_branch;
      idex_is_jump        <= dec_is_jump;
      idex_branch_target  <= dec_branch_target;
      idex_wreg           <= dec_wreg_final;  // R14 for BL, if_Rd otherwise
      idex_r1data         <= rf_r1data;
      idex_r2data         <= rf_r2data;
      idex_is_cond_branch <= dec_is_cond_branch;
      idex_branch_cond    <= dec_branch_cond;
      idex_is_bl          <= dec_is_bl;
      idex_pc             <= ifid_pc;         // word addr of the BL instruction
		idex_thread_id <= ifid_thread_id;
    end
  end

// ===========================================================================
// EX STAGE  ?  ALU + branch / jump resolution
// ===========================================================================

  wire [63:0] ex_alu_A = idex_r1data;
  wire [63:0] ex_alu_B = idex_use_imm ? idex_imm64 : idex_r2data;
  
  assign ex_thread_id = idex_thread_id;
  
  wire [63:0] ex_alu_out;
  wire        ex_alu_ovf;

  ALU #(.data_width(64)) u_alu (
    .A        (ex_alu_A),
    .B        (ex_alu_B),
    .aluctrl  (idex_alu_ctrl),
    .Z        (ex_alu_out),
    .overflow (ex_alu_ovf)
  );

  // Zero flag for conditional branches
  // wire ex_zero = (ex_alu_out == 64'h0);
  wire ex_zero = (ex_alu_A == ex_alu_B);

  // Conditional branch decision
  // BEQ: take if Rn==Rm  ?  (Rn-Rm)==0  ?  ex_zero=1
  // BNE: take if Rn!=Rm  ?  (Rn-Rm)!=0  ?  ex_zero=0
  wire ex_cond_taken = idex_is_cond_branch &
                       (idex_branch_cond ? ~ex_zero : ex_zero);

  // Unconditional branch: is_branch=1 and is NOT a conditional branch
  wire ex_uncond_taken = idex_is_branch & ~idex_is_cond_branch;

  assign ex_branch_taken  = (ex_uncond_taken | ex_cond_taken | idex_is_jump);
  assign ex_branch_target = idex_is_jump
                            ? idex_r2data[8:0]   // BX / JR: target from register
                            : idex_branch_target; // B / J / BEQ / BNE

  // Return address for BL = word address of instruction after BL = idex_pc + 1
  wire [63:0] ex_link_addr = {55'b0, idex_pc + 9'd1};

  // Write-back data mux:
  //   BL  ? return address (idex_pc + 1) into R14
  //   all others ? ALU result
  wire [63:0] ex_wdata = idex_is_bl ? ex_link_addr : ex_alu_out;
  wire [63:0] ex_store = idex_r2data;

  // EX ? EX/MEM pipeline registers
  reg        exmem_reg_wen;
  reg        exmem_mem_wen;
  reg        exmem_is_load;
  reg [3:0]  exmem_wreg;
  reg [63:0] exmem_alu_result;
  reg [63:0] exmem_store_data;
  reg [1:0] exmem_thread_id;

  always @(posedge clk) begin
    if (reset || pc_reset_pulse) begin
      exmem_reg_wen    <= 1'b0;
      exmem_mem_wen    <= 1'b0;
      exmem_is_load    <= 1'b0;
      exmem_wreg       <= 4'h0;
      exmem_alu_result <= 64'h0;
      exmem_store_data <= 64'h0;
		exmem_thread_id 		<= 2'b00;
    end else if (advance) begin
      exmem_reg_wen    <= idex_reg_wen;
      exmem_mem_wen    <= idex_mem_wen;
      exmem_is_load    <= idex_is_load;
      exmem_wreg       <= idex_wreg;
      exmem_alu_result <= ex_wdata;
      exmem_store_data <= ex_store;
		exmem_thread_id <= ex_thread_id;
    end
  end

// ===========================================================================
// MEM STAGE  ?  Data memory access
// ===========================================================================
  wire [7:0]  mem_bram_addr = exmem_alu_result[7:0];
  wire [63:0] dmem_douta;
  wire [63:0] dmem_doutb;

  D_M_64bit_256 u_dmem (
    .addra (mem_bram_addr),
    .clka  (clk),
    .ena   (exmem_is_load | exmem_mem_wen),
    .wea   (exmem_mem_wen),
    .dina  (exmem_store_data),
    .douta (dmem_douta),

    .addrb (dmem_prog_addr),
    .clkb  (clk),
    .enb   (dmem_prog_en),
    .web   (dmem_prog_we),
    .dinb  (dmem_prog_wdata),
    .doutb (dmem_doutb)
  );
  assign dmem_prog_rdata = dmem_doutb;

  reg        mem_reg_wen;
  reg        mem_is_load;
  reg [3:0]  mem_wreg;
  reg [63:0] mem_alu_result;
  reg [1:0]  mem_thread_id;
  
  always @(posedge clk) begin
    if (reset || pc_reset_pulse) begin
      mem_reg_wen    <= 1'b0;
      mem_is_load    <= 1'b0;
      mem_wreg       <= 4'h0;
      mem_alu_result <= 64'h0;
		mem_thread_id <= 2'b00;
    end else if (advance) begin
      mem_reg_wen    <= exmem_reg_wen;
      mem_is_load    <= exmem_is_load;
      mem_wreg       <= exmem_wreg;
      mem_alu_result <= exmem_alu_result;
		mem_thread_id <= exmem_thread_id;
    end
  end

// ===========================================================================
// MEM/WB PIPELINE REGISTERS
// ===========================================================================
  reg        memwb_wreg_en;
  reg [3:0]  memwb_wreg;
  reg [63:0] memwb_alu_result;
  reg [63:0] memwb_dmem_rdata;
  reg        memwb_is_load;
  reg [1:0]  memwb_thread_id;

  always @(posedge clk) begin
    if (reset || pc_reset_pulse) begin
      memwb_wreg_en    <= 1'b0;
      memwb_wreg       <= 4'h0;
      memwb_alu_result <= 64'h0;
      memwb_dmem_rdata <= 64'h0;
      memwb_is_load    <= 1'b0;
		memwb_thread_id <= 2'b00;
    end else if (advance) begin
      memwb_wreg_en    <= mem_reg_wen;
      memwb_wreg       <= mem_wreg;
      memwb_alu_result <= mem_alu_result;
      memwb_dmem_rdata <= dmem_douta;
      memwb_is_load    <= mem_is_load;
		memwb_thread_id <= mem_thread_id;
    end
  end

// ===========================================================================
// WB STAGE  ?  Write back to register file
// ===========================================================================
  assign wb_wen   = (~reset) & (~pc_reset_pulse) & memwb_wreg_en;
  assign wb_waddr = memwb_wreg;
  assign wb_wdata = memwb_is_load ? memwb_dmem_rdata : memwb_alu_result;
  assign wb_thread_id = memwb_thread_id;
endmodule
