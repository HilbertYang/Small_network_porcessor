#!/usr/bin/env python
# smartnic_passThrough_init.py - initialize CPU for FIFO pass-through
#
# CPU program from fifo_passThrough_imem.txt:
#   PC 0: 0xa0000000   (FIFO pass-through start)
#   PC 1: 0xe0000000   (NOP)
#   PC 2: 0xab000000   (FIFODONE)
#   PC 3: 0xeafffffd   (B -3, loop back to PC 0)
#
# GPU IMEM is left empty (no GPU kernel needed for pass-through).
# DMEM is not initialized (no data arrays needed).

import os
import subprocess
import sys

THIS_DIR = os.path.dirname(os.path.abspath(__file__))
CPUGPUREG = os.path.join(THIS_DIR, "cpugpureg.py")
PYTHON = sys.executable or "python"

CPU_GPU_BASE = 0x2000100
CTRL_REG     = CPU_GPU_BASE + 0x00


# ---------------------------------------------------------------------------
# Shell helpers
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
# CPU instruction encoders
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
def cpu_rdf(rd, sel):          # {8'b10101111, Rd, 19'b0, sel}
    return 0xAF000000 | ((rd & 0xf) << 20) | (sel & 0x1)
def cpu_fifowait():            # {8'b10101100, 24'b0}
    return 0xAC000000
def cpu_fifodone():            # {8'b10101011, 24'b0}
    return 0xAB000000


# ---------------------------------------------------------------------------
# GPU instruction encoders
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
def gpu_add_i16(rd, rs1, rs2): # {5'h01, rd, rs1, rs2, 15'h0}
    return (0x01 << 27) | ((rd & 0xf) << 23) | ((rs1 & 0xf) << 19) | ((rs2 & 0xf) << 15)
def gpu_sub_i16(rd, rs1, rs2): # {5'h02, rd, rs1, rs2, 15'h0}
    return (0x02 << 27) | ((rd & 0xf) << 23) | ((rs1 & 0xf) << 19) | ((rs2 & 0xf) << 15)
def gpu_max_i16(rd, rs1, rs2): # {5'h03, rd, rs1, rs2, 15'h0}
    return (0x03 << 27) | ((rd & 0xf) << 23) | ((rs1 & 0xf) << 19) | ((rs2 & 0xf) << 15)
def gpu_add64(rd, rs1, rs2):   # {5'h04, rd, rs1, rs2, 15'h0}
    return (0x04 << 27) | ((rd & 0xf) << 23) | ((rs1 & 0xf) << 19) | ((rs2 & 0xf) << 15)
def gpu_mac_bf16(rd, rs1, rs2): # {5'h09, rd, rs1, rs2, 15'h0}
    return (0x09 << 27) | ((rd & 0xf) << 23) | ((rs1 & 0xf) << 19) | ((rs2 & 0xf) << 15)
def gpu_mul_bf16(rd, rs1, rs2): # {5'h0a, rd, rs1, rs2, 15'h0}
    return (0x0a << 27) | ((rd & 0xf) << 23) | ((rs1 & 0xf) << 19) | ((rs2 & 0xf) << 15)
def gpu_ret():                 # {5'h15, 27'h0}
    return (0x15 << 27)


# ---------------------------------------------------------------------------
# CPU IMEM program (imem_sel = 1)
# From fifo_passThrough_imem.txt
# ---------------------------------------------------------------------------
CPU_MAIN = [
    (0, 0xa0000000),
    (1, 0xe0000000),
    (2, 0xab000000),
    (3, 0xeafffffd),
]

# Interrupt vector area NOPs
_NOP_RANGES = [
    range(128, 150),
    range(256, 276),
    range(384, 404),
]


def main():
    write_line("\n=== CTRL CLEAR ===\n")
    ctrl_clear_all()

    # ------------------------------------------------------------------
    # Phase 1: GPU IMEM - skipped (no GPU kernel for pass-through)
    # ------------------------------------------------------------------
    write_line("\n=== PHASE 1: GPU IMEM skipped (pass-through, no GPU kernel) ===\n")

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
    # Phase 3: DMEM - skipped (no data arrays for pass-through)
    # ------------------------------------------------------------------
    write_line("\n=== PHASE 3: DMEM skipped (pass-through, no data init) ===\n")

    write_line("\n=== PC RESET ===\n")
    g("pcreset")
    g("dbg")

    write_line("\n=== INIT DONE ===\n")
    write_line("Run with:  cpugpureg.py run 1")
    write_line("Check with: cpugpureg.py done_check")
    write_line("           cpugpureg.py allregs")


if __name__ == "__main__":
    main()
