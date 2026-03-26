#!/usr/bin/env python
import os
import subprocess
import sys

GPU_CTRL_REG = 0x2000000

A = 10
B = 11
C = 12

THIS_DIR = os.path.dirname(os.path.abspath(__file__))
GPUREG = os.path.join(THIS_DIR, "gpureg.py")
PYTHON = sys.executable or "python"


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


OP_LD_PARAM = 0x16
OP_MOV = 0x12
OP_SETP_GE = 0x06
OP_BPR = 0x13
OP_LD64 = 0x10
OP_ST64 = 0x11
OP_ADDI64 = 0x05
OP_ADD_I16 = 0x01
OP_BR = 0x14
OP_RET = 0x15

NOP = 0x00000000

PROG = [
    enc(OP_LD_PARAM, 1, 0, 0, 1),
    enc(OP_LD_PARAM, 2, 0, 0, 2),
    enc(OP_LD_PARAM, 3, 0, 0, 3),
    enc(OP_LD_PARAM, 4, 0, 0, 4),
    enc(OP_MOV, 5, 0, 0, 0),
    NOP,
    NOP,
    enc(OP_SETP_GE, 0, 5, 4, 0),
    enc(OP_BPR, 0, 0, 0, 18),
    enc(OP_LD64, A, 1, 0, 0),
    enc(OP_LD64, B, 2, 0, 0),
    enc(OP_ADDI64, 1, 1, 0, 1),
    enc(OP_ADDI64, 2, 2, 0, 1),
    enc(OP_ADD_I16, C, A, B, 0),
    enc(OP_BR, 0, 0, 0, 7),
    enc(OP_ADDI64, 5, 5, 0, 4),
    enc(OP_ST64, C, 3, 0, 0),
    enc(OP_ADDI64, 3, 3, 0, 1),
    enc(OP_RET, 0, 0, 0, 0),
]

DMEM_INIT = [
    [0, "0x0003_0002", "0x0001_0000"],
    [1, "0x0007_0006", "0x0005_0004"],
    [2, "0x000b_000a", "0x0009_0008"],
    [10, "0x0003_0002", "0x0001_0000"],
    [11, "0x0007_0006", "0x0005_0004"],
    [12, "0x000b_000a", "0x0009_0008"],
    [20, "0x0000_0000", "0x0000_0000"],
    [21, "0x0000_0000", "0x0000_0000"],
    [22, "0x0000_0000", "0x0000_0000"],
    [23, "0x0000_0000", "0x0000_0000"],
]

PARAM_INIT = [
    [1, "0", "0"],
    [2, "0", "a"],
    [3, "0", "14"],
    [4, "0", "b"],
]


def main():
    write_line("")
    write_line("=== CTRL CLEAR ===")
    write_line("")
    ctrl_clear_all()

    write_line("")
    write_line("=== INIT DMEM ===")
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


if __name__ == "__main__":
    main()
