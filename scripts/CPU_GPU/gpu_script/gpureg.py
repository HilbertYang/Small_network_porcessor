#!/usr/bin/env python
import sys
import re
import subprocess

GPU_BASE = 0x2000000

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
        ctrl_set_bit(0, 1)
    else:
        ctrl_set_bit(0, 0)


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
    write_line("DMEM[%s] = hi=%s  low=%s" % (a, format_hex_groups(hi), format_hex_groups(lo)))


def cmd_dbg():
    write_line("PC:       %s" % regread(GPU_PC_DBG_REG))
    write_line("IF_INSTR: %s" % regread(GPU_IF_INSTR_REG))


def cmd_allregs():
    cmd_dbg()
    write_line("DMEM_RLO: %s" % regread(GPU_DMEM_RDATA_LO_REG))
    write_line("DMEM_RHI: %s" % regread(GPU_DMEM_RDATA_HI_REG))


def cmd_param_write(addr, hi, lo):
    a    = parse_int(addr)
    hi_v = parse_word(hi)
    lo_v = parse_word(lo)
    regwrite(GPU_PARAM_ADDR_REG, a)
    regwrite(GPU_PARAM_DATA_HI_REG, hi_v)
    regwrite(GPU_PARAM_DATA_LO_REG, lo_v)
    ctrl_pulse_bit(6)


def cmd_done_check():
    write_line("DONE: %s" % regread(GPU_DONE))


def usage():
    write_line("Usage: gpureg.py <cmd> [args]")
    write_line("  Commands:")
    write_line("    run <0|1>                                   set run")
    write_line("    step                                        single step")
    write_line("    pcreset                                     pc_reset_pulse")
    write_line("    imem_write <addr> <wdata>                   program I-mem word")
    write_line("    dmem_write <addr> <hi> <lo>                 program D-mem 64b")
    write_line("    dmem_read <addr>                            read D-mem 64b via portB")
    write_line("    dbg                                         print pc + if_instr")
    write_line("    allregs                                     dump all hw regs")
    write_line("    param_write <addr> <hi> <lo>                program param_write 64b")
    write_line("    done_check                                  check done register")


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
        write_line("Unrecognized command: %s" % cmd)
        usage()
        return 1
    return 0


def main():
    sys.exit(run_command(sys.argv[1:]))


if __name__ == "__main__":
    main()
