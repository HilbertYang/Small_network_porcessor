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
#   [  0.. 99]  reserved for X + header headroom; X filled by network (FIFO)
#   [100..163]  W1:    DMEM[100+i] = {W1[i] x4}
#   [164..227]  W2:    DMEM[164+i] = {W2[i] x4}
#   [228]       bias1 x4  (read-only)
#   [229]       bias2 x4  (read-only)
#   [230]       logit1 x4 (written by epilogue ST64)
#   [231]       logit2 x4 (written by epilogue ST64)
#
# Param registers (set by CPU via FIFOWAIT/RDF/WRP instructions):
#   P1 = fifo_start_offset  (base_X, dynamic -- read by CPU via RDF)
#   P2 = 100  (base_W1)
#   P3 = 164  (base_W2)
#   P4 = 64   (loop count)
#   P5 = 228  (bias1 addr)
#   P6 = 229  (bias2 addr)
#   P7 = 230  (logit1 store addr)  -- logit2 addr = P7+1 computed in-kernel

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
def cpu_rdf(rd, sel):          # RDF Rd, #sel  (0=fifo_start_offset, 1=fifo_end_offset)
    return 0xAF000000 | ((rd & 0xf) << 20) | (sel & 0x1)
def cpu_fifowait():            # FIFOWAIT  (stall until fifo_data_ready)
    return 0xAC000000
def cpu_fifodone():            # FIFODONE  (pulse fifo_data_done)
    return 0xAB000000
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
    # addr 28: DMEM[R8+0] = R12  (write logit1 to DMEM[230])
    enc(OP_ST64,     12, 8, 0, 0),
    # addr 29: DMEM[R9+0] = R13  (write logit2 to DMEM[231])
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
# Sequence:
#   1. FIFOWAIT        -- stall until network packet data is ready
#   2. NOP
#   3. RDF R3, #0      -- read fifo_start_offset (X base addr) into R3
#   4. NOP
#   5. WRP R3, #1      -- param[1] = X base (dynamic)
#   6. NOP + MOV+WRP x6, each separated by a NOP (hazard gap)
#   7. GPURUN          -- launch GPU (CPU stalls until gpu_done via GPU_interface)
#   8. NOP
#   9. FIFODONE        -- pulse fifo_data_done to signal packet processing complete
#  (no branch -- CPU falls through into NOP sled after addr 33)
#
# Interrupt vector area (PC 128, 256, 384) cleared with NOPs.
# ---------------------------------------------------------------------------

# Main program (PC 0-33)
# One NOP inserted between every instruction to eliminate RAW hazards.
# The final B -2 spin is removed: after FIFODONE the CPU falls through into
# the NOP sled that fills the rest of IMEM, which is harmless.
CPU_MAIN = [
    (0,   cpu_nop()),
    (1,   cpu_fifowait()),         # FIFOWAIT -- stall until fifo_data_ready
    (2,   cpu_nop()),
    (3,   cpu_rdf(3, 0)),          # RDF R3, #0 -- R3 = fifo_start_offset (base_X)
    (4,   cpu_nop()),
    (5,   cpu_wrp(3, 1)),          # WRP R3, #1  - param[1] = base_X (dynamic)
    (6,   cpu_nop()),
    (7,   cpu_mov(4, 100)),        # MOV R4, #100
    (8,   cpu_nop()),
    (9,   cpu_wrp(4, 2)),          # WRP R4, #2  - param[2] = 100 (base_W1)
    (10,  cpu_nop()),
    (11,  cpu_mov(5, 164)),        # MOV R5, #164
    (12,  cpu_nop()),
    (13,  cpu_wrp(5, 3)),          # WRP R5, #3  - param[3] = 164 (base_W2)
    (14,  cpu_nop()),
    (15,  cpu_mov(6, 64)),         # MOV R6, #64
    (16,  cpu_nop()),
    (17,  cpu_wrp(6, 4)),          # WRP R6, #4  - param[4] = 64  (loop count)
    (18,  cpu_nop()),
    (19,  cpu_mov(7, 228)),        # MOV R7, #228
    (20,  cpu_nop()),
    (21,  cpu_wrp(7, 5)),          # WRP R7, #5  - param[5] = 228 (bias1 addr)
    (22,  cpu_nop()),
    (23,  cpu_mov(8, 229)),        # MOV R8, #229
    (24,  cpu_nop()),
    (25,  cpu_wrp(8, 6)),          # WRP R8, #6  - param[6] = 229 (bias2 addr)
    (26,  cpu_nop()),
    (27,  cpu_mov(9, 230)),        # MOV R9, #230
    (28,  cpu_nop()),
    (29,  cpu_wrp(9, 7)),          # WRP R9, #7  - param[7] = 230 (logit1 store addr)
    (30,  cpu_nop()),
    (31,  cpu_gpurun()),           # GPURUN -- CPU stalls until gpu_done
    (32,  cpu_nop()),
    (33,  cpu_fifodone()),         # FIFODONE -- signal packet processing complete
]

# Interrupt vector area NOPs
_NOP_RANGES = [
    range(128, 150),
    range(256, 276),
    range(384, 404),
]


# ---------------------------------------------------------------------------
# DMEM initialization: (addr, hi_hex, lo_hex)
#   [  0.. 99]  reserved for X + header headroom (NOT written here)
#   [100..163]  W1:    DMEM[100+i] = {W1[i] x4}
#   [164..227]  W2:    DMEM[164+i] = {W2[i] x4}
#   [228]       bias1 x4  (BE39 = -0.1807)
#   [229]       bias2 x4  (3E0E = +0.1387)
#   [230..231]  logit output slots
# ---------------------------------------------------------------------------
DMEM_INIT = [
    # DMEM[0..99]: reserved for X (filled by network) + header headroom
    # --- W1: DMEM[100+i] = {W1[i] x4} ---
    (100, "0xBF13BF13", "0xBF13BF13"),
    (101, "0xBF1FBF1F", "0xBF1FBF1F"),
    (102, "0xBF2DBF2D", "0xBF2DBF2D"),
    (103, "0x3F0D3F0D", "0x3F0D3F0D"),
    (104, "0x3F043F04", "0x3F043F04"),
    (105, "0xBF36BF36", "0xBF36BF36"),
    (106, "0x3F143F14", "0x3F143F14"),
    (107, "0x3F203F20", "0x3F203F20"),
    (108, "0xBEFCBEFC", "0xBEFCBEFC"),
    (109, "0x3F0C3F0C", "0x3F0C3F0C"),
    (110, "0xBF0EBF0E", "0xBF0EBF0E"),
    (111, "0xBF06BF06", "0xBF06BF06"),
    (112, "0x3F063F06", "0x3F063F06"),
    (113, "0x3F133F13", "0x3F133F13"),
    (114, "0x3EB33EB3", "0x3EB33EB3"),
    (115, "0x3EB13EB1", "0x3EB13EB1"),
    (116, "0x3ED13ED1", "0x3ED13ED1"),
    (117, "0x3EF93EF9", "0x3EF93EF9"),
    (118, "0x3EB63EB6", "0x3EB63EB6"),
    (119, "0xBF38BF38", "0xBF38BF38"),
    (120, "0x3F083F08", "0x3F083F08"),
    (121, "0xBF0ABF0A", "0xBF0ABF0A"),
    (122, "0xBF1EBF1E", "0xBF1EBF1E"),
    (123, "0x3EF13EF1", "0x3EF13EF1"),
    (124, "0x3ECC3ECC", "0x3ECC3ECC"),
    (125, "0xBF0BBF0B", "0xBF0BBF0B"),
    (126, "0x3EDE3EDE", "0x3EDE3EDE"),
    (127, "0xBF3FBF3F", "0xBF3FBF3F"),
    (128, "0x3EB73EB7", "0x3EB73EB7"),
    (129, "0xBF0ABF0A", "0xBF0ABF0A"),
    (130, "0x3ED03ED0", "0x3ED03ED0"),
    (131, "0x3EA43EA4", "0x3EA43EA4"),
    (132, "0x3EE23EE2", "0x3EE23EE2"),
    (133, "0xBF13BF13", "0xBF13BF13"),
    (134, "0x3F093F09", "0x3F093F09"),
    (135, "0x3F113F11", "0x3F113F11"),
    (136, "0x3EFD3EFD", "0x3EFD3EFD"),
    (137, "0x3F083F08", "0x3F083F08"),
    (138, "0x3EAC3EAC", "0x3EAC3EAC"),
    (139, "0xBF0ABF0A", "0xBF0ABF0A"),
    (140, "0x3F023F02", "0x3F023F02"),
    (141, "0x3F1E3F1E", "0x3F1E3F1E"),
    (142, "0x3EE93EE9", "0x3EE93EE9"),
    (143, "0x3EFF3EFF", "0x3EFF3EFF"),
    (144, "0x3EF43EF4", "0x3EF43EF4"),
    (145, "0xBF21BF21", "0xBF21BF21"),
    (146, "0xBF29BF29", "0xBF29BF29"),
    (147, "0x3ED53ED5", "0x3ED53ED5"),
    (148, "0x3F003F00", "0x3F003F00"),
    (149, "0xBF2DBF2D", "0xBF2DBF2D"),
    (150, "0xBF4ABF4A", "0xBF4ABF4A"),
    (151, "0xBF21BF21", "0xBF21BF21"),
    (152, "0x3ED43ED4", "0x3ED43ED4"),
    (153, "0xBF2EBF2E", "0xBF2EBF2E"),
    (154, "0x3F0F3F0F", "0x3F0F3F0F"),
    (155, "0x3EE33EE3", "0x3EE33EE3"),
    (156, "0x3EE23EE2", "0x3EE23EE2"),
    (157, "0xBF19BF19", "0xBF19BF19"),
    (158, "0x3ECE3ECE", "0x3ECE3ECE"),
    (159, "0xBF10BF10", "0xBF10BF10"),
    (160, "0xBF41BF41", "0xBF41BF41"),
    (161, "0x3F0F3F0F", "0x3F0F3F0F"),
    (162, "0x3EA33EA3", "0x3EA33EA3"),
    (163, "0xBF2BBF2B", "0xBF2BBF2B"),
    # --- W2: DMEM[164+i] = {W2[i] x4} ---
    (164, "0x3F0E3F0E", "0x3F0E3F0E"),
    (165, "0x3F2C3F2C", "0x3F2C3F2C"),
    (166, "0x3F2B3F2B", "0x3F2B3F2B"),
    (167, "0xBF00BF00", "0xBF00BF00"),
    (168, "0xBF13BF13", "0xBF13BF13"),
    (169, "0x3F263F26", "0x3F263F26"),
    (170, "0xBF00BF00", "0xBF00BF00"),
    (171, "0xBEE3BEE3", "0xBEE3BEE3"),
    (172, "0x3F2E3F2E", "0x3F2E3F2E"),
    (173, "0xBF00BF00", "0xBF00BF00"),
    (174, "0x3F123F12", "0x3F123F12"),
    (175, "0x3F293F29", "0x3F293F29"),
    (176, "0xBED0BED0", "0xBED0BED0"),
    (177, "0xBF02BF02", "0xBF02BF02"),
    (178, "0xBEF8BEF8", "0xBEF8BEF8"),
    (179, "0xBEA3BEA3", "0xBEA3BEA3"),
    (180, "0xBEEEBEEE", "0xBEEEBEEE"),
    (181, "0xBEEDBEED", "0xBEEDBEED"),
    (182, "0xBF07BF07", "0xBF07BF07"),
    (183, "0x3F423F42", "0x3F423F42"),
    (184, "0xBF01BF01", "0xBF01BF01"),
    (185, "0x3F133F13", "0x3F133F13"),
    (186, "0x3F203F20", "0x3F203F20"),
    (187, "0xBEFABEFA", "0xBEFABEFA"),
    (188, "0xBEFBBEFB", "0xBEFBBEFB"),
    (189, "0x3F3B3F3B", "0x3F3B3F3B"),
    (190, "0xBEF8BEF8", "0xBEF8BEF8"),
    (191, "0x3F353F35", "0x3F353F35"),
    (192, "0xBF0DBF0D", "0xBF0DBF0D"),
    (193, "0x3F303F30", "0x3F303F30"),
    (194, "0xBE87BE87", "0xBE87BE87"),
    (195, "0xBEDABEDA", "0xBEDABEDA"),
    (196, "0xBEA9BEA9", "0xBEA9BEA9"),
    (197, "0x3F2D3F2D", "0x3F2D3F2D"),
    (198, "0xBED5BED5", "0xBED5BED5"),
    (199, "0xBED6BED6", "0xBED6BED6"),
    (200, "0xBEEABEEA", "0xBEEABEEA"),
    (201, "0xBEF2BEF2", "0xBEF2BEF2"),
    (202, "0xBF02BF02", "0xBF02BF02"),
    (203, "0x3F123F12", "0x3F123F12"),
    (204, "0xBEC5BEC5", "0xBEC5BEC5"),
    (205, "0xBEF4BEF4", "0xBEF4BEF4"),
    (206, "0xBEEEBEEE", "0xBEEEBEEE"),
    (207, "0xBF0CBF0C", "0xBF0CBF0C"),
    (208, "0xBF05BF05", "0xBF05BF05"),
    (209, "0x3F3C3F3C", "0x3F3C3F3C"),
    (210, "0x3F323F32", "0x3F323F32"),
    (211, "0xBEDEBEDE", "0xBEDEBEDE"),
    (212, "0xBEA9BEA9", "0xBEA9BEA9"),
    (213, "0x3F133F13", "0x3F133F13"),
    (214, "0x3F253F25", "0x3F253F25"),
    (215, "0x3F3E3F3E", "0x3F3E3F3E"),
    (216, "0xBEA3BEA3", "0xBEA3BEA3"),
    (217, "0x3F303F30", "0x3F303F30"),
    (218, "0xBF1ABF1A", "0xBF1ABF1A"),
    (219, "0xBEDBBEDB", "0xBEDBBEDB"),
    (220, "0xBEF0BEF0", "0xBEF0BEF0"),
    (221, "0x3F453F45", "0x3F453F45"),
    (222, "0xBE8EBE8E", "0xBE8EBE8E"),
    (223, "0x3F143F14", "0x3F143F14"),
    (224, "0x3F363F36", "0x3F363F36"),
    (225, "0xBF07BF07", "0xBF07BF07"),
    (226, "0xBEC9BEC9", "0xBEC9BEC9"),
    (227, "0x3F2A3F2A", "0x3F2A3F2A"),
    # --- Biases (initialise logit accumulators; read-only during inference) ---
    (228, "0xBE39BE39", "0xBE39BE39"),  # bias1 = BE39 (-0.1807) x4
    (229, "0x3E0E3E0E", "0x3E0E3E0E"),  # bias2 = 3E0E (+0.1387) x4
    # --- Logit output slots (overwritten by epilogue ST64s) ---
    (230, "0x00000000", "0x00000000"),  # logit1 placeholder
    (231, "0x00000000", "0x00000000"),  # logit2 placeholder
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
    write_line("  DMEM[228] = BE39BE39BE39BE39  (bias1, unchanged)")
    write_line("  DMEM[229] = 3E0E3E0E3E0E3E0E  (bias2, unchanged)")
    write_line("  DMEM[230] = 4073C0D54066C0D9  (logit1: beat4=4073, beat3=C0D5, beat2=4066, beat1=C0D9)")
    write_line("  DMEM[231] = C05F40E7C05A40EA  (logit2: beat4=C05F, beat3=40E7, beat2=C05A, beat1=40EA)")
    write_line("  Predicted classes: beat1=1, beat2=0, beat3=1, beat4=0")


if __name__ == "__main__":
    main()
