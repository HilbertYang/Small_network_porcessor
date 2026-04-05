#!/usr/bin/env python3
import re
import sys

REG_RE = re.compile(r"R(1[0-5]|\d)$", re.IGNORECASE)

def reg_num(tok: str) -> int:
    tok = tok.strip().upper()
    m = REG_RE.fullmatch(tok)
    if not m:
        raise ValueError(f"Bad register: {tok}")
    n = int(m.group(1))
    if not (0 <= n <= 15):
        raise ValueError(f"Register out of range: {tok}")
    return n

def parse_imm(tok: str) -> int:
    tok = tok.strip()
    if tok.startswith("#"):
        tok = tok[1:]
    return int(tok, 0)

def u32(x: int) -> int:
    return x & 0xFFFFFFFF

def split_operands(s: str):
    if not s.strip():
        return []
    ops = []
    cur = []
    depth = 0
    for ch in s:
        if ch == '[':
            depth += 1
        elif ch == ']':
            depth = max(0, depth - 1)
        elif ch == ',' and depth == 0:
            part = ''.join(cur).strip()
            if part:
                ops.append(part)
            cur = []
            continue
        cur.append(ch)
    part = ''.join(cur).strip()
    if part:
        ops.append(part)
    return ops



def strip_comment(line: str) -> str:
    return line.split("//", 1)[0].strip()

def encode_data_proc(cond, I, opcode, S, Rn, Rd, operand2):
    return (
        (cond << 28) |
        (0b00 << 26) |
        (I << 25) |
        (opcode << 21) |
        (S << 20) |
        (Rn << 16) |
        (Rd << 12) |
        (operand2 & 0xFFF)
    )

def encode_branch(cond, link, off24):
    return (
        (cond << 28) |
        (0b101 << 25) |
        (link << 24) |
        (off24 & 0xFFFFFF)
    )

def encode_load_store(cond, L, Rn, Rd, imm12, U=1):
    return (
        (cond << 28) |
        (0b01 << 26) |
        (1 << 25) |
        (U << 23) |
        (L << 20) |
        (Rn << 16) |
        (Rd << 12) |
        (imm12 & 0xFFF)
    )

def encode_bx(rm):
    return 0xE12FFF10 | (rm & 0xF)

def encode_j(target9):
    return (0b111011 << 26) | (target9 & 0x1FF)

def encode_beq_bne(is_bne, rn, rm, off16):
    return (
        (0xE << 28) |
        ((0x9 if is_bne else 0x8) << 24) |
        ((rn & 0xF) << 20) |
        ((rm & 0xF) << 16) |
        (off16 & 0xFFFF)
    )

def encode_wrp(rs, imm3):
    return (0xAE << 24) | ((rs & 0xF) << 20) | (imm3 & 0x7)

def encode_rdf(rd, sel):
    return (0xAF << 24) | ((rd & 0xF) << 20) | (sel & 0x1)

def encode_special(op):
    specials = {
        "NOP":      0xE0000000,
        "FIFOWAIT": 0xAC000000,
        "FIFODONE": 0xAB000000,
        "GPU_RUN":  0xAD000000,
    }
    return specials[op]

def assemble_line(line: str):
    line = strip_comment(line)
    if not line:
        return None

    m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*(.*)$", line)
    if not m:
        raise ValueError(f"Cannot parse line: {line}")

    op = m.group(1).upper()
    rest = m.group(2).strip()
    ops = split_operands(rest)

    if op in {"NOP", "FIFOWAIT", "FIFODONE", "GPU_RUN"}:
        return encode_special(op)

    if op == "MOV":
        if len(ops) != 2 or not ops[1].startswith("#"):
            raise ValueError("MOV syntax: MOV Rd, #imm8")
        rd = reg_num(ops[0])
        imm8 = parse_imm(ops[1]) & 0xFF
        return encode_data_proc(0xE, 1, 0b1101, 0, 0, rd, imm8)

    if op in {"ADD", "SUB", "AND", "ORR", "EOR", "SLT"}:
        if len(ops) != 3:
            raise ValueError(f"{op} syntax: {op} Rd, Rn, Rm/#imm")
        rd = reg_num(ops[0])
        rn = reg_num(ops[1])

        if ops[2].startswith("#"):
            imm = parse_imm(ops[2]) & 0xFF
            I = 1
            operand2 = imm
        else:
            rm = reg_num(ops[2])
            I = 0
            operand2 = rm

        opcode_map = {
            "AND": 0b0000,
            "EOR": 0b0001,
            "SUB": 0b0010,
            "ADD": 0b0100,
            "ORR": 0b1100,
            "SLT": 0b1011,
        }
        return encode_data_proc(0xE, I, opcode_map[op], 0, rn, rd, operand2)

    if op in {"LDR", "STR"}:
        # Expected syntax: LDR Rd, [Rn, #off12]
        # or:             STR Rd, [Rn, #off12]
        if len(ops) != 2:
            raise ValueError(f"{op} syntax: {op} Rd, [Rn, #off12]")

        rd = reg_num(ops[0])

        addr = ops[1].strip()
        m2 = re.fullmatch(
            r"\[\s*(R(?:1[0-5]|\d))\s*,\s*#?([+-]?(?:0x[0-9a-fA-F]+|\d+))\s*\]",
            addr,
            re.IGNORECASE,
        )
        if not m2:
            raise ValueError(f"Bad address syntax: {addr}")

        rn = reg_num(m2.group(1))
        imm12 = int(m2.group(2), 0) & 0xFFF

        return encode_load_store(0xE, 1 if op == "LDR" else 0, rn, rd, imm12, U=1)

    if op in {"B", "BL"}:
        if len(ops) != 1:
            raise ValueError(f"{op} syntax: {op} off24")
        off24 = parse_imm(ops[0]) & 0xFFFFFF
        return encode_branch(0xE, 1 if op == "BL" else 0, off24)

    if op in {"BX", "JR"}:
        if len(ops) != 1:
            raise ValueError("BX/JR syntax: BX Rm")
        return encode_bx(reg_num(ops[0]))

    if op == "J":
        if len(ops) != 1:
            raise ValueError("J syntax: J target9")
        return encode_j(parse_imm(ops[0]) & 0x1FF)

    if op in {"BEQ", "BNE"}:
        if len(ops) != 3:
            raise ValueError(f"{op} syntax: {op} Rn, Rm, off16")
        rn = reg_num(ops[0])
        rm = reg_num(ops[1])
        off16 = parse_imm(ops[2]) & 0xFFFF
        return encode_beq_bne(op == "BNE", rn, rm, off16)

    if op == "WRP":
        if len(ops) != 2:
            raise ValueError("WRP syntax: WRP Rs, #imm3")
        rs = reg_num(ops[0])
        imm3 = parse_imm(ops[1]) & 0x7
        return encode_wrp(rs, imm3)

    if op == "RDF":
        if len(ops) != 2:
            raise ValueError("RDF syntax: RDF Rd, #sel")
        rd = reg_num(ops[0])
        sel = parse_imm(ops[1]) & 0x1
        return encode_rdf(rd, sel)

    if op in {"SLL", "SRL"}:
        if len(ops) != 3:
            raise ValueError(f"{op} syntax: {op} Rd, Rn, Rm")
        rd = reg_num(ops[0])
        rn = reg_num(ops[1])
        rm = reg_num(ops[2])

        # Matches the encoding style in your comment.
        cond = 0xE
        opbits = 0b0110 if op == "SLL" else 0b0111
        word = (cond << 28) | (0b000 << 25) | (opbits << 21)
        word |= (0 << 20) | (rn << 16) | (rd << 12) | (0 << 4) | (rm & 0xF)
        return word

    raise ValueError(f"Unknown instruction: {op}")

def assemble_text(text: str):
    out = []
    addr = 0
    for raw in text.splitlines():
        word = assemble_line(raw)
        if word is None:
            continue
        out.append(f"{addr:02x};0x{u32(word):08x}")
        addr += 1
    return out

def main():
    if len(sys.argv) > 1 and sys.argv[1] != "-":
        with open(sys.argv[1], "r", encoding="utf-8") as f:
            text = f.read()
    else:
        text = sys.stdin.read()

    for line in assemble_text(text):
        print(line)

if __name__ == "__main__":
    main()
