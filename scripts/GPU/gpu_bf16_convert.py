#!/usr/bin/env python
# bf16_convert.py  --  hardware-compatible version (Python >= 2.3)
# Convert between BF16 hex values and decimal numbers.
#
# Usage:
#   bf16_convert.py --to-dec  [--plain] <hex> [<hex> ...]
#   bf16_convert.py --to-bf16 [--plain] <dec> [<dec> ...]
#
# Input formats accepted by --to-dec:
#   3F80  0x3F80  16'h3F80  'h3F80  (case-insensitive, underscores ignored)
#
# Examples:
#   bf16_convert.py --to-dec  3F80 BF80
#   bf16_convert.py --to-bf16 1.0 -1.0 3.14
#   echo "3F80 4000" | bf16_convert.py --to-dec --plain

import struct
import sys
from optparse import OptionParser


def _isnan(x):
    return x != x


def _isinf(x):
    return x != 0.0 and x == x and x * 2.0 == x


def normalize_bf16_token(token):
    s = token.strip().lower().replace("_", "")

    if s.startswith("16'h"):
        s = s[4:]
    elif s.startswith("'h"):
        s = s[2:]

    if s.startswith("0x"):
        s = s[2:]

    if not s:
        raise ValueError("empty BF16 value")

    if len(s) > 4:
        raise ValueError("'%s' is longer than 16 bits" % token)

    value = int(s, 16)
    return "%04x" % value


def bf16_to_float(token):
    bf16_bits = int(normalize_bf16_token(token), 16)
    fp32_bits = bf16_bits << 16
    return struct.unpack(">f", struct.pack(">I", fp32_bits))[0]


def float_to_float32_bits(value):
    if _isnan(value):
        return 0x7FC00000
    if _isinf(value):
        if value > 0:
            return 0x7F800000
        return 0xFF800000
    try:
        return struct.unpack(">I", struct.pack(">f", value))[0]
    except OverflowError:
        if value > 0:
            return 0x7F800000
        return 0xFF800000


def float_to_bf16_bits(value):
    fp32_bits = float_to_float32_bits(value)
    exponent = fp32_bits & 0x7F800000
    mantissa = fp32_bits & 0x007FFFFF

    if exponent == 0x7F800000:
        if mantissa:
            return ((fp32_bits >> 16) | 0x0040) & 0xFFFF
        return (fp32_bits >> 16) & 0xFFFF

    round_bias = 0x7FFF + ((fp32_bits >> 16) & 1)
    return ((fp32_bits + round_bias) >> 16) & 0xFFFF


def format_decimal(value):
    if _isnan(value):
        return "nan"
    if _isinf(value):
        if value > 0:
            return "inf"
        return "-inf"
    return "%.9g" % value


def read_tokens(values):
    if values:
        return values
    if sys.stdin.isatty():
        raise ValueError("provide at least one value or pipe data through stdin")
    piped = sys.stdin.read().split()
    if not piped:
        raise ValueError("stdin did not contain any values")
    return piped


def main():
    parser = OptionParser(
        usage="%prog --to-dec|--to-bf16 [--plain] [values ...]"
    )
    parser.add_option("--to-dec",  dest="to_dec",  action="store_true",
                      default=False,
                      help="interpret inputs as BF16 hex, print decimal values")
    parser.add_option("--to-bf16", dest="to_bf16", action="store_true",
                      default=False,
                      help="interpret inputs as decimal values, print BF16 hex")
    parser.add_option("--plain",   dest="plain",   action="store_true",
                      default=False,
                      help="print only converted values, one per line")

    opts, args = parser.parse_args()

    if not opts.to_dec and not opts.to_bf16:
        parser.error("one of --to-dec or --to-bf16 is required")
    if opts.to_dec and opts.to_bf16:
        parser.error("--to-dec and --to-bf16 are mutually exclusive")

    try:
        tokens = read_tokens(args)
    except ValueError, exc:
        parser.error(str(exc))

    for token in tokens:
        try:
            if opts.to_dec:
                normalized = normalize_bf16_token(token)
                converted  = format_decimal(bf16_to_float(normalized))
                if opts.plain:
                    output = converted
                else:
                    output = "%s -> %s" % (normalized, converted)
            else:
                decimal_value = float(token.strip().replace("_", ""))
                converted     = "%04x" % float_to_bf16_bits(decimal_value)
                if opts.plain:
                    output = converted
                else:
                    output = "%s -> %s" % (token, converted)

            sys.stdout.write(output + "\n")

        except ValueError, exc:
            sys.stderr.write("%s -> ERROR: %s\n" % (token, exc))
            return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
