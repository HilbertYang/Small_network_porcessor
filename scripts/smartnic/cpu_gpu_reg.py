#!/usr/bin/env python2
# -*- coding: utf-8 -*-
# cpu_gpu_reg.py
# Python 2.4 compatible tool for cpu_gpu_dmem_top_regs.v
# Updated: DMEM loading via top-level "loaddmem <file>"

import sys, subprocess, re, os

# -------------------------------------------------------------------------
# Register addresses (match your earlier #defines)
# -------------------------------------------------------------------------
CPU_GPU_CTRL_REG             = 0x2000100
CPU_GPU_IMEM_ADDR_REG        = 0x2000104
CPU_GPU_IMEM_WDATA_REG       = 0x2000108
CPU_GPU_DMEM_ADDR_REG        = 0x200010c
CPU_GPU_DMEM_WDATA_LO_REG    = 0x2000110
CPU_GPU_DMEM_WDATA_HI_REG    = 0x2000114
# CPU_GPU_FIFO_CTRL_REG        = 0x2000118
# CPU_GPU_RESERVED_REG         = 0x2000118
CPU_GPU_CPU_PC_DBG_REG       = 0x2000118
CPU_GPU_CPU_IF_INSTR_REG     = 0x200011c
CPU_GPU_GPU_PC_DBG_REG       = 0x2000120
CPU_GPU_GPU_IF_INSTR_REG     = 0x2000124
CPU_GPU_DMEM_RDATA_LO_REG    = 0x2000128
CPU_GPU_DMEM_RDATA_HI_REG    = 0x200012c
CPU_GPU_DONE_REG             = 0x2000130
# CPU_GPU_FIFO_DATA_DONE_REG   = 0x200013c
CPU_GPU_HB_REG               = 0x2000134

# -------------------------------------------------------------------------
# SW register bitfield mapping (matches cpu_gpu_dmem_top_regs.v comment)
# sw_ctrl bits:
#  [0] run
#  [1] step
#  [2] pc_reset
#  [3] imem_prog_we (pulse)
#  [4] dmem_prog_en (level)
#  [5] dmem_prog_we (level)
#  [6] imem_sel (0 = GPU IMEM, 1 = CPU IMEM)
# -------------------------------------------------------------------------
BIT_RUN          = 0
BIT_STEP         = 1
BIT_PC_RESET     = 2
BIT_IMEM_PROG_WE = 3
BIT_DMEM_PROG_EN = 4
BIT_DMEM_PROG_WE = 5
BIT_IMEM_SEL     = 6

# -------------------------------------------------------------------------
# helpers (Python 2.4 compatible)
# -------------------------------------------------------------------------
def run_cmd(cmd):
    """Run shell command, return (rc, stdout_lines). Uses Popen (no check_output)."""
    try:
        p = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        (out, err) = p.communicate()
        rc = p.returncode
        if out is None:
            return rc, []
        lines = out.splitlines()
        return rc, lines
    except Exception, e:
        return 1, []

def regwrite(addr, value):
    cmd = "regwrite 0x%08x 0x%08x" % (addr, value)
    rc, _ = run_cmd(cmd)
    if rc != 0:
        sys.stderr.write("[ERROR] regwrite failed: %s\n" % cmd)
    return rc

# def regread(addr):
#     cmd = "regread 0x%08x" % (addr)
#     rc, lines = run_cmd(cmd)
#     if rc != 0:
#         raise RuntimeError("regread failed (cmd='%s')" % cmd)
#     if not lines:
#         return ""
#     first = lines[0].strip()
#     m = re.search(r"(0x[0-9a-fA-F]+)", first)
#     if m:
#         return m.group(1)
#     return first

def regread(addr):
    cmd = "regread 0x%08x" % addr
    rc, out = run_cmd(cmd)
    if rc != 0:
        #fail_cmd(cmd, out, err)
        raise RuntimeError("regread failed (cmd='%s')" % cmd)
    if out:
        result = out[0]
    else:
        result = ""
    m = re.match(r"Reg (0x[0-9a-f]+) \(\d+\):\s+(0x[0-9a-f]+) \(\d+\)", result, re.IGNORECASE)
    if m:
        return m.group(2)
    return result

# -------------------------------------------------------------------------
# numeric parsing helpers
# -------------------------------------------------------------------------
def parse_int_auto(s):
    s = str(s)
    if s.lower().startswith("0x"):
        return int(s, 16)
    return int(s, 0)

def parse_hex_auto(s):
    s = str(s).strip()
    if s.lower().startswith("0x"):
        return int(s, 16)
    if re.match(r'^[0-9a-fA-F]+$', s):
        return int(s, 16)
    return int(s, 0)

# -------------------------------------------------------------------------
# SW ctrl read/write helpers (RMW so pulses work)
# -------------------------------------------------------------------------
def read_sw_ctrl():
    v = regread(CPU_GPU_CTRL_REG)
    v = str(v).strip()
    try:
        return int(v, 16)
    except Exception:
        m = re.search(r"(0x[0-9a-fA-F]+)", v)
        if m:
            return int(m.group(1), 16)
    return 0

def write_sw_ctrl(val):
    return regwrite(CPU_GPU_CTRL_REG, val)

def sw_set_bit(bit, value):
    v = read_sw_ctrl()
    if value:
        v = v | (1 << bit)
    else:
        v = v & ~(1 << bit)
    write_sw_ctrl(v)

def sw_pulse_bit(bit):
    # 0 -> 1 -> 0 sequence
    sw_set_bit(bit, 0)
    sw_set_bit(bit, 1)
    sw_set_bit(bit, 0)

# -------------------------------------------------------------------------
# High-level commands that mirror the Verilog behaviour
# -------------------------------------------------------------------------
def set_run(target, on):
    # run is shared in this RTL; set shared bit regardless of 'target'
    if on:
        sw_set_bit(BIT_RUN, 1)
    else:
        sw_set_bit(BIT_RUN, 0)

def step_target(target):
    sw_pulse_bit(BIT_STEP)

def pcreset_target(target):
    sw_pulse_bit(BIT_PC_RESET)

def dmem_write(addr, hi, lo):
    a = parse_int_auto(addr) & 0xFF
    hi_v = parse_hex_auto(hi) & 0xFFFFFFFF
    lo_v = parse_hex_auto(lo) & 0xFFFFFFFF

    regwrite(CPU_GPU_DMEM_ADDR_REG, a)
    regwrite(CPU_GPU_DMEM_WDATA_HI_REG, hi_v)
    regwrite(CPU_GPU_DMEM_WDATA_LO_REG, lo_v)

    # assert enable + pulse we
    sw_set_bit(BIT_DMEM_PROG_EN, 1)
    sw_set_bit(BIT_DMEM_PROG_WE, 1)
    sw_set_bit(BIT_DMEM_PROG_WE, 0)
    sw_set_bit(BIT_DMEM_PROG_EN, 0)

def fifo_config(start_offset, end_offset, data_ready_bit):
    so = int(start_offset) & 0xFF
    eo = int(end_offset) & 0xFF
    if int(data_ready_bit):
        dr = 1
    else:
        dr = 0
    val = (dr << 16) | (eo << 8) | so
    regwrite(CPU_GPU_FIFO_CTRL_REG, val)

# -------------------------------------------------------------------------
# IMEM loader: read ascii file lines "addr;data" (hex) and program IMEM
# -------------------------------------------------------------------------
def load_imem_file(target, path):
    if target.lower() not in ("cpu", "gpu"):
        raise ValueError("target must be 'cpu' or 'gpu'")
    if not os.path.isfile(path):
        raise ValueError("file not found: %s" % path)

    line_no = 0
    f = open(path, "r")
    try:
        for raw in f:
            line_no = line_no + 1
            s = raw.strip()
            if not s:
                continue
            if s.startswith("#") or s.startswith("//") or s.startswith(";"):
                continue
            parts = s.split(";")
            if len(parts) < 2:
                sys.stderr.write("[WARN] skipping line %d: cannot parse '%s'\n" % (line_no, s))
                continue
            addr_str = parts[0].strip()
            data_str = parts[1].strip()
            try:
                if not addr_str.lower().startswith("0x"):
                    a = parse_int_auto("0x" + addr_str)
                else:
                    a = parse_int_auto(addr_str)
            except Exception:
                try:
                    a = parse_int_auto(addr_str)
                except Exception:
                    sys.stderr.write("[WARN] bad addr on line %d: '%s'\n" % (line_no, addr_str))
                    continue
            try:
                d = parse_hex_auto(data_str)
            except Exception:
                try:
                    d = parse_int_auto(data_str)
                except Exception:
                    sys.stderr.write("[WARN] bad data on line %d: '%s'\n" % (line_no, data_str))
                    continue

            # set imem_sel: 1 => CPU, 0 => GPU
            if target.lower() == "cpu":
                sw_set_bit(BIT_IMEM_SEL, 1)
            else:
                sw_set_bit(BIT_IMEM_SEL, 0)

            regwrite(CPU_GPU_IMEM_ADDR_REG, a & 0x1FF)
            regwrite(CPU_GPU_IMEM_WDATA_REG, d & 0xFFFFFFFF)

            sw_pulse_bit(BIT_IMEM_PROG_WE)
    finally:
        f.close()

    print "Finished loading IMEM from %s to %s" % (path, target.upper())

# -------------------------------------------------------------------------
# DMEM loader: read file "addr;64hex" and write DMEM
# -------------------------------------------------------------------------
def load_dmem_file(path):
    if not os.path.isfile(path):
        raise ValueError("file not found: %s" % path)

    line_no = 0
    f = open(path, "r")
    try:
        for raw in f:
            line_no = line_no + 1
            s = raw.strip()
            if not s:
                continue
            if s.startswith("#") or s.startswith("//") or s.startswith(";"):
                continue
            parts = s.split(";")
            if len(parts) < 2:
                sys.stderr.write("[WARN] skipping line %d: cannot parse '%s'\n" % (line_no, s))
                continue
            addr_str = parts[0].strip()
            data_str = parts[1].strip()
            try:
                if not addr_str.lower().startswith("0x"):
                    a = parse_int_auto("0x" + addr_str)
                else:
                    a = parse_int_auto(addr_str)
            except Exception:
                try:
                    a = parse_int_auto(addr_str)
                except Exception:
                    sys.stderr.write("[WARN] bad addr on line %d: '%s'\n" % (line_no, addr_str))
                    continue

            d = data_str.lower()
            if d.startswith("0x"):
                d = d[2:]
            if not re.match(r'^[0-9a-f]{1,16}$', d):
                sys.stderr.write("[WARN] bad data on line %d: '%s'\n" % (line_no, data_str))
                continue
            d = d.rjust(16, "0")
            hi = d[0:8]
            lo = d[8:16]
            dmem_write(a, hi, lo)
    finally:
        f.close()

    print "Finished loading DMEM from %s" % (path,)

# -------------------------------------------------------------------------
# DMEM read range and dump to file as "addr;64hex"
# -------------------------------------------------------------------------
def dmem_read_range_and_dump(start_addr, end_addr, out_path):
    start = parse_int_auto(start_addr)
    end = parse_int_auto(end_addr)
    if start < 0 or end < 0 or end < start:
        raise ValueError("invalid start/end addresses")

    if start > 0xFF or end > 0xFF:
        sys.stderr.write("[WARN] DMEM address limited to 8-bit; truncating to 0xFF\n")

    outf = open(out_path, "w")
    try:
        a = start
        while a <= end:
            addr8 = a & 0xFF
            regwrite(CPU_GPU_DMEM_ADDR_REG, addr8)
            sw_set_bit(BIT_DMEM_PROG_EN, 1)
            sw_set_bit(BIT_DMEM_PROG_WE, 0)
            lo = regread(CPU_GPU_DMEM_RDATA_LO_REG)
            hi = regread(CPU_GPU_DMEM_RDATA_HI_REG)
            sw_set_bit(BIT_DMEM_PROG_EN, 0)
            hi_s = str(hi).strip()
            lo_s = str(lo).strip()
            mhi = re.search(r"(0x[0-9a-fA-F]+)", hi_s)
            mlo = re.search(r"(0x[0-9a-fA-F]+)", lo_s)
            if mhi:
                hi_val = mhi.group(1)[2:]
            else:
                hi_val = hi_s
            if mlo:
                lo_val = mlo.group(1)[2:]
            else:
                lo_val = lo_s
            if len(hi_val) < 8:
                hi_val = hi_val.rjust(8, "0")
            if len(lo_val) < 8:
                lo_val = lo_val.rjust(8, "0")
            combined = (hi_val + lo_val).lower()
            outf.write("%02x;%s\n" % (addr8, combined))
            a = a + 1
    finally:
        outf.close()

    sw_set_bit(BIT_DMEM_PROG_EN, 0)
    print "Finished DMEM dump to %s" % out_path

# -------------------------------------------------------------------------
# HW read helpers (map 1:1 to Verilog hw regs)
# -------------------------------------------------------------------------
def hw_cpu_pc():
    return regread(CPU_GPU_CPU_PC_DBG_REG)

def hw_cpu_if_instr():
    return regread(CPU_GPU_CPU_IF_INSTR_REG)

def hw_gpu_pc():
    return regread(CPU_GPU_GPU_PC_DBG_REG)

def hw_gpu_if_instr():
    return regread(CPU_GPU_GPU_IF_INSTR_REG)

def hw_dmem_rdata():
    lo = regread(CPU_GPU_DMEM_RDATA_LO_REG)
    hi = regread(CPU_GPU_DMEM_RDATA_HI_REG)
    return hi, lo

def hw_done():
    return regread(CPU_GPU_DONE_REG)

def hw_fifo_data_done():
    return regread(CPU_GPU_FIFO_DATA_DONE_REG)

def hw_hb():
    return regread(CPU_GPU_HB_REG)

def hw_dbg_all():
    print "CPU PC:       ", hw_cpu_pc()
    print "CPU IF:       ", hw_cpu_if_instr()
    print "GPU PC:       ", hw_gpu_pc()
    print "GPU IF:       ", hw_gpu_if_instr()
    hi, lo = hw_dmem_rdata()
    print "DMEM RDATA:   hi=%s lo=%s" % (hi, lo)
    print "DONE:         ", hw_done()
    print "FIFO_DATA_DONE:", hw_fifo_data_done()
    print "HB:           ", hw_hb()

# -------------------------------------------------------------------------
# CLI dispatch
# -------------------------------------------------------------------------
def usage():
    print "Usage: cpu_gpu_reg.py <cmd> [args]"
    print "Commands:"
    print "  cpu run <0|1>"
    print "  cpu step"
    print "  cpu pcreset"
    print "  cpu loadImem <file>     # load CPU IMEM from file (addr;data)"
    print "  gpu loadImem <file>     # load GPU IMEM from file (addr;data)"
    print "  loaddmem <file>         # load DMEM from file (addr;64hex)"
    print "  dmem_read <start> <end> <out_file>   # dump DMEM range to file"
    print "  dmem_write <addr> <hi> <lo>     # low-level DMEM write"
    print "  fifo_config <start_offset> <end_offset> <data_ready_bit>"
    print "  sw_ctrl read|write <hexval>"
    print "  hw dbg"
    print "  hw read <cpu_pc|cpu_if|gpu_pc|gpu_if|dmem|done|fifo|hb>"
    print ""
    print "Examples:"
    print "  ./cpu_gpu_reg.py cpu loadImem ./cpuImem.txt"
    print "  ./cpu_gpu_reg.py loaddmem ./dmemdata.txt"
    print "  ./cpu_gpu_reg.py dmem_read 0 1b dmem.txt"

def main(argv):
    if len(argv) < 2:
        usage()
        sys.exit(1)

    cmd = argv[1]

    try:
        if cmd == "cpu":
            if len(argv) < 3:
                raise ValueError("missing cpu subcommand")
            sub = argv[2]
            if sub == "run":
                if len(argv) < 4:
                    raise ValueError("cpu run <0|1>")
                set_run("cpu", int(argv[3]))
            elif sub == "step":
                step_target("cpu")
            elif sub == "pcreset":
                pcreset_target("cpu")
            elif sub == "loadImem":
                if len(argv) < 4:
                    raise ValueError("cpu loadImem <file>")
                load_imem_file("cpu", argv[3])
            else:
                raise ValueError("cpu <run|step|pcreset|loadImem>")

        elif cmd == "gpu":
            if len(argv) < 3:
                raise ValueError("missing gpu subcommand")
            sub = argv[2]
            if sub == "run":
                if len(argv) < 4:
                    raise ValueError("gpu run <0|1>")
                set_run("gpu", int(argv[3]))
            elif sub == "step":
                step_target("gpu")
            elif sub == "pcreset":
                pcreset_target("gpu")
            elif sub == "loadImem":
                if len(argv) < 4:
                    raise ValueError("gpu loadImem <file>")
                load_imem_file("gpu", argv[3])
            else:
                raise ValueError("gpu <run|step|pcreset|loadImem>")

        elif cmd == "loaddmem":
            if len(argv) < 3:
                raise ValueError("loaddmem <file>")
            load_dmem_file(argv[2])

        elif cmd == "dmem_read":
            if len(argv) < 5:
                raise ValueError("dmem_read <start> <end> <out_file>")
            dmem_read_range_and_dump(argv[2], argv[3], argv[4])

        elif cmd == "dmem_write":
            if len(argv) < 5:
                raise ValueError("dmem_write <addr> <hi> <lo>")
            dmem_write(argv[2], argv[3], argv[4])

        elif cmd == "fifo_config":
            if len(argv) < 5:
                raise ValueError("fifo_config <start_offset> <end_offset> <data_ready_bit>")
            fifo_config(argv[2], argv[3], argv[4])

        elif cmd == "sw_ctrl":
            if len(argv) < 3:
                raise ValueError("sw_ctrl read|write <hexval>")
            if argv[2] == "read":
                print "0x%08x" % read_sw_ctrl()
            elif argv[2] == "write":
                if len(argv) < 4:
                    raise ValueError("sw_ctrl write <hexval>")
                val = parse_hex_auto(argv[3])
                write_sw_ctrl(val)
            else:
                raise ValueError("sw_ctrl read|write <hexval>")

        elif cmd == "hw":
            if len(argv) < 3:
                raise ValueError("hw dbg|read <args>")
            sub = argv[2]
            if sub == "dbg":
                hw_dbg_all()
            elif sub == "read":
                if len(argv) >= 4:
                    what = argv[3]
                else:
                    what = ""
                if what == "cpu_pc":
                    print hw_cpu_pc()
                elif what == "cpu_if":
                    print hw_cpu_if_instr()
                elif what == "gpu_pc":
                    print hw_gpu_pc()
                elif what == "gpu_if":
                    print hw_gpu_if_instr()
                elif what == "dmem":
                    hi, lo = hw_dmem_rdata()
                    print "DMEM RDATA hi=%s lo=%s" % (hi, lo)
                elif what == "done":
                    print hw_done()
                elif what == "fifo":
                    print hw_fifo_data_done()
                elif what == "hb":
                    print hw_hb()
                else:
                    raise ValueError("hw read <cpu_pc|cpu_if|gpu_pc|gpu_if|dmem|done|fifo|hb>")
            else:
                raise ValueError("hw dbg|read")
        else:
            raise ValueError("unknown command")
    except Exception, e:
        sys.stderr.write("[ERROR] %s\n" % str(e))
        usage()
        sys.exit(1)

if __name__ == "__main__":
    main(sys.argv)
