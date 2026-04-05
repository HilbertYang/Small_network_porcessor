#!/usr/bin/env python
# gpu_init_ECG.py
# Initialise GPU for ECG beat classifier (64-dim -> 2-class, 4 beats SIMD)
#
# DMEM layout:
#   [  0.. 63]  features: DMEM[i] = {X4[i], X3[i], X2[i], X1[i]}
#   [ 64..127]  W1:       DMEM[64+i] = {W1[i] x4}
#   [128..191]  W2:       DMEM[128+i] = {W2[i] x4}
#   [192]       bias1 x4  (read-only)
#   [193]       bias2 x4  (read-only)
#   [194]       logit1 x4 (written by epilogue ST64)
#   [195]       logit2 x4 (written by epilogue ST64)
#
# Param registers:
#   P1=0  (base_X), P2=64 (base_W1), P3=128 (base_W2),
#   P4=64 (loop count), P5=192 (bias1 addr), P6=193 (bias2 addr),
#   P7=194 (logit1 store addr)  -- logit2 addr = P7+1 computed in-kernel
import os
import subprocess
import sys

GPU_CTRL_REG = 0x2000000

THIS_DIR = os.path.dirname(os.path.abspath(__file__))
GPUREG   = os.path.join(THIS_DIR, "gpureg.py")
PYTHON   = sys.executable or "python"


def write_line(text):
    sys.stdout.write("%s\n" % text)


def run_process(argv):
    return subprocess.Popen(argv).wait()


def run_cmd(argv):
    printable = " ".join(argv)
    write_line(">> %s" % printable)
    if run_process(argv) != 0:
        raise SystemExit("Failed: %s" % printable)


def g(*args):
    run_cmd([PYTHON, GPUREG] + list(args))


def ctrl_clear_all():
    run_cmd(["regwrite", "0x%08x" % GPU_CTRL_REG, "0x%08x" % 0])


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
# ECG classifier program  (32 instructions, addr 0-31)
#
# Prologue  (addr  0-12): load params, compute R9, load biases into accumulators
# Loop      (addr 13-27): 64 iterations of MAC_BF16 for logit1 and logit2
# Epilogue  (addr 28-31): store logits, RET
# ---------------------------------------------------------------------------
PROG = [
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
    # addr  8-9: NOPs (gap for R8@6 before ADDI64@10)
    NOP,
    NOP,
    # addr 10: R9 = R8+1 (logit2 store addr = 195)
    enc(OP_ADDI64,   9,  8, 0, 1),
    # addr 11: R12 = DMEM[R6+0] = bias1 (logit1 accumulator)
    enc(OP_LD64,     12, 6, 0, 0),
    # addr 12: R13 = DMEM[R7+0] = bias2 (logit2 accumulator)
    enc(OP_LD64,     13, 7, 0, 0),

    # --- Loop top = addr 13 ---
    # addr 13: predicate = (R5 >= R4)
    enc(OP_SETP_GE,  0,  5, 4, 0),
    # addr 14: if predicate, branch to epilogue (addr 28)
    enc(OP_BPR,      0,  0, 0, 28),
    # addr 15-17: branch delay slots
    # addr 15: R10 = DMEM[R1+0] = X[i]
    enc(OP_LD64,     10, 1, 0, 0),
    # addr 16: R11 = DMEM[R2+0] = W1[i]
    enc(OP_LD64,     11, 2, 0, 0),
    # addr 17: R14 = DMEM[R3+0] = W2[i]
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

# ---------------------------------------------------------------------------
# DMEM init: [addr, hi_32, lo_32]  (all values are 32-bit hex strings)
# Each 64-bit word is split: hi = bits[63:32], lo = bits[31:0]
# ---------------------------------------------------------------------------
DMEM_INIT = [
    # --- Features: DMEM[i] = {X4[i], X3[i], X2[i], X1[i]} ---
    [  0, "0x3E073F29", "0x3E0E3F1D"],
    [  1, "0x3D1C3F1A", "0x3D613F03"],
    [  2, "0x3E3E3E3F", "0x3D973E42"],
    [  3, "0x3E213D15", "0x3E1D3D2E"],
    [  4, "0x3E7B3E0E", "0x3E4B3DE2"],
    [  5, "0x3D683F3F", "0x3E043F1F"],
    [  6, "0x3E613E2E", "0x3E843DB5"],
    [  7, "0x3EB13E25", "0x3EA03DD6"],
    [  8, "0x3D973F13", "0x3DB33F08"],
    [  9, "0x3E803D06", "0x3E953D11"],
    [ 10, "0x3D263F20", "0x3DEA3F26"],
    [ 11, "0x3E043ECF", "0x3DD23EC4"],
    [ 12, "0x3EB33D80", "0x3ED33D4B"],
    [ 13, "0x3E883E1D", "0x3E123DAB"],
    [ 14, "0x3E6E3DC5", "0x3E5E3D74"],
    [ 15, "0x3EB73DA3", "0x3EDB3DB5"],
    [ 16, "0x3E973DA8", "0x3EA33CE8"],
    [ 17, "0x3E5C3D09", "0x3E9E3D7F"],
    [ 18, "0x3EC13E0D", "0x3F093DBA"],
    [ 19, "0x3C253F33", "0x3D403F09"],
    [ 20, "0x3E6A3E43", "0x3E453DB6"],
    [ 21, "0x3DAE3EF0", "0x3E2E3EFE"],
    [ 22, "0x3E023F13", "0x3E1B3F01"],
    [ 23, "0x3E993DCD", "0x3EA13D2B"],
    [ 24, "0x3EC73DD6", "0x3EBC3DDF"],
    [ 25, "0x3E233F2A", "0x3E5D3F0B"],
    [ 26, "0x3EF63D34", "0x3F013D1B"],
    [ 27, "0x3D053F13", "0x3D503ED9"],
    [ 28, "0x3E793DAC", "0x3E453CF3"],
    [ 29, "0x3D9D3F0C", "0x3D3D3EFA"],
    [ 30, "0x3ECA3E8B", "0x3EB13E51"],
    [ 31, "0x3E843E0F", "0x3EAB3D9E"],
    [ 32, "0x3E983D80", "0x3EB03D4A"],
    [ 33, "0x3E043EAD", "0x3D953EA8"],
    [ 34, "0x3E913E36", "0x3EAC3D95"],
    [ 35, "0x3E883E03", "0x3E893DF6"],
    [ 36, "0x3E913E59", "0x3E763D2D"],
    [ 37, "0x3EA93DD6", "0x3EA53DBF"],
    [ 38, "0x3ED73D7E", "0x3EF63CFB"],
    [ 39, "0x3D943F55", "0x3E393F43"],
    [ 40, "0x3E793DDB", "0x3E813D68"],
    [ 41, "0x3E093D29", "0x3E133D1A"],
    [ 42, "0x3EA53D84", "0x3ECD3CF9"],
    [ 43, "0x3E823D8B", "0x3E3B3D8D"],
    [ 44, "0x3EA13E88", "0x3E9E3E09"],
    [ 45, "0x3E5D3EE5", "0x3E183EBC"],
    [ 46, "0x3D8A3F07", "0x3DEF3F00"],
    [ 47, "0x3EBF3D90", "0x3EC03D99"],
    [ 48, "0x3ED13D51", "0x3EDC3D15"],
    [ 49, "0x3DB13F10", "0x3D513F02"],
    [ 50, "0x3DBC3F1E", "0x3E2A3F07"],
    [ 51, "0x3E5D3E84", "0x3E033E99"],
    [ 52, "0x3EC63E4A", "0x3E8E3DC4"],
    [ 53, "0x3C483F29", "0x3DCA3F27"],
    [ 54, "0x3E563E90", "0x3E473E12"],
    [ 55, "0x3EBD3DCC", "0x3EA03D4A"],
    [ 56, "0x3EC43EC1", "0x3EBD3E76"],
    [ 57, "0x3E023F08", "0x3E2D3F0D"],
    [ 58, "0x3EE53E52", "0x3EF23DFE"],
    [ 59, "0x3E283F07", "0x3E083F03"],
    [ 60, "0x3C783F32", "0x3DA83F30"],
    [ 61, "0x3E343E16", "0x3EA13D9E"],
    [ 62, "0x3EEC3E47", "0x3F173DFE"],
    [ 63, "0x3D3F3F0E", "0x3E123F05"],
    # --- W1: DMEM[64+i] = {W1[i] x4} ---
    [ 64, "0xBF13BF13", "0xBF13BF13"],
    [ 65, "0xBF1FBF1F", "0xBF1FBF1F"],
    [ 66, "0xBF2DBF2D", "0xBF2DBF2D"],
    [ 67, "0x3F0D3F0D", "0x3F0D3F0D"],
    [ 68, "0x3F043F04", "0x3F043F04"],
    [ 69, "0xBF36BF36", "0xBF36BF36"],
    [ 70, "0x3F143F14", "0x3F143F14"],
    [ 71, "0x3F203F20", "0x3F203F20"],
    [ 72, "0xBEFCBEFC", "0xBEFCBEFC"],
    [ 73, "0x3F0C3F0C", "0x3F0C3F0C"],
    [ 74, "0xBF0EBF0E", "0xBF0EBF0E"],
    [ 75, "0xBF06BF06", "0xBF06BF06"],
    [ 76, "0x3F063F06", "0x3F063F06"],
    [ 77, "0x3F133F13", "0x3F133F13"],
    [ 78, "0x3EB33EB3", "0x3EB33EB3"],
    [ 79, "0x3EB13EB1", "0x3EB13EB1"],
    [ 80, "0x3ED13ED1", "0x3ED13ED1"],
    [ 81, "0x3EF93EF9", "0x3EF93EF9"],
    [ 82, "0x3EB63EB6", "0x3EB63EB6"],
    [ 83, "0xBF38BF38", "0xBF38BF38"],
    [ 84, "0x3F083F08", "0x3F083F08"],
    [ 85, "0xBF0ABF0A", "0xBF0ABF0A"],
    [ 86, "0xBF1EBF1E", "0xBF1EBF1E"],
    [ 87, "0x3EF13EF1", "0x3EF13EF1"],
    [ 88, "0x3ECC3ECC", "0x3ECC3ECC"],
    [ 89, "0xBF0BBF0B", "0xBF0BBF0B"],
    [ 90, "0x3EDE3EDE", "0x3EDE3EDE"],
    [ 91, "0xBF3FBF3F", "0xBF3FBF3F"],
    [ 92, "0x3EB73EB7", "0x3EB73EB7"],
    [ 93, "0xBF0ABF0A", "0xBF0ABF0A"],
    [ 94, "0x3ED03ED0", "0x3ED03ED0"],
    [ 95, "0x3EA43EA4", "0x3EA43EA4"],
    [ 96, "0x3EE23EE2", "0x3EE23EE2"],
    [ 97, "0xBF13BF13", "0xBF13BF13"],
    [ 98, "0x3F093F09", "0x3F093F09"],
    [ 99, "0x3F113F11", "0x3F113F11"],
    [100, "0x3EFD3EFD", "0x3EFD3EFD"],
    [101, "0x3F083F08", "0x3F083F08"],
    [102, "0x3EAC3EAC", "0x3EAC3EAC"],
    [103, "0xBF0ABF0A", "0xBF0ABF0A"],
    [104, "0x3F023F02", "0x3F023F02"],
    [105, "0x3F1E3F1E", "0x3F1E3F1E"],
    [106, "0x3EE93EE9", "0x3EE93EE9"],
    [107, "0x3EFF3EFF", "0x3EFF3EFF"],
    [108, "0x3EF43EF4", "0x3EF43EF4"],
    [109, "0xBF21BF21", "0xBF21BF21"],
    [110, "0xBF29BF29", "0xBF29BF29"],
    [111, "0x3ED53ED5", "0x3ED53ED5"],
    [112, "0x3F003F00", "0x3F003F00"],
    [113, "0xBF2DBF2D", "0xBF2DBF2D"],
    [114, "0xBF4ABF4A", "0xBF4ABF4A"],
    [115, "0xBF21BF21", "0xBF21BF21"],
    [116, "0x3ED43ED4", "0x3ED43ED4"],
    [117, "0xBF2EBF2E", "0xBF2EBF2E"],
    [118, "0x3F0F3F0F", "0x3F0F3F0F"],
    [119, "0x3EE33EE3", "0x3EE33EE3"],
    [120, "0x3EE23EE2", "0x3EE23EE2"],
    [121, "0xBF19BF19", "0xBF19BF19"],
    [122, "0x3ECE3ECE", "0x3ECE3ECE"],
    [123, "0xBF10BF10", "0xBF10BF10"],
    [124, "0xBF41BF41", "0xBF41BF41"],
    [125, "0x3F0F3F0F", "0x3F0F3F0F"],
    [126, "0x3EA33EA3", "0x3EA33EA3"],
    [127, "0xBF2BBF2B", "0xBF2BBF2B"],
    # --- W2: DMEM[128+i] = {W2[i] x4} ---
    [128, "0x3F0E3F0E", "0x3F0E3F0E"],
    [129, "0x3F2C3F2C", "0x3F2C3F2C"],
    [130, "0x3F2B3F2B", "0x3F2B3F2B"],
    [131, "0xBF00BF00", "0xBF00BF00"],
    [132, "0xBF13BF13", "0xBF13BF13"],
    [133, "0x3F263F26", "0x3F263F26"],
    [134, "0xBF00BF00", "0xBF00BF00"],
    [135, "0xBEE3BEE3", "0xBEE3BEE3"],
    [136, "0x3F2E3F2E", "0x3F2E3F2E"],
    [137, "0xBF00BF00", "0xBF00BF00"],
    [138, "0x3F123F12", "0x3F123F12"],
    [139, "0x3F293F29", "0x3F293F29"],
    [140, "0xBED0BED0", "0xBED0BED0"],
    [141, "0xBF02BF02", "0xBF02BF02"],
    [142, "0xBEF8BEF8", "0xBEF8BEF8"],
    [143, "0xBEA3BEA3", "0xBEA3BEA3"],
    [144, "0xBEEEBEEE", "0xBEEEBEEE"],
    [145, "0xBEEDBEED", "0xBEEDBEED"],
    [146, "0xBF07BF07", "0xBF07BF07"],
    [147, "0x3F423F42", "0x3F423F42"],
    [148, "0xBF01BF01", "0xBF01BF01"],
    [149, "0x3F133F13", "0x3F133F13"],
    [150, "0x3F203F20", "0x3F203F20"],
    [151, "0xBEFABEFA", "0xBEFABEFA"],
    [152, "0xBEFBBEFB", "0xBEFBBEFB"],
    [153, "0x3F3B3F3B", "0x3F3B3F3B"],
    [154, "0xBEF8BEF8", "0xBEF8BEF8"],
    [155, "0x3F353F35", "0x3F353F35"],
    [156, "0xBF0DBF0D", "0xBF0DBF0D"],
    [157, "0x3F303F30", "0x3F303F30"],
    [158, "0xBE87BE87", "0xBE87BE87"],
    [159, "0xBEDABEDA", "0xBEDABEDA"],
    [160, "0xBEA9BEA9", "0xBEA9BEA9"],
    [161, "0x3F2D3F2D", "0x3F2D3F2D"],
    [162, "0xBED5BED5", "0xBED5BED5"],
    [163, "0xBED6BED6", "0xBED6BED6"],
    [164, "0xBEEABEEA", "0xBEEABEEA"],
    [165, "0xBEF2BEF2", "0xBEF2BEF2"],
    [166, "0xBF02BF02", "0xBF02BF02"],
    [167, "0x3F123F12", "0x3F123F12"],
    [168, "0xBEC5BEC5", "0xBEC5BEC5"],
    [169, "0xBEF4BEF4", "0xBEF4BEF4"],
    [170, "0xBEEEBEEE", "0xBEEEBEEE"],
    [171, "0xBF0CBF0C", "0xBF0CBF0C"],
    [172, "0xBF05BF05", "0xBF05BF05"],
    [173, "0x3F3C3F3C", "0x3F3C3F3C"],
    [174, "0x3F323F32", "0x3F323F32"],
    [175, "0xBEDEBEDE", "0xBEDEBEDE"],
    [176, "0xBEA9BEA9", "0xBEA9BEA9"],
    [177, "0x3F133F13", "0x3F133F13"],
    [178, "0x3F253F25", "0x3F253F25"],
    [179, "0x3F3E3F3E", "0x3F3E3F3E"],
    [180, "0xBEA3BEA3", "0xBEA3BEA3"],
    [181, "0x3F303F30", "0x3F303F30"],
    [182, "0xBF1ABF1A", "0xBF1ABF1A"],
    [183, "0xBEDBBEDB", "0xBEDBBEDB"],
    [184, "0xBEF0BEF0", "0xBEF0BEF0"],
    [185, "0x3F453F45", "0x3F453F45"],
    [186, "0xBE8EBE8E", "0xBE8EBE8E"],
    [187, "0x3F143F14", "0x3F143F14"],
    [188, "0x3F363F36", "0x3F363F36"],
    [189, "0xBF07BF07", "0xBF07BF07"],
    [190, "0xBEC9BEC9", "0xBEC9BEC9"],
    [191, "0x3F2A3F2A", "0x3F2A3F2A"],
    # --- Biases (initialise logit accumulators; read-only during inference) ---
    [192, "0xBE39BE39", "0xBE39BE39"],  # bias1 = BE39 (-0.1807) x4
    [193, "0x3E0E3E0E", "0x3E0E3E0E"],  # bias2 = 3E0E (+0.1387) x4
    # --- Logit output slots (overwritten by epilogue ST64s) ---
    [194, "0x00000000", "0x00000000"],  # logit1 placeholder
    [195, "0x00000000", "0x00000000"],  # logit2 placeholder
]

# ---------------------------------------------------------------------------
# Param register init: [addr, hi_hex_str, lo_hex_str]
#   P1=0  (base_X),  P2=64 (base_W1), P3=128 (base_W2),
#   P4=64 (loop count), P5=192 (bias1 addr), P6=193 (bias2 addr),
#   P7=194 (logit1 store addr)
# ---------------------------------------------------------------------------
PARAM_INIT = [
    [1, "0", "0"],    # P1 = 0
    [2, "0", "40"],   # P2 = 64
    [3, "0", "80"],   # P3 = 128
    [4, "0", "40"],   # P4 = 64
    [5, "0", "c0"],   # P5 = 192
    [6, "0", "c1"],   # P6 = 193
    [7, "0", "c2"],   # P7 = 194
]


def main():
    write_line("")
    write_line("=== CTRL CLEAR ===")
    write_line("")
    ctrl_clear_all()

    write_line("")
    write_line("=== INIT DMEM (features, W1, W2, biases) ===")
    write_line("")
    for addr, hi, lo in DMEM_INIT:
        g("dmem_write", str(addr), hi, lo)

    ctrl_clear_all()

    write_line("")
    write_line("=== INIT PARAM ===")
    write_line("")
    for addr, hi, lo in PARAM_INIT:
        g("param_write", str(addr), hi, lo)

    write_line("")
    write_line("=== PROGRAM IMEM ===")
    write_line("")
    for pc, word in enumerate(PROG):
        g("imem_write", str(pc), "%08x" % word)

    write_line("")
    write_line("=== PC RESET ===")
    write_line("")
    g("pcreset")
    g("dbg")

    write_line("")
    write_line("=== INIT DONE ===")
    write_line("")
    write_line("Expected results after run:")
    write_line("  DMEM[192] = BE39BE39BE39BE39  (bias1, unchanged)")
    write_line("  DMEM[193] = 3E0E3E0E3E0E3E0E  (bias2, unchanged)")
    write_line("  DMEM[194] = 4073C0D54066C0D9  (logit1: beat4=4073, beat3=C0D5, beat2=4066, beat1=C0D9)")
    write_line("  DMEM[195] = C05F40E7C05A40EA  (logit2: beat4=C05F, beat3=40E7, beat2=C05A, beat1=40EA)")
    write_line("  Predicted classes: beat1=1, beat2=0, beat3=1, beat4=0")


if __name__ == "__main__":
    main()
