#!/usr/bin/env python
from __future__ import print_function
import sys
import re
import subprocess

GPU_BASE = 0x2000000

try:
    INTEGER_TYPES = (int, long)
except NameError:
    INTEGER_TYPES = (int,)

# SW regs
GPU_CTRL_REG          = GPU_BASE + 0x0
GPU_IMEM_ADDR_REG     = GPU_BASE + 0x4
GPU_IMEM_WDATA_REG    = GPU_BASE + 0x8
GPU_DMEM_ADDR_REG     = GPU_BASE + 0xc
GPU_DMEM_WDATA_LO_REG = GPU_BASE + 0x10
GPU_DMEM_WDATA_HI_REG = GPU_BASE + 0x14
GPU_PARAM_ADDR_REG    = GPU_BASE + 0x18
GPU_PARAM_DATA_LO_REG = GPU_BASE + 0x1c
GPU_PARAM_DATA_HI_REG = GPU_BASE + 0x20

# HW dbg regs
GPU_PC_DBG_REG        = GPU_BASE + 0x24
GPU_IF_INSTR_REG      = GPU_BASE + 0x28
GPU_DMEM_RDATA_LO_REG = GPU_BASE + 0x2c
GPU_DMEM_RDATA_HI_REG = GPU_BASE + 0x30
GPU_DONE              = GPU_BASE + 0x34

# ctrl reg bit assignments:
#   [0] run_level
#   [1] step
#   [2] pc_reset
#   [3] imem_prog_we
#   [4] dmem_prog_en
#   [5] dmem_prog_we
#   [6] param_wr_en


def regwrite(addr, value):
    cmd = "regwrite 0x{:08x} 0x{:08x}".format(addr, value)
    subprocess.call(cmd, shell=True)


def regread(addr):
    cmd = "regread 0x{:08x}".format(addr)
    out = subprocess.check_output(cmd, shell=True).decode("utf-8")
    result = out.splitlines()[0] if out else ""
    m = re.match(r"Reg (0x[0-9a-f]+) \(\d+\):\s+(0x[0-9a-f]+) \(\d+\)", result, re.IGNORECASE)
    if m:
        return m.group(2)
    return result


def ctrl_read_val():
    v = regread(GPU_CTRL_REG).strip()
    return int(v, 16)


def ctrl_write_val(v):
    regwrite(GPU_CTRL_REG, v)


def ctrl_set_bit(bit, val):
    v = ctrl_read_val()
    if val:
        v |= (1 << bit)
    else:
        v &= ~(1 << bit)
    ctrl_write_val(v)


def ctrl_pulse_bit(bit):
    ctrl_set_bit(bit, 0)
    ctrl_set_bit(bit, 1)
    ctrl_set_bit(bit, 0)


def normalize_number(s):
    if isinstance(s, INTEGER_TYPES):
        return str(s)
    return str(s).strip().replace("_", "")


def parse_int(s):
    return int(normalize_number(s), 0)


def parse_word(s):
    token = normalize_number(s)
    if token.startswith("0x") or token.startswith("0X"):
        return int(token, 0)
    return int(token, 16)


def cmd_run(on):
    ctrl_set_bit(0, 1 if on else 0)


def cmd_step():
    ctrl_pulse_bit(1)


def cmd_pcreset():
    ctrl_pulse_bit(2)


def cmd_imem_write(addr, wdata):
    a = parse_int(addr)
    d = parse_word(wdata)
    regwrite(GPU_IMEM_ADDR_REG, a)
    regwrite(GPU_IMEM_WDATA_REG, d)
    ctrl_pulse_bit(3)


def cmd_dmem_write(addr, hi, lo):
    a    = parse_int(addr)
    hi_v = parse_word(hi)
    lo_v = parse_word(lo)
    regwrite(GPU_DMEM_ADDR_REG, a)
    regwrite(GPU_DMEM_WDATA_HI_REG, hi_v)
    regwrite(GPU_DMEM_WDATA_LO_REG, lo_v)
    ctrl_set_bit(4, 1)
    ctrl_set_bit(5, 1)
    ctrl_set_bit(5, 0)


def cmd_dmem_read(addr):
    a = parse_int(addr)
    regwrite(GPU_DMEM_ADDR_REG, a)
    ctrl_set_bit(4, 1)
    ctrl_set_bit(5, 0)
    lo = regread(GPU_DMEM_RDATA_LO_REG)
    hi = regread(GPU_DMEM_RDATA_HI_REG)
    print("DMEM[{}] = {}{}".format(a, hi, lo))


def cmd_dbg():
    print("PC:       {}".format(regread(GPU_PC_DBG_REG)))
    print("IF_INSTR: {}".format(regread(GPU_IF_INSTR_REG)))


def cmd_allregs():
    cmd_dbg()
    print("DMEM_RLO: {}".format(regread(GPU_DMEM_RDATA_LO_REG)))
    print("DMEM_RHI: {}".format(regread(GPU_DMEM_RDATA_HI_REG)))


def cmd_param_write(addr, hi, lo):
    a    = parse_int(addr)
    hi_v = parse_word(hi)
    lo_v = parse_word(lo)
    regwrite(GPU_PARAM_ADDR_REG, a)
    regwrite(GPU_PARAM_DATA_HI_REG, hi_v)
    regwrite(GPU_PARAM_DATA_LO_REG, lo_v)
    ctrl_pulse_bit(6)


def cmd_done_check():
    print("DONE: {}".format(regread(GPU_DONE)))


def usage():
    print("Usage: gpureg.py <cmd> [args]")
    print("  Commands:")
    print("    run <0|1>                                   set run")
    print("    step                                        single step")
    print("    pcreset                                     pc_reset_pulse")
    print("    imem_write <addr> <wdata>                   program I-mem word")
    print("    dmem_write <addr> <hi> <lo>                 program D-mem 64b")
    print("    dmem_read <addr>                            read D-mem 64b via portB")
    print("    dbg                                         print pc + if_instr")
    print("    allregs                                     dump all hw regs")
    print("    param_write <addr> <hi> <lo>                program param_write 64b")
    print("    done_check                                  check done register")


def run_command(args):
    if not args:
        usage()
        return 1

    cmd = args[0]

    if cmd == "run":
        if len(args) < 2:
            raise SystemExit("run <0|1>")
        cmd_run(int(args[1]))
    elif cmd == "step":
        cmd_step()
    elif cmd == "pcreset":
        cmd_pcreset()
    elif cmd == "imem_write":
        if len(args) < 3:
            raise SystemExit("imem_write <addr> <wdata>")
        cmd_imem_write(args[1], args[2])
    elif cmd == "dmem_write":
        if len(args) < 4:
            raise SystemExit("dmem_write <addr> <hi> <lo>")
        cmd_dmem_write(args[1], args[2], args[3])
    elif cmd == "dmem_read":
        if len(args) < 2:
            raise SystemExit("dmem_read <addr>")
        cmd_dmem_read(args[1])
    elif cmd == "dbg":
        cmd_dbg()
    elif cmd == "allregs":
        cmd_allregs()
    elif cmd == "param_write":
        if len(args) < 4:
            raise SystemExit("param_write <addr> <hi> <lo>")
        cmd_param_write(args[1], args[2], args[3])
    elif cmd == "done_check":
        cmd_done_check()
    else:
        print("Unrecognized command: {}".format(cmd))
        usage()
        return 1
    return 0


def main():
    sys.exit(run_command(sys.argv[1:]))


if __name__ == "__main__":
    main()
