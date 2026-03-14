#!/usr/bin/env python
from __future__ import print_function
import os
import subprocess
import sys

THIS_DIR = os.path.dirname(os.path.abspath(__file__))
GPUREG = os.path.join(THIS_DIR, "gpureg.py")
PYTHON = sys.executable or "python"

try:
    input_func = raw_input
except NameError:
    input_func = input


def g(*args):
    argv = [PYTHON, GPUREG] + list(args)
    if subprocess.call(argv) != 0:
        raise SystemExit("Failed: {}".format(" ".join(argv)))


def do_steps(count):
    for _ in range(count):
        g("step")
    g("dbg")


def main():
    print("=== GPU Interactive Stepper ===")
    print("Commands:")
    print("  <n>       step N cycles then show PC/instr")
    print("  d <addr>  read DMEM[addr]")
    print("  done      check done flag")
    print("  dbg       show PC + IF_INSTR")
    print("  q         quit")
    print("")

    while True:
        try:
            line = input_func("step> ")
        except EOFError:
            break

        line = line.strip()
        if not line:
            continue

        if line in ("q", "quit"):
            break
        elif line.isdigit():
            count = int(line)
            if count < 1:
                print("Enter a positive integer.")
                continue
            print("--- stepping {} cycle(s) ---".format(count))
            do_steps(count)
        elif line.startswith("d "):
            parts = line.split(None, 1)
            if len(parts) == 2:
                g("dmem_read", parts[1])
            else:
                print("Unknown command: {}".format(line))
        elif line == "done":
            g("done_check")
        elif line == "dbg":
            g("dbg")
        else:
            print("Unknown command: {}".format(line))

    print("Bye.")


if __name__ == "__main__":
    main()
