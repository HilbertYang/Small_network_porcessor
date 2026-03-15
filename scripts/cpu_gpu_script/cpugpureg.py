#!/usr/bin/env python
# cpugpureg.py - register interface for cpu_gpu_dmem_top_regs
#
# Register map (base = CPU_GPU_BASE_ADDR = 0x2000100, from reg_defines_lab9.h):
#
# SW regs:
#   0x2000100  CTRL          [0]=run [1]=step [2]=pc_reset [3]=imem_prog_we
#                            [4]=dmem_prog_en [5]=dmem_prog_we [6]=imem_sel
#   0x2000104  IMEM_ADDR     [8:0]  IMEM program address
#   0x2000108  IMEM_WDATA    [31:0] IMEM program write data
#   0x200010c  DMEM_ADDR     [7:0]  DMEM Port-A program address
#   0x2000110  DMEM_WDATA_LO [31:0] DMEM write data [31:0]
#   0x2000114  DMEM_WDATA_HI [31:0] DMEM write data [63:32]
#   0x2000118  FIFO_CTRL     [7:0]=fifo_start_offset [15:8]=fifo_end_offset
#                            [16]=fifo_data_ready
#   0x200011c  (reserved)
#
# HW regs:
#   0x2000120  CPU_PC_DBG      CPU current PC [8:0]
#   0x2000124  CPU_IF_INSTR    CPU IF-stage instruction [31:0]
#   0x2000128  GPU_PC_DBG      GPU current PC [8:0]
#   0x200012c  GPU_IF_INSTR    GPU IF-stage instruction [31:0]
#   0x2000130  DMEM_RDATA_LO   DMEM Port-A read data [31:0]
#   0x2000134  DMEM_RDATA_HI   DMEM Port-A read data [63:32]
#   0x2000138  DONE            GPU kernel done [0]
#   0x200013c  FIFO_DATA_DONE  CPU fifo_data_done [0]
#   0x2000140  HB              Heartbeat counter [31:0]
#
# imem_sel (ctrl bit[6]):  0 = GPU IMEM,  1 = CPU IMEM

import sys
import re
import subprocess

CPU_GPU_BASE = 0x2000100

# SW regs
CTRL_REG          = CPU_GPU_BASE + 0x00
IMEM_ADDR_REG     = CPU_GPU_BASE + 0x04
IMEM_WDATA_REG    = CPU_GPU_BASE + 0x08
DMEM_ADDR_REG     = CPU_GPU_BASE + 0x0c
DMEM_WDATA_LO_REG = CPU_GPU_BASE + 0x10
DMEM_WDATA_HI_REG = CPU_GPU_BASE + 0x14
FIFO_CTRL_REG     = CPU_GPU_BASE + 0x18
# 0x1c reserved

# HW regs
CPU_PC_DBG_REG      = CPU_GPU_BASE + 0x20
CPU_IF_INSTR_REG    = CPU_GPU_BASE + 0x24
GPU_PC_DBG_REG      = CPU_GPU_BASE + 0x28
GPU_IF_INSTR_REG    = CPU_GPU_BASE + 0x2c
DMEM_RDATA_LO_REG   = CPU_GPU_BASE + 0x30
DMEM_RDATA_HI_REG   = CPU_GPU_BASE + 0x34
DONE_REG            = CPU_GPU_BASE + 0x38
FIFO_DATA_DONE_REG  = CPU_GPU_BASE + 0x3c
HB_REG              = CPU_GPU_BASE + 0x40

# ctrl bit positions
BIT_RUN          = 0
BIT_STEP         = 1
BIT_PC_RESET     = 2
BIT_IMEM_PROG_WE = 3
BIT_DMEM_PROG_EN = 4
BIT_DMEM_PROG_WE = 5
BIT_IMEM_SEL     = 6   # 0=GPU IMEM, 1=CPU IMEM


def write_line(text):
    sys.stdout.write("%s\n" % text)


def decode_text(blob):
    if isinstance(blob, str):
        return blob
    return blob.decode("utf-8")


def run_shell(cmd):
    proc = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out, err = proc.communicate()
    return proc.returncode, decode_text(out), decode_text(err)


def fail_cmd(cmd, out, err):
    details = []
    if out:
        details.append(out.strip())
    if err:
        details.append(err.strip())
    if details:
        raise SystemExit("Command failed: %s\n%s" % (cmd, "\n".join(details)))
    raise SystemExit("Command failed: %s" % cmd)


def regwrite(addr, value):
    cmd = "regwrite 0x%08x 0x%08x" % (addr, value)
    rc, out, err = run_shell(cmd)
    if rc != 0:
        fail_cmd(cmd, out, err)


def regread(addr):
    cmd = "regread 0x%08x" % addr
    rc, out, err = run_shell(cmd)
    if rc != 0:
        fail_cmd(cmd, out, err)
    if out:
        result = out.splitlines()[0]
    else:
        result = ""
    m = re.match(r"Reg (0x[0-9a-f]+) \(\d+\):\s+(0x[0-9a-f]+) \(\d+\)", result, re.IGNORECASE)
    if m:
        return m.group(2)
    return result


def ctrl_read_val():
    v = regread(CTRL_REG).strip()
    return int(v, 16)


def ctrl_write_val(v):
    regwrite(CTRL_REG, v)


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
    return str(s).strip().replace("_", "")


def format_hex_groups(token):
    text = str(token).strip()
    prefix = ""
    body = text
    if len(body) >= 2 and (body[:2] == "0x" or body[:2] == "0X"):
        prefix = body[:2]
        body = body[2:]
    body = body.replace("_", "")
    if not body:
        return text
    groups = []
    idx = 0
    while idx < len(body):
        groups.append(body[idx:idx + 4])
        idx += 4
    return prefix + " ".join(groups)


def parse_int(s):
    return int(normalize_number(s), 0)


def parse_word(s):
    token = normalize_number(s)
    if token.startswith("0x") or token.startswith("0X"):
        return int(token, 0)
    return int(token, 16)


def cmd_run(on):
    if on:
        ctrl_set_bit(BIT_RUN, 1)
    else:
        ctrl_set_bit(BIT_RUN, 0)


def cmd_step():
    ctrl_pulse_bit(BIT_STEP)


def cmd_pcreset():
    ctrl_pulse_bit(BIT_PC_RESET)


def cmd_imem_write(target, addr, wdata):
    """Program one 32-bit word into IMEM.
    target: 'gpu' (imem_sel=0) or 'cpu' (imem_sel=1)
    """
    a = parse_int(addr)
    d = parse_word(wdata)
    if target.lower() == "cpu":
        sel = 1
    else:
        sel = 0
    ctrl_set_bit(BIT_IMEM_SEL, sel)
    regwrite(IMEM_ADDR_REG, a)
    regwrite(IMEM_WDATA_REG, d)
    ctrl_pulse_bit(BIT_IMEM_PROG_WE)
    ctrl_set_bit(BIT_IMEM_SEL, 0)


def cmd_dmem_write(addr, hi, lo):
    a    = parse_int(addr)
    hi_v = parse_word(hi)
    lo_v = parse_word(lo)
    regwrite(DMEM_ADDR_REG, a)
    regwrite(DMEM_WDATA_HI_REG, hi_v)
    regwrite(DMEM_WDATA_LO_REG, lo_v)
    ctrl_set_bit(BIT_DMEM_PROG_EN, 1)
    ctrl_set_bit(BIT_DMEM_PROG_WE, 1)
    ctrl_set_bit(BIT_DMEM_PROG_WE, 0)


def cmd_dmem_read(addr):
    a = parse_int(addr)
    regwrite(DMEM_ADDR_REG, a)
    ctrl_set_bit(BIT_DMEM_PROG_EN, 1)
    ctrl_set_bit(BIT_DMEM_PROG_WE, 0)
    lo = regread(DMEM_RDATA_LO_REG)
    hi = regread(DMEM_RDATA_HI_REG)
    write_line("DMEM[%s] = hi=%s  lo=%s" % (a, format_hex_groups(hi), format_hex_groups(lo)))


def cmd_fifo_ctrl(start_offset, end_offset, data_ready):
    s = parse_int(start_offset) & 0xff
    e = parse_int(end_offset)   & 0xff
    if int(data_ready):
        r = 1
    else:
        r = 0
    val = s | (e << 8) | (r << 16)
    regwrite(FIFO_CTRL_REG, val)


def cmd_dbg():
    write_line("CPU_PC:       %s" % regread(CPU_PC_DBG_REG))
    write_line("CPU_IF_INSTR: %s" % regread(CPU_IF_INSTR_REG))
    write_line("GPU_PC:       %s" % regread(GPU_PC_DBG_REG))
    write_line("GPU_IF_INSTR: %s" % regread(GPU_IF_INSTR_REG))


def cmd_allregs():
    cmd_dbg()
    write_line("DMEM_RLO:       %s" % regread(DMEM_RDATA_LO_REG))
    write_line("DMEM_RHI:       %s" % regread(DMEM_RDATA_HI_REG))
    write_line("DONE:           %s" % regread(DONE_REG))
    write_line("FIFO_DATA_DONE: %s" % regread(FIFO_DATA_DONE_REG))
    write_line("HEARTBEAT:      %s" % regread(HB_REG))


def cmd_done_check():
    write_line("DONE: %s" % regread(DONE_REG))


def cmd_fifo_done_check():
    write_line("FIFO_DATA_DONE: %s" % regread(FIFO_DATA_DONE_REG))


def cmd_hb():
    write_line("HEARTBEAT: %s" % regread(HB_REG))


def usage():
    write_line("Usage: cpugpureg.py <cmd> [args]")
    write_line("  Commands:")
    write_line("    run <0|1>                                   set run (CPU+GPU)")
    write_line("    step                                        single-step one cycle")
    write_line("    pcreset                                     reset CPU+GPU PCs to 0")
    write_line("    imem_write <gpu|cpu> <addr> <wdata>         program IMEM word")
    write_line("    dmem_write <addr> <hi> <lo>                 write DMEM 64-bit word")
    write_line("    dmem_read  <addr>                           read  DMEM 64-bit word")
    write_line("    fifo_ctrl  <start> <end> <rdy>              set FIFO ctrl register")
    write_line("    dbg                                         print CPU+GPU PC/instr")
    write_line("    allregs                                     dump all HW status regs")
    write_line("    done_check                                  check GPU done flag")
    write_line("    fifo_done_check                             check CPU fifo_data_done")
    write_line("    hb                                          read heartbeat counter")


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
        if len(args) < 4:
            raise SystemExit("imem_write <gpu|cpu> <addr> <wdata>")
        cmd_imem_write(args[1], args[2], args[3])
    elif cmd == "dmem_write":
        if len(args) < 4:
            raise SystemExit("dmem_write <addr> <hi> <lo>")
        cmd_dmem_write(args[1], args[2], args[3])
    elif cmd == "dmem_read":
        if len(args) < 2:
            raise SystemExit("dmem_read <addr>")
        cmd_dmem_read(args[1])
    elif cmd == "fifo_ctrl":
        if len(args) < 4:
            raise SystemExit("fifo_ctrl <start_offset> <end_offset> <data_ready>")
        cmd_fifo_ctrl(args[1], args[2], args[3])
    elif cmd == "dbg":
        cmd_dbg()
    elif cmd == "allregs":
        cmd_allregs()
    elif cmd == "done_check":
        cmd_done_check()
    elif cmd == "fifo_done_check":
        cmd_fifo_done_check()
    elif cmd == "hb":
        cmd_hb()
    else:
        write_line("Unrecognized command: %s" % cmd)
        usage()
        return 1
    return 0


def main():
    sys.exit(run_command(sys.argv[1:]))


if __name__ == "__main__":
    main()
