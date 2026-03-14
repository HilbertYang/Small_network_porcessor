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
my $OP_LD_PARAM = 0x16;
my $OP_MOV      = 0x12;
my $OP_SETP_GE  = 0x06;
my $OP_BPR      = 0x13;
my $OP_LD64     = 0x10;
my $OP_ST64     = 0x11;
my $OP_ADDI64   = 0x05;
my $OP_ADD_I16  = 0x01;
my $OP_BR       = 0x14;
my $OP_RET      = 0x15;

my $NOP = 0x0000_0000;

# -------- readable program --------
# Pipeline: IF->ID->EX->MEM->WB, with internal forwarding
# BR/BPR resolve in EX -> 2 delay slots (ID + IF stages drain)
# BRAM registered output -> 1 extra fetch cycle -> total 3 delay slots
#
# Hazard notes (forwarding covers most; r3 hazard is intentional):
#   ADDI64 r3 (#15) -> ST64 reads r3 (#16): 0-gap, INTENTIONAL
#     ST64 sees old r3 -> stores to DMEM[20/21/22] (pre-increment address)
my @prog = (
  ENC($OP_LD_PARAM ,1,0,0,1),   #0  r1 = param[1] = src_A_ptr
  ENC($OP_LD_PARAM ,2,0,0,2),   #1  r2 = param[2] = src_B_ptr
  ENC($OP_LD_PARAM ,3,0,0,3),   #2  r3 = param[3] = dst_C_ptr
  ENC($OP_LD_PARAM ,4,0,0,4),   #3  r4 = param[4] = count
  ENC($OP_MOV      ,5,0,0,0),   #4  r5 = 0  (loop counter)
  $NOP,                         #5
  $NOP,                         #6
  ENC($OP_SETP_GE  ,0,5,4,0),   #7  pred = (r5 >= r4)   <- LOOP TOP
  ENC($OP_BPR      ,0,0,0,18),  #8  if pred -> RET (#18)
  ENC($OP_LD64     ,A,1,0,0),   #9  BPR-ds1: r10 = DMEM[r1]
  ENC($OP_LD64     ,B,2,0,0),   #10 BPR-ds2: r11 = DMEM[r2]
  ENC($OP_ADDI64   ,1,1,0,1),   #11 BPR-ds3: r1 += 1
  ENC($OP_ADDI64   ,2,2,0,1),   #12 r2 += 1
  ENC($OP_ADD_I16  ,C,A,B,0),   #13 r12 = r10 + r11
  ENC($OP_BR       ,0,0,0,7),   #14 loop back to #7
  ENC($OP_ADDI64   ,5,5,0,4),   #15 BR-ds1: r5 += 4
  ENC($OP_ST64     ,C,3,0,0),   #16 BR-ds2: DMEM[old_r3] = r12
  ENC($OP_ADDI64   ,3,3,0,1),   #17 BR-ds3: r3 += 1  (intentional hazard -> ST64 uses old r3)
  ENC($OP_RET      ,0,0,0,0),   #18
);

my @dmem_init = (
  [0,  "0x0003_0002", "0x0001_0000"],
  [1,  "0x0007_0006", "0x0005_0004"],
  [2,  "0x000b_000a", "0x0009_0008"],
  [10, "0x0003_0002", "0x0001_0000"],
  [11, "0x0007_0006", "0x0005_0004"],
  [12, "0x000b_000a", "0x0009_0008"],
  [20, "0x0000_0000", "0x0000_0000"],
  [21, "0x0000_0000", "0x0000_0000"],
  [22, "0x0000_0000", "0x0000_0000"],
  [23, "0x0000_0000", "0x0000_0000"],
);

my @param_init = (
  [1, "0", "0"],   # src_A_ptr = 0
  [2, "0", "a"],   # src_B_ptr = 0xa = 10
  [3, "0", "14"],  # dst_C_ptr = 0x14 = 20
  [4, "0", "b"],   # count     = 0xb  = 11
);

print "\n=== CTRL CLEAR ===\n";
ctrl_clear_all();

print "\n=== INIT DMEM ===\n";
for my $w (@dmem_init) {
  my ($a,$hi,$lo) = @$w;
  g("dmem_write $a $hi $lo");
}

# IMPORTANT: release dmem_prog_en so core can use DMEM
ctrl_clear_all();

print "\n=== INIT PARAM ===\n";
for my $p (@param_init) {
  my ($a,$hi,$lo) = @$p;
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