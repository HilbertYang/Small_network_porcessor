`timescale 1ns/1ps
module CTRL_UNIT (
    input wire [31:0]   instr,
    input wire [8:0]    ifid_pc,
    output wire         dec_reg_wen,
    output wire         dec_mem_wen,
    output wire [3:0]   id_reg1, id_reg2,
    output wire [3:0]   dec_alu_ctrl,
    output wire         dec_use_imm,
    output wire [63:0]  dec_imm64,
    output wire         dec_is_load,
    output wire         dec_is_branch,
    output wire         dec_is_jump,
    output wire         dec_is_cond_branch,
    output wire [8:0]   dec_branch_target,
    output wire         dec_branch_cond, 
    output wire         dec_is_bl,
    output wire [3:0]   dec_wreg_final
);
  
  // ---------------------------------------------------------------------------
  // ALU control constants 
  // ---------------------------------------------------------------------------
  localparam ALU_NOP     = 4'b0000;
  localparam ALU_ADD     = 4'b0001;
  localparam ALU_SUB     = 4'b0010;
  localparam ALU_AND     = 4'b0011;
  localparam ALU_OR      = 4'b0100;
  localparam ALU_XNOR    = 4'b0101;
  localparam ALU_SHIFTL  = 4'b0110;   
  localparam ALU_SHIFTR  = 4'b0111;  
  localparam ALU_SHIFTLV = 4'b1000;   
  localparam ALU_SHIFTRV = 4'b1001;   
  localparam ALU_SLT     = 4'b1010;   


  wire [1:0]  if_op     = instr[27:26];
  wire        if_I      = instr[25];
  wire [3:0]  if_opcode = instr[24:21];
  wire        if_L      = instr[20];
  wire [3:0]  if_Rn     = instr[19:16];
  wire [3:0]  if_Rd     = instr[15:12];
  wire [3:0]  if_Rm     = instr[3:0];
  wire [7:0]  if_imm8   = instr[7:0];
  wire [23:0] if_off24  = instr[23:0];
  wire        if_U      = instr[23];
  wire [11:0] if_imm12  = instr[11:0];

  // BEQ/BNE
  wire [3:0]  if_beq_type = instr[27:24];  // 4'b1000=BEQ, 4'b1001=BNE
  wire [3:0]  if_beq_Rn   = instr[23:20];
  wire [3:0]  if_beq_Rm   = instr[19:16];
  wire [15:0] if_beq_off  = instr[15:0];

  // J field extraction (inst[31:26]=6'b111010): inst[25:0]=target26
  wire [25:0] if_j_target = instr[25:0];

  // ---------------------------------------------------------------------------
  // Detect BEQ/BNE before normal op decode
  // BEQ: cond=E, [27:24]=4'b1000    BNE: cond=E, [27:24]=4'b1001
  // ---------------------------------------------------------------------------
  wire is_beqbne = (instr[31:28] == 4'hE) &&
                   ((if_beq_type == 4'b1000) || (if_beq_type == 4'b1001));

  // Detect J instruction: inst[31:26]=6'b111011
  wire is_j = (instr[31:26] == 6'b111011);

  // ---------------------------------------------------------------------------
  // Register-file read port addressing
  //   BEQ/BNE: port0=Rn, port1=Rm  (both comparison operands)
  //   STR:     port0=Rn(base), port1=Rd(data to store)
  //   others:  port0=Rn, port1=Rm
  // ---------------------------------------------------------------------------
  wire [3:0] id_reg1 = is_beqbne ? if_beq_Rn : if_Rn;
  wire [3:0] id_reg2 = is_beqbne ? if_beq_Rm :
                       (if_op == 2'b01 && !if_L) ? if_Rd : if_Rm;


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
    dec_branch_target = ifid_pc + 9'd2 + if_off24[8:0];
	 //dec_branch_target = ifid_pc + 9'd2 + imem_dout[8:0];

    // Priority 1: BEQ / BNE 
    if (is_beqbne) begin
      // Use ALU to compute Rn - Rm; branch if zero (BEQ) or nonzero (BNE)
      dec_alu_ctrl       = ALU_SUB;
      dec_use_imm        = 1'b0;
      dec_reg_wen        = 1'b0;
      dec_is_branch      = 1'b1;
      dec_is_cond_branch = 1'b1;
      dec_branch_cond    = (if_beq_type == 4'b1001); // 1=BNE, 0=BEQ
      // Branch target: ifid_pc + 2 + sign_extend(off16), truncated to 9 bits
      dec_branch_target  = ifid_pc + 9'd2 + if_beq_off[8:0];

    // Priority 2: J (absolute jump) 
    end else if (is_j) begin
      dec_is_branch     = 1'b1;
      dec_branch_target = if_j_target[8:0];  // lower 9 bits = word address
      dec_reg_wen       = 1'b0;

    // Priority 3: Normal ARM-32 instructions
    end else begin
      case (if_op)

        // op=00: Data-processing, BX, SLT, SLL, SRL
        2'b00: begin
          // BX Rm  (= JR Rm): inst[27:4] = 24'h12FFF1
          if (instr[27:4] == 24'h12FFF1) begin
            dec_is_jump = 1'b1;
            // target = rf_r2data[8:0], resolved in EX

          end else begin
            // Immediate operand (I=1): 8-bit zero-extended
            if (if_I) begin
              dec_use_imm = 1'b1;
              dec_imm64   = {56{if_imm8[7]}, if_imm8};
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
              4'b0101: begin dec_alu_ctrl = ALU_ADD;   dec_reg_wen = 1'b1; end 
              4'b0011: begin dec_alu_ctrl = ALU_SUB;   dec_reg_wen = 1'b1; end 
              default: begin dec_alu_ctrl = ALU_NOP;   dec_reg_wen = 1'b0; end
            endcase
          end
        end // op=00

        // op=01: Load / Store
        2'b01: begin
          dec_alu_ctrl = if_U ? ALU_ADD : ALU_SUB;
          dec_use_imm  = 1'b1;
          dec_imm64    = {52{if_imm12[11]}, if_imm12};

          if (if_L) begin              // LDR
            dec_is_load = 1'b1;
            dec_reg_wen = 1'b1;
          end else begin               // STR
            dec_mem_wen = 1'b1;
          end
        end // op=01

        //--------------op=10: Branch B / BL ------------------
        2'b10: begin
          if (instr[27:25] == 3'b101) begin
            dec_is_branch = 1'b1;
            if (instr[24]) begin   // bit24=1 -> BL
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



endmodule