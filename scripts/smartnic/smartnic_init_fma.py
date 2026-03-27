#!/usr/bin/env python
# cpugpu_init.py - initialize CPU+GPU for MAC_BF16 FMA kernel
#
# Mirrors the stimulus in sim/cpu_gpu/tb_smallest_test_fma.v:
#   Phase 1: Program GPU IMEM  (imem_sel=0)  - MAC_BF16 kernel
#   Phase 2: Program CPU IMEM  (imem_sel=1)  - param setup + GPURUN
#   Phase 3: Initialize DMEM   - BF16 arrays A(0), B(10), C(20)

import os
import subprocess
import sys

THIS_DIR = os.path.dirname(os.path.abspath(__file__))
CPUGPUREG = os.path.join(THIS_DIR, "smartnic_reg.py")
PYTHON = sys.executable or "python"

CPU_GPU_BASE = 0x2000100
CTRL_REG     = CPU_GPU_BASE + 0x00


# ---------------------------------------------------------------------------
# Shell helpers (same style as updated gpureg.py)
# ---------------------------------------------------------------------------

def write_line(text):
    sys.stdout.write("%s\n" % text)


def run_cmd(argv):
    printable = " ".join(argv)
    write_line(">> %s" % printable)
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out, err = proc.communicate()
    if proc.returncode != 0:
        raise SystemExit("Failed: %s" % printable)


def g(*args):
    run_cmd([PYTHON, CPUGPUREG] + list(args))


def ctrl_clear_all():
    run_cmd(["regwrite", "0x%08x" % CTRL_REG, "0x00000000"])


# ---------------------------------------------------------------------------
# CPU instruction encoders  (match tb_smallest_test_fma.v functions)
# ---------------------------------------------------------------------------

def cpu_nop():                 # 32'hE000_0000
    return 0xE0000000
def cpu_mov(rd, imm8):         # {4'hE, 3'b001, 4'b1101, 1'b0, 4'h0, rd, 4'h0, imm8}
    return 0xE3A00000 | ((rd & 0xf) << 12) | (imm8 & 0xff)
def cpu_wrp(rs, imm3):         # {8'b10101110, rs, 17'b0, imm3}
    return 0xAE000000 | ((rs & 0xf) << 20) | (imm3 & 0x7)
def cpu_gpurun():              # {8'b10101101, 24'b0}
    return 0xAD000000
def cpu_b(off24):              # {4'hE, 8'hEA, off24}
    return 0xEA000000 | (off24 & 0xFFFFFF)


# ---------------------------------------------------------------------------
# GPU instruction encoders  (match tb_smallest_test_fma.v functions)
# ---------------------------------------------------------------------------

def gpu_nop():                 # 32'h0000_0000
    return 0x00000000
def gpu_ld_param(rd, imm3):    # {5'h16, rd, 4'h0, 4'h0, 12'h0, imm3}
    return (0x16 << 27) | ((rd & 0xf) << 23) | (imm3 & 0x7)
def gpu_mov(rd, imm15):        # {5'h12, rd, 4'h0, 4'h0, imm15}
    return (0x12 << 27) | ((rd & 0xf) << 23) | (imm15 & 0x7fff)
def gpu_setp_ge(rs1, rs2):     # {5'h06, 4'h0, rs1, rs2, 15'h0}
    return (0x06 << 27) | ((rs1 & 0xf) << 19) | ((rs2 & 0xf) << 15)
def gpu_bpr(target):           # {5'h13, 4'h0, 4'h0, 4'h0, 6'h0, target[8:0]}
    return (0x13 << 27) | (target & 0x1ff)
def gpu_br(target):            # {5'h14, 4'h0, 4'h0, 4'h0, 6'h0, target[8:0]}
    return (0x14 << 27) | (target & 0x1ff)
def gpu_ld64(rd, rs1, imm15):  # {5'h10, rd, rs1, 4'h0, imm15}
    return (0x10 << 27) | ((rd & 0xf) << 23) | ((rs1 & 0xf) << 19) | (imm15 & 0x7fff)
def gpu_st64(rd, rs1, imm15):  # {5'h11, rd, rs1, 4'h0, imm15}
    return (0x11 << 27) | ((rd & 0xf) << 23) | ((rs1 & 0xf) << 19) | (imm15 & 0x7fff)
def gpu_addi64(rd, rs1, imm15): # {5'h05, rd, rs1, 4'h0, imm15}
    return (0x05 << 27) | ((rd & 0xf) << 23) | ((rs1 & 0xf) << 19) | (imm15 & 0x7fff)
def gpu_mac_bf16(rd, rs1, rs2): # {5'h09, rd, rs1, rs2, 15'h0}
    return (0x09 << 27) | ((rd & 0xf) << 23) | ((rs1 & 0xf) << 19) | ((rs2 & 0xf) << 15)
def gpu_ret():                 # {5'h15, 27'h0}
    return (0x15 << 27)


# ---------------------------------------------------------------------------
# GPU IMEM program  (imem_sel = 0)
# Exact encoding from tb_smallest_test_fma.v Phase 1
#
# Kernel: C[i] = A[i] * B[i] + C[i]  (4×BF16 MAC, 3 loop iterations)
# PARAM[1]=0 (A base), PARAM[2]=10 (B base), PARAM[3]=20 (C base), PARAM[4]=11 (limit)
#
# PC 15: BR 7 has two delay slots: PC16 (R5+=4), PC17 (ST64 C[R3])
# PC 18: R3++ runs before next loop iteration (not a delay slot of BPR)
# ---------------------------------------------------------------------------
GPU_PROG = [
    (0,  gpu_ld_param(1, 1)),        # R1 = PARAM[1]  (A base addr)
    (1,  gpu_ld_param(2, 2)),        # R2 = PARAM[2]  (B base addr)
    (2,  gpu_ld_param(3, 3)),        # R3 = PARAM[3]  (C base addr)
    (3,  gpu_ld_param(4, 4)),        # R4 = PARAM[4]  (loop limit)
    (4,  gpu_mov(5, 0)),             # R5 = 0  (loop counter)
    (5,  gpu_nop()),                 # NOP (hazard slot after LD_PARAM)
    (6,  gpu_nop()),                 # NOP (hazard slot after LD_PARAM)
    (7,  gpu_setp_ge(5, 4)),         # PRED = (R5 >= R4)
    (8,  gpu_bpr(19)),               # if PRED goto 19 (RET)
    (9,  gpu_ld64(10, 1, 0)),        # R10 = DMEM[R1]  (load A word)
    (10, gpu_ld64(11, 2, 0)),        # R11 = DMEM[R2]  (load B word)
    (11, gpu_ld64(12, 3, 0)),        # R12 = DMEM[R3]  (load C accumulator)
    (12, gpu_addi64(1, 1, 1)),       # R1++
    (13, gpu_addi64(2, 2, 1)),       # R2++
    (14, gpu_mac_bf16(12, 10, 11)),  # R12 = R10 * R11 + R12  (MAC_BF16)
    (15, gpu_br(7)),                 # goto 7  (delay slots: PC16, PC17)
    (16, gpu_addi64(5, 5, 4)),       # [delay slot 1] R5 += 4
    (17, gpu_st64(12, 3, 0)),        # [delay slot 2] DMEM[R3] = R12
    (18, gpu_addi64(3, 3, 1)),       # R3++
    (19, gpu_ret()),                 # RET  (BPR exit target)
    (20, gpu_nop()),                 # NOP
]


# ---------------------------------------------------------------------------
# CPU IMEM program  (imem_sel = 1)
# Exact encoding from tb_smallest_test_fma.v Phase 2
#
# Sets GPU kernel params via WRP then issues GPURUN.
# The CPU interrupt vector area (PC 128, 256, 384) is cleared with NOPs.
# ---------------------------------------------------------------------------

# Main program (PC 0-13)
CPU_MAIN = [
    (0,   cpu_nop()),
    (1,   cpu_mov(3, 0)),          # MOV R3, #0
    (2,   cpu_wrp(3, 1)),          # WRP R3, #1  → param[1] = 0  (A base)
    (3,   cpu_mov(4, 10)),         # MOV R4, #10
    (4,   cpu_wrp(4, 2)),          # WRP R4, #2  → param[2] = 10 (B base)
    (5,   cpu_mov(5, 20)),         # MOV R5, #20
    (6,   cpu_wrp(5, 3)),          # WRP R5, #3  → param[3] = 20 (C base)
    (7,   cpu_mov(6, 11)),         # MOV R6, #11
    (8,   cpu_wrp(6, 4)),          # WRP R6, #4  → param[4] = 11 (loop limit)
    (9,   cpu_nop()),
    (10,  cpu_gpurun()),           # GPURUN - asserts gpu_run to GPU
    (11,  cpu_nop()),
    (12,  cpu_nop()),
    (13,  cpu_b(0xFFFFFE)),        # B -2  (spin forever)
]

# Interrupt vector area NOPs (match tb exactly)
_NOP_RANGES = [
    range(128, 150),
    range(256, 276),
    range(384, 404),
]


# ---------------------------------------------------------------------------
# DMEM initialization  (BF16 arrays A, B, C)
# Exact values from tb_smallest_test_fma.v Phase 3
#
#   A / B  (same values):
#     DMEM[ 0] = 0x4040_4000_3F80_0000  BF16: 3.0  2.0  1.0  1.0
#     DMEM[ 1] = 0x40E0_40C0_40A0_4080  BF16: 7.0  6.0  5.0  4.0
#     DMEM[ 2] = 0x4130_4120_4110_4100  BF16:11.0 10.0  9.0  8.0
#   C (initial accumulator = 1.0 for all lanes):
#     DMEM[20] = DMEM[21] = DMEM[22] = 0x3F80_3F80_3F80_3F80
# ---------------------------------------------------------------------------
DMEM_INIT = [
    (0,  "40404000", "3F800000"),
    (1,  "40E040C0", "40A04080"),
    (2,  "41304120", "41104100"),
    (10, "40404000", "3F800000"),
    (11, "40E040C0", "40A04080"),
    (12, "41304120", "41104100"),
    (20, "3F803F80", "3F803F80"),
    (21, "3F803F80", "3F803F80"),
    (22, "3F803F80", "3F803F80"),
]


def main():
    write_line("\n=== CTRL CLEAR ===\n")
    ctrl_clear_all()

    # ------------------------------------------------------------------
    # Phase 1: GPU IMEM
    # ------------------------------------------------------------------
    write_line("\n=== PHASE 1: Program GPU IMEM (imem_sel=0) ===\n")
    for pc, word in GPU_PROG:
        g("imem_write", "gpu", str(pc), "%08x" % word)

    # ------------------------------------------------------------------
    # Phase 2: CPU IMEM
    # ------------------------------------------------------------------
    write_line("\n=== PHASE 2: Program CPU IMEM (imem_sel=1) ===\n")
    for pc, word in CPU_MAIN:
        g("imem_write", "cpu", str(pc), "%08x" % word)
    for nop_range in _NOP_RANGES:
        for pc in nop_range:
            g("imem_write", "cpu", str(pc), "%08x" % cpu_nop())

    ctrl_clear_all()

    # ------------------------------------------------------------------
    # Phase 3: DMEM
    # ------------------------------------------------------------------
    write_line("\n=== PHASE 3: Initialize DMEM ===\n")
    for addr, hi, lo in DMEM_INIT:
        g("dmem_write", str(addr), hi, lo)

    write_line("\n=== PC RESET ===\n")
    g("pcreset")
    g("dbg")

    write_line("\n=== INIT DONE ===\n")
    write_line("Run with:  cpugpureg.py run 1")
    write_line("Check with: cpugpureg.py done_check")
    write_line("           cpugpureg.py allregs")


if __name__ == "__main__":
    main()
