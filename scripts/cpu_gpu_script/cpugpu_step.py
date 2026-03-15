#!/usr/bin/env python
# cpugpu_step.py — interactive stepper for CPU+GPU subsystem

import os
import subprocess
import sys

THIS_DIR = os.path.dirname(os.path.abspath(__file__))
CPUGPUREG = os.path.join(THIS_DIR, "cpugpureg.py")
PYTHON = sys.executable or "python"

try:
    input_func = raw_input
except NameError:
    input_func = input


def write_line(text):
    sys.stdout.write("%s\n" % text)


def g(*args):
    argv = [PYTHON, CPUGPUREG] + list(args)
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out, err = proc.communicate()
    if out:
        sys.stdout.write(out if isinstance(out, str) else out.decode("utf-8"))
    if proc.returncode != 0:
        raise SystemExit("Failed: %s" % " ".join(argv))


def do_steps(count):
    for _ in range(count):
        g("step")
    g("dbg")


def main():
    write_line("=== CPU+GPU Interactive Stepper ===")
    write_line("Commands:")
    write_line("  <n>           step N cycles then show CPU+GPU PC/instr")
    write_line("  d <addr>      read DMEM[addr] (64-bit)")
    write_line("  done          check GPU done flag")
    write_line("  fdone         check CPU fifo_data_done flag")
    write_line("  hb            read heartbeat counter")
    write_line("  dbg           show CPU+GPU PC + IF_INSTR")
    write_line("  all           dump all HW status regs")
    write_line("  q             quit")
    write_line("")

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
                write_line("Enter a positive integer.")
                continue
            write_line("--- stepping %d cycle(s) ---" % count)
            do_steps(count)
        elif line.startswith("d "):
            parts = line.split(None, 1)
            if len(parts) == 2:
                g("dmem_read", parts[1])
            else:
                write_line("Usage: d <addr>")
        elif line == "done":
            g("done_check")
        elif line == "fdone":
            g("fifo_done_check")
        elif line == "hb":
            g("hb")
        elif line == "dbg":
            g("dbg")
        elif line == "all":
            g("allregs")
        else:
            write_line("Unknown command: %s" % line)

    write_line("Bye.")


if __name__ == "__main__":
    main()
