#!/usr/bin/env python
import os
import subprocess
import sys

THIS_DIR = os.path.dirname(os.path.abspath(__file__))
GPUREG = os.path.join(THIS_DIR, "gpureg.py")
PYTHON = sys.executable or "python"

def write_line(text):
    sys.stdout.write("%s\n" % text)


def run_process(argv):
    return subprocess.Popen(argv).wait()


try:
    input_func = raw_input
except NameError:
    input_func = input


def g(*args):
    argv = [PYTHON, GPUREG] + list(args)
    if run_process(argv) != 0:
        raise SystemExit("Failed: %s" % " ".join(argv))


def do_steps(count):
    for _ in range(count):
        g("step")
    g("dbg")


def main():
    write_line("=== GPU Interactive Stepper ===")
    write_line("Commands:")
    write_line("  <n>       step N cycles then show PC/instr")
    write_line("  d <addr>  read DMEM[addr]")
    write_line("  done      check done flag")
    write_line("  dbg       show PC + IF_INSTR")
    write_line("  q         quit")
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
            write_line("--- stepping %s cycle(s) ---" % count)
            do_steps(count)
        elif line.startswith("d "):
            parts = line.split(None, 1)
            if len(parts) == 2:
                g("dmem_read", parts[1])
            else:
                write_line("Unknown command: %s" % line)
        elif line == "done":
            g("done_check")
        elif line == "dbg":
            g("dbg")
        else:
            write_line("Unknown command: %s" % line)

    write_line("Bye.")


if __name__ == "__main__":
    main()
