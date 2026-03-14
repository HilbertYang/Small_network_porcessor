#!/usr/bin/env perl
use strict;
use warnings;

my $GPUREG = "perl ./gpureg.pl";
my $GPU_CTRL_REG = 0x2000000;

use constant { A => 10, B => 11, C => 12 };

sub sh {
  my ($cmd) = @_;
  print ">> $cmd\n";
  system($cmd) == 0 or die "Failed: $cmd\n";
}
sub g { my ($cmd) = @_; sh("$GPUREG $cmd"); }

sub ctrl_clear_all {
  sh(sprintf("regwrite 0x%08x 0x%08x", $GPU_CTRL_REG, 0));
}

sub ENC {
  my ($op, $rd, $rs1, $rs2, $imm15) = @_;
  $imm15 &= 0x7fff;
  return (($op & 0x1f) << 27)
       | (($rd & 0x0f) << 23)
       | (($rs1 & 0x0f) << 19)
       | (($rs2 & 0x0f) << 15)
       |  ($imm15);
}

# Opcodes
my $OP_NOP      = 0x00;
my $OP_LD_PARAM = 0x16;
my $OP_MOV      = 0x12;
my $OP_SETP_GE  = 0x06;
my $OP_BPR      = 0x13;
my $OP_LD64     = 0x10;
my $OP_ST64     = 0x11;
my $OP_ADDI64   = 0x05;
my $OP_MAC_BF16 = 0x09;
my $OP_BR       = 0x14;
my $OP_RET      = 0x15;

my $NOP = 0x0000_0000;

# -------- FMA / MAC BF16 program --------
# Pipeline: IF->ID->EX->MEM->WB, no flushing, no forwarding
# NOP policy: 3 NOPs after every write instruction
# BR/BPR resolve in EX -> 3 delay slots (instructions following BR/BPR execute)
#
# Loop: for each element: R12 = R10 * R11 + R12  (MAC_BF16)
#   param[1] -> R1 : base address of array A (src)
#   param[2] -> R2 : base address of array B (src)
#   param[3] -> R3 : base address of array C (accumulator / output)
#   param[4] -> R4 : n (number of 64-bit words = 4xBF16 per word)
#   R5             : loop index (increments by 4 per iteration, exits when R5 >= R4)
#
# DMEM layout (64-bit words, each holds 4xBF16):
#   [0 .. 2 ] : array A  (bf16: 0,1,2,3 / 4,5,6,7 / 8,9,10,11)
#   [10..12 ] : array B  (bf16: same values)
#   [20..22 ] : array C  (initial 1.0, accumulates A*B+C per element)
#
# Expected results after 3 iterations (addresses 20,21,22):
#   DMEM[20] = 0x4120_40A0_4000_3F80  (bf16: 10, 5, 2, 1)
#   DMEM[21] = 0x4248_4214_41D0_4188  (bf16: 50, 37, 26, 17)
#   DMEM[22] = 0x42F4_42CA_42A4_4282  (bf16: 122, 101, 82, 65)

my @prog = (
  ENC($OP_LD_PARAM, 1, 0, 0, 1),    #0  R1 = param[1]  (src_A base ptr)
  ENC($OP_LD_PARAM, 2, 0, 0, 2),    #1  R2 = param[2]  (src_B base ptr)
  ENC($OP_LD_PARAM, 3, 0, 0, 3),    #2  R3 = param[3]  (dst_C base ptr)
  ENC($OP_LD_PARAM, 4, 0, 0, 4),    #3  R4 = param[4]  (n)
  ENC($OP_MOV,      5, 0, 0, 0),    #4  R5 = 0         (loop counter)
  $NOP,                              #5  NOP
  $NOP,                              #6  NOP
  # LOOP TOP (address 7)
  ENC($OP_SETP_GE,  0, 5, 4, 0),    #7  pred = (R5 >= R4)
  ENC($OP_BPR,      0, 0, 0, 19),   #8  if pred -> RET (addr 19)
  ENC($OP_LD64,    A,  1, 0, 0),    #9  BPR-ds1: R10 = DMEM[R1]
  ENC($OP_LD64,    B,  2, 0, 0),    #10 BPR-ds2: R11 = DMEM[R2]
  ENC($OP_LD64,    C,  3, 0, 0),    #11 BPR-ds3: R12 = DMEM[R3]
  ENC($OP_ADDI64,   1, 1, 0, 1),    #12 R1 += 1
  ENC($OP_ADDI64,   2, 2, 0, 1),    #13 R2 += 1
  ENC($OP_MAC_BF16, C, A, B, 0),    #14 R12 = R10 * R11 + R12
  ENC($OP_BR,       0, 0, 0, 7),    #15 branch back to LOOP TOP (addr 7)
  ENC($OP_ADDI64,   5, 5, 0, 4),    #16 BR-ds1: R5 += 4
  ENC($OP_ST64,     C, 3, 0, 0),    #17 BR-ds2: DMEM[R3] = R12 (result)
  ENC($OP_ADDI64,   3, 3, 0, 1),    #18 BR-ds3: R3 += 1
  # RET (address 19)
  ENC($OP_RET,      0, 0, 0, 0),    #19 DONE
);

# BF16 DMEM initial data  [addr, "hi_32bit_hex", "lo_32bit_hex"]
# Each 64-bit word packs 4 BF16 values: [hi_bf16 | lo_bf16] x2
#   0x3F80=1.0  0x4000=2.0  0x4040=3.0  0x4080=4.0
#   0x40A0=5.0  0x40C0=6.0  0x40E0=7.0  0x4100=8.0
#   0x4110=9.0  0x4120=10.0 0x4130=11.0
my @dmem_init = (
  # Array A (src)
  [ 0, "0x4040_4000", "0x3F80_0000"],  # bf16: 3,2,1,0
  [ 1, "0x40E0_40C0", "0x40A0_4080"],  # bf16: 7,6,5,4
  [ 2, "0x4130_4120", "0x4110_4100"],  # bf16: 11,10,9,8
  # Array B (src)
  [10, "0x4040_4000", "0x3F80_0000"],  # bf16: 3,2,1,0
  [11, "0x40E0_40C0", "0x40A0_4080"],  # bf16: 7,6,5,4
  [12, "0x4130_4120", "0x4110_4100"],  # bf16: 11,10,9,8
  # Array C (accumulator, initialised to 1.0 per element)
  [20, "0x3F80_3F80", "0x3F80_3F80"],  # bf16: 1,1,1,1
  [21, "0x3F80_3F80", "0x3F80_3F80"],  # bf16: 1,1,1,1
  [22, "0x3F80_3F80", "0x3F80_3F80"],  # bf16: 1,1,1,1
);

# param_init: [param_addr, hi_hex, lo_hex]
my @param_init = (
  [1, "0", "0"],    # src_A_ptr = DMEM addr 0
  [2, "0", "a"],    # src_B_ptr = DMEM addr 10 (0xa)
  [3, "0", "14"],   # dst_C_ptr = DMEM addr 20 (0x14)
  [4, "0", "b"],    # n         = 11 (0xb) -> 3 loop iterations (r5: 0,4,8 < 11)
);

print "\n=== CTRL CLEAR ===\n";
ctrl_clear_all();

print "\n=== INIT DMEM (BF16 arrays A, B, C) ===\n";
for my $w (@dmem_init) {
  my ($a, $hi, $lo) = @$w;
  g("dmem_write $a $hi $lo");
}

# Release dmem_prog_en so the core can access DMEM during execution
ctrl_clear_all();

print "\n=== INIT PARAM ===\n";
for my $p (@param_init) {
  my ($a, $hi, $lo) = @$p;
  g("param_write $a $hi $lo");
}

print "\n=== PROGRAM IMEM ===\n";
for (my $pc = 0; $pc < @prog; $pc++) {
  my $w = sprintf("%08x", $prog[$pc]);
  g("imem_write $pc $w");
}

print "\n=== PC RESET ===\n";
g("pcreset");
g("dbg");

print "\n=== INIT DONE ===\n";
