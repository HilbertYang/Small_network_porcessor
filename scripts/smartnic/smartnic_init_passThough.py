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
            g("imem_write", "cpu", str(pc), "%08x" % 0xe0000000)

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
