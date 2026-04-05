#!/usr/bin/env python
# smartnic_init_ECG.py - initialize CPU+GPU for ECG beat classifier kernel
#
# ECG classifier: 64-dim -> 2-class logistic regression, 4 beats SIMD (BF16 MAC)
#
#   Phase 1: Program GPU IMEM  (imem_sel=0)  - ECG classifier kernel
#   Phase 2: Program CPU IMEM  (imem_sel=1)  - param setup via WRP + GPURUN
#   Phase 3: Initialize DMEM   - features, W1, W2, biases, logit slots
#
# DMEM layout:
#   [  0.. 63]  features: filled by network (FIFO) at runtime -- NOT written here
#   [ 64..127]  W1:       DMEM[64+i] = {W1[i] x4}
#   [128..191]  W2:       DMEM[128+i] = {W2[i] x4}
#   [192]       bias1 x4  (read-only)
#   [193]       bias2 x4  (read-only)
#   [194]       logit1 x4 (written by epilogue ST64)
#   [195]       logit2 x4 (written by epilogue ST64)
#
# Param registers (set by CPU WRP instructions):
#   P1=0  (base_X), P2=64 (base_W1), P3=128 (base_W2),
#   P4=64 (loop count), P5=192 (bias1 addr), P6=193 (bias2 addr),
#   P7=194 (logit1 store addr)  -- logit2 addr = P7+1 computed in-kernel

import os
import subprocess
import sys

THIS_DIR = os.path.dirname(os.path.abspath(__file__))
CPUGPUREG = os.path.join(THIS_DIR, "smartnic_reg.py")
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
def cpu_mov(rd, imm8):         # MOV Rd, #imm8
    return 0xE3A00000 | ((rd & 0xf) << 12) | (imm8 & 0xff)
def cpu_wrp(rs, imm3):         # WRP Rs, #imm3  (write GPU param[imm3] = Rs)
    return 0xAE000000 | ((rs & 0xf) << 20) | (imm3 & 0x7)
def cpu_gpurun():              # GPURUN
    return 0xAD000000
def cpu_b(off24):              # B off24
    return 0xEA000000 | (off24 & 0xFFFFFF)


# ---------------------------------------------------------------------------
# GPU instruction encoders
# ---------------------------------------------------------------------------

def enc(op, rd, rs1, rs2, imm15):
    imm15 &= 0x7fff
    return ((op & 0x1f) << 27) | ((rd & 0x0f) << 23) | ((rs1 & 0x0f) << 19) | ((rs2 & 0x0f) << 15) | imm15

OP_NOP      = 0x00
OP_ADDI64   = 0x05
OP_SETP_GE  = 0x06
OP_MAC_BF16 = 0x09
OP_LD64     = 0x10
OP_ST64     = 0x11
OP_MOV      = 0x12
OP_BPR      = 0x13
OP_BR       = 0x14
OP_RET      = 0x15
OP_LD_PARAM = 0x16

NOP = 0x00000000


# ---------------------------------------------------------------------------
# GPU IMEM program  (imem_sel = 0)
#
# Prologue  (addr  0-12): load params, compute R9, load biases into accumulators
# Loop      (addr 13-27): 64 iterations of MAC_BF16 for logit1 and logit2
# Epilogue  (addr 28-31): store logits, RET
# ---------------------------------------------------------------------------
_GPU_PROG_WORDS = [
    # addr  0: R1  = P1 (base_X = 0)
    enc(OP_LD_PARAM, 1,  0, 0, 1),
    # addr  1: R2  = P2 (base_W1 = 64)
    enc(OP_LD_PARAM, 2,  0, 0, 2),
    # addr  2: R3  = P3 (base_W2 = 128)
    enc(OP_LD_PARAM, 3,  0, 0, 3),
    # addr  3: R4  = P4 (loop limit = 64)
    enc(OP_LD_PARAM, 4,  0, 0, 4),
    # addr  4: R6  = P5 (bias1 load addr = 192)
    enc(OP_LD_PARAM, 6,  0, 0, 5),
    # addr  5: R7  = P6 (bias2 load addr = 193)
    enc(OP_LD_PARAM, 7,  0, 0, 6),
    # addr  6: R8  = P7 (logit1 store addr = 194)
    enc(OP_LD_PARAM, 8,  0, 0, 7),
    # addr  7: R5  = 0  (loop counter)
    enc(OP_MOV,      5,  0, 0, 0),
    # addr  8-9: NOPs (hazard gap for R8@6 before ADDI64@10)
    NOP,
    NOP,
    # addr 10: R9 = R8+1 (logit2 store addr = 195)
    enc(OP_ADDI64,   9,  8, 0, 1),
    # addr 11: R12 = DMEM[R6+0] = bias1  (logit1 accumulator)
    enc(OP_LD64,     12, 6, 0, 0),
    # addr 12: R13 = DMEM[R7+0] = bias2  (logit2 accumulator)
    enc(OP_LD64,     13, 7, 0, 0),

    # --- Loop top = addr 13 ---
    # addr 13: predicate = (R5 >= R4)
    enc(OP_SETP_GE,  0,  5, 4, 0),
    # addr 14: if predicate, branch to epilogue (addr 28)
    enc(OP_BPR,      0,  0, 0, 28),
    # addr 15: [branch delay slot] R10 = DMEM[R1+0] = X[i]
    enc(OP_LD64,     10, 1, 0, 0),
    # addr 16: [branch delay slot] R11 = DMEM[R2+0] = W1[i]
    enc(OP_LD64,     11, 2, 0, 0),
    # addr 17: [branch delay slot] R14 = DMEM[R3+0] = W2[i]
    enc(OP_LD64,     14, 3, 0, 0),
    # addr 18: R1++ (advance feature pointer)
    enc(OP_ADDI64,   1,  1, 0, 1),
    # addr 19: R2++ (advance W1 pointer)
    enc(OP_ADDI64,   2,  2, 0, 1),
    # addr 20: R3++ (advance W2 pointer)
    enc(OP_ADDI64,   3,  3, 0, 1),
    # addr 21: R5++ (increment loop counter)
    enc(OP_ADDI64,   5,  5, 0, 1),
    # addr 22: R12 += R10 * R11  (logit1 += X[i] * W1[i])
    enc(OP_MAC_BF16, 12, 10, 11, 0),
    # addr 23: R13 += R10 * R14  (logit2 += X[i] * W2[i])
    enc(OP_MAC_BF16, 13, 10, 14, 0),
    # addr 24: branch back to loop top (addr 13)
    enc(OP_BR,       0,  0, 0, 13),
    # addr 25-27: branch delay slots
    NOP,
    NOP,
    NOP,

    # --- Epilogue (addr 28) ---
    # addr 28: DMEM[R8+0] = R12  (write logit1 to DMEM[194])
    enc(OP_ST64,     12, 8, 0, 0),
    # addr 29: DMEM[R9+0] = R13  (write logit2 to DMEM[195])
    enc(OP_ST64,     13, 9, 0, 0),
    # addr 30: RET
    enc(OP_RET,      0,  0, 0, 0),
    # addr 31: drain NOP
    NOP,
]

GPU_PROG = list(enumerate(_GPU_PROG_WORDS))


# ---------------------------------------------------------------------------
# CPU IMEM program  (imem_sel = 1)
#
# Sets GPU kernel params via WRP then issues GPURUN.
# Interrupt vector area (PC 128, 256, 384) cleared with NOPs.
# ---------------------------------------------------------------------------

# Main program (PC 0-19)
CPU_MAIN = [
    (0,   cpu_nop()),
    (1,   cpu_mov(3, 0)),          # MOV R3, #0
    (2,   cpu_wrp(3, 1)),          # WRP R3, #1  → param[1] = 0   (base_X)
    (3,   cpu_mov(4, 64)),         # MOV R4, #64
    (4,   cpu_wrp(4, 2)),          # WRP R4, #2  → param[2] = 64  (base_W1)
    (5,   cpu_mov(5, 128)),        # MOV R5, #128
    (6,   cpu_wrp(5, 3)),          # WRP R5, #3  → param[3] = 128 (base_W2)
    (7,   cpu_mov(6, 64)),         # MOV R6, #64
    (8,   cpu_wrp(6, 4)),          # WRP R6, #4  → param[4] = 64  (loop count)
    (9,   cpu_mov(7, 192)),        # MOV R7, #192
    (10,  cpu_wrp(7, 5)),          # WRP R7, #5  → param[5] = 192 (bias1 addr)
    (11,  cpu_mov(8, 193)),        # MOV R8, #193
    (12,  cpu_wrp(8, 6)),          # WRP R8, #6  → param[6] = 193 (bias2 addr)
    (13,  cpu_mov(9, 194)),        # MOV R9, #194
    (14,  cpu_wrp(9, 7)),          # WRP R9, #7  → param[7] = 194 (logit1 store addr)
    (15,  cpu_nop()),
    (16,  cpu_gpurun()),           # GPURUN - asserts gpu_run to GPU
    (17,  cpu_nop()),
    (18,  cpu_nop()),
    (19,  cpu_b(0xFFFFFE)),        # B -2  (spin forever)
]

# Interrupt vector area NOPs
_NOP_RANGES = [
    range(128, 150),
    range(256, 276),
    range(384, 404),
]


# ---------------------------------------------------------------------------
# DMEM initialization: (addr, hi_hex, lo_hex)
#   [  0.. 63]  features: NOT written here -- filled by network (FIFO) at runtime
#   [ 64..127]  W1:       DMEM[64+i] = {W1[i] x4}
#   [128..191]  W2:       DMEM[128+i] = {W2[i] x4}
#   [192]       bias1 x4  (BE39 = -0.1807)
#   [193]       bias2 x4  (3E0E = +0.1387)
#   [194..195]  logit output slots
# ---------------------------------------------------------------------------
DMEM_INIT = [
    # DMEM[0..63]: features X -- left empty; filled by network (FIFO) at runtime
    # --- W1: DMEM[64+i] = {W1[i] x4} ---
    ( 64, "0xBF13BF13", "0xBF13BF13"),
    ( 65, "0xBF1FBF1F", "0xBF1FBF1F"),
    ( 66, "0xBF2DBF2D", "0xBF2DBF2D"),
    ( 67, "0x3F0D3F0D", "0x3F0D3F0D"),
    ( 68, "0x3F043F04", "0x3F043F04"),
    ( 69, "0xBF36BF36", "0xBF36BF36"),
    ( 70, "0x3F143F14", "0x3F143F14"),
    ( 71, "0x3F203F20", "0x3F203F20"),
    ( 72, "0xBEFCBEFC", "0xBEFCBEFC"),
    ( 73, "0x3F0C3F0C", "0x3F0C3F0C"),
    ( 74, "0xBF0EBF0E", "0xBF0EBF0E"),
    ( 75, "0xBF06BF06", "0xBF06BF06"),
    ( 76, "0x3F063F06", "0x3F063F06"),
    ( 77, "0x3F133F13", "0x3F133F13"),
    ( 78, "0x3EB33EB3", "0x3EB33EB3"),
    ( 79, "0x3EB13EB1", "0x3EB13EB1"),
    ( 80, "0x3ED13ED1", "0x3ED13ED1"),
    ( 81, "0x3EF93EF9", "0x3EF93EF9"),
    ( 82, "0x3EB63EB6", "0x3EB63EB6"),
    ( 83, "0xBF38BF38", "0xBF38BF38"),
    ( 84, "0x3F083F08", "0x3F083F08"),
    ( 85, "0xBF0ABF0A", "0xBF0ABF0A"),
    ( 86, "0xBF1EBF1E", "0xBF1EBF1E"),
    ( 87, "0x3EF13EF1", "0x3EF13EF1"),
    ( 88, "0x3ECC3ECC", "0x3ECC3ECC"),
    ( 89, "0xBF0BBF0B", "0xBF0BBF0B"),
    ( 90, "0x3EDE3EDE", "0x3EDE3EDE"),
    ( 91, "0xBF3FBF3F", "0xBF3FBF3F"),
    ( 92, "0x3EB73EB7", "0x3EB73EB7"),
    ( 93, "0xBF0ABF0A", "0xBF0ABF0A"),
    ( 94, "0x3ED03ED0", "0x3ED03ED0"),
    ( 95, "0x3EA43EA4", "0x3EA43EA4"),
    ( 96, "0x3EE23EE2", "0x3EE23EE2"),
    ( 97, "0xBF13BF13", "0xBF13BF13"),
    ( 98, "0x3F093F09", "0x3F093F09"),
    ( 99, "0x3F113F11", "0x3F113F11"),
    (100, "0x3EFD3EFD", "0x3EFD3EFD"),
    (101, "0x3F083F08", "0x3F083F08"),
    (102, "0x3EAC3EAC", "0x3EAC3EAC"),
    (103, "0xBF0ABF0A", "0xBF0ABF0A"),
    (104, "0x3F023F02", "0x3F023F02"),
    (105, "0x3F1E3F1E", "0x3F1E3F1E"),
    (106, "0x3EE93EE9", "0x3EE93EE9"),
    (107, "0x3EFF3EFF", "0x3EFF3EFF"),
    (108, "0x3EF43EF4", "0x3EF43EF4"),
    (109, "0xBF21BF21", "0xBF21BF21"),
    (110, "0xBF29BF29", "0xBF29BF29"),
    (111, "0x3ED53ED5", "0x3ED53ED5"),
    (112, "0x3F003F00", "0x3F003F00"),
    (113, "0xBF2DBF2D", "0xBF2DBF2D"),
    (114, "0xBF4ABF4A", "0xBF4ABF4A"),
    (115, "0xBF21BF21", "0xBF21BF21"),
    (116, "0x3ED43ED4", "0x3ED43ED4"),
    (117, "0xBF2EBF2E", "0xBF2EBF2E"),
    (118, "0x3F0F3F0F", "0x3F0F3F0F"),
    (119, "0x3EE33EE3", "0x3EE33EE3"),
    (120, "0x3EE23EE2", "0x3EE23EE2"),
    (121, "0xBF19BF19", "0xBF19BF19"),
    (122, "0x3ECE3ECE", "0x3ECE3ECE"),
    (123, "0xBF10BF10", "0xBF10BF10"),
    (124, "0xBF41BF41", "0xBF41BF41"),
    (125, "0x3F0F3F0F", "0x3F0F3F0F"),
    (126, "0x3EA33EA3", "0x3EA33EA3"),
    (127, "0xBF2BBF2B", "0xBF2BBF2B"),
    # --- W2: DMEM[128+i] = {W2[i] x4} ---
    (128, "0x3F0E3F0E", "0x3F0E3F0E"),
    (129, "0x3F2C3F2C", "0x3F2C3F2C"),
    (130, "0x3F2B3F2B", "0x3F2B3F2B"),
    (131, "0xBF00BF00", "0xBF00BF00"),
    (132, "0xBF13BF13", "0xBF13BF13"),
    (133, "0x3F263F26", "0x3F263F26"),
    (134, "0xBF00BF00", "0xBF00BF00"),
    (135, "0xBEE3BEE3", "0xBEE3BEE3"),
    (136, "0x3F2E3F2E", "0x3F2E3F2E"),
    (137, "0xBF00BF00", "0xBF00BF00"),
    (138, "0x3F123F12", "0x3F123F12"),
    (139, "0x3F293F29", "0x3F293F29"),
    (140, "0xBED0BED0", "0xBED0BED0"),
    (141, "0xBF02BF02", "0xBF02BF02"),
    (142, "0xBEF8BEF8", "0xBEF8BEF8"),
    (143, "0xBEA3BEA3", "0xBEA3BEA3"),
    (144, "0xBEEEBEEE", "0xBEEEBEEE"),
    (145, "0xBEEDBEED", "0xBEEDBEED"),
    (146, "0xBF07BF07", "0xBF07BF07"),
    (147, "0x3F423F42", "0x3F423F42"),
    (148, "0xBF01BF01", "0xBF01BF01"),
    (149, "0x3F133F13", "0x3F133F13"),
    (150, "0x3F203F20", "0x3F203F20"),
    (151, "0xBEFABEFA", "0xBEFABEFA"),
    (152, "0xBEFBBEFB", "0xBEFBBEFB"),
    (153, "0x3F3B3F3B", "0x3F3B3F3B"),
    (154, "0xBEF8BEF8", "0xBEF8BEF8"),
    (155, "0x3F353F35", "0x3F353F35"),
    (156, "0xBF0DBF0D", "0xBF0DBF0D"),
    (157, "0x3F303F30", "0x3F303F30"),
    (158, "0xBE87BE87", "0xBE87BE87"),
    (159, "0xBEDABEDA", "0xBEDABEDA"),
    (160, "0xBEA9BEA9", "0xBEA9BEA9"),
    (161, "0x3F2D3F2D", "0x3F2D3F2D"),
    (162, "0xBED5BED5", "0xBED5BED5"),
    (163, "0xBED6BED6", "0xBED6BED6"),
    (164, "0xBEEABEEA", "0xBEEABEEA"),
    (165, "0xBEF2BEF2", "0xBEF2BEF2"),
    (166, "0xBF02BF02", "0xBF02BF02"),
    (167, "0x3F123F12", "0x3F123F12"),
    (168, "0xBEC5BEC5", "0xBEC5BEC5"),
    (169, "0xBEF4BEF4", "0xBEF4BEF4"),
    (170, "0xBEEEBEEE", "0xBEEEBEEE"),
    (171, "0xBF0CBF0C", "0xBF0CBF0C"),
    (172, "0xBF05BF05", "0xBF05BF05"),
    (173, "0x3F3C3F3C", "0x3F3C3F3C"),
    (174, "0x3F323F32", "0x3F323F32"),
    (175, "0xBEDEBEDE", "0xBEDEBEDE"),
    (176, "0xBEA9BEA9", "0xBEA9BEA9"),
    (177, "0x3F133F13", "0x3F133F13"),
    (178, "0x3F253F25", "0x3F253F25"),
    (179, "0x3F3E3F3E", "0x3F3E3F3E"),
    (180, "0xBEA3BEA3", "0xBEA3BEA3"),
    (181, "0x3F303F30", "0x3F303F30"),
    (182, "0xBF1ABF1A", "0xBF1ABF1A"),
    (183, "0xBEDBBEDB", "0xBEDBBEDB"),
    (184, "0xBEF0BEF0", "0xBEF0BEF0"),
    (185, "0x3F453F45", "0x3F453F45"),
    (186, "0xBE8EBE8E", "0xBE8EBE8E"),
    (187, "0x3F143F14", "0x3F143F14"),
    (188, "0x3F363F36", "0x3F363F36"),
    (189, "0xBF07BF07", "0xBF07BF07"),
    (190, "0xBEC9BEC9", "0xBEC9BEC9"),
    (191, "0x3F2A3F2A", "0x3F2A3F2A"),
    # --- Biases (initialise logit accumulators; read-only during inference) ---
    (192, "0xBE39BE39", "0xBE39BE39"),  # bias1 = BE39 (-0.1807) x4
    (193, "0x3E0E3E0E", "0x3E0E3E0E"),  # bias2 = 3E0E (+0.1387) x4
    # --- Logit output slots (overwritten by epilogue ST64s) ---
    (194, "0x00000000", "0x00000000"),  # logit1 placeholder
    (195, "0x00000000", "0x00000000"),  # logit2 placeholder
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
    write_line("Run with:  smartnic_reg.py run 1")
    write_line("Check with: smartnic_reg.py done_check")
    write_line("            smartnic_reg.py allregs")
    write_line("")
    write_line("Expected results after run:")
    write_line("  DMEM[192] = BE39BE39BE39BE39  (bias1, unchanged)")
    write_line("  DMEM[193] = 3E0E3E0E3E0E3E0E  (bias2, unchanged)")
    write_line("  DMEM[194] = 4073C0D54066C0D9  (logit1: beat4=4073, beat3=C0D5, beat2=4066, beat1=C0D9)")
    write_line("  DMEM[195] = C05F40E7C05A40EA  (logit2: beat4=C05F, beat3=40E7, beat2=C05A, beat1=40EA)")
    write_line("  Predicted classes: beat1=1, beat2=0, beat3=1, beat4=0")


if __name__ == "__main__":
    main()
