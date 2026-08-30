#!/usr/bin/env python3
"""
elf2coe.py - convert a bare-metal ELF into a Xilinx .coe file for blk_mem_gen.

Usage:
    elf2coe.py <input.elf> <output.coe> [--depth 16384] [--base 0x80000000]

Uses objcopy to flatten the ELF into a raw binary image, then emits one
32-bit little-endian word per line in hex.

Only loaded sections end up in the image. .bss is NOLOAD, so it contributes
nothing here; crt0.S zeroes it at boot.
"""

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

OBJCOPY = "riscv32-unknown-elf-objcopy"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("elf")
    ap.add_argument("coe")
    ap.add_argument("--depth", type=int, default=16384,
                    help="memory depth in 32-bit words (default 16384)")
    ap.add_argument("--base", type=lambda s: int(s, 0), default=0x80000000,
                    help="memory base address (default 0x80000000)")
    ap.add_argument("--objcopy", default=OBJCOPY)
    args = ap.parse_args()

    elf = Path(args.elf)
    if not elf.is_file():
        sys.exit(f"error: {elf} not found")

    if shutil.which(args.objcopy) is None:
        sys.exit(f"error: {args.objcopy} not on PATH")

    # Flatten to a raw binary. objcopy emits from the lowest to the highest
    # loaded address, zero-filling any gaps.
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as tmp:
        binpath = Path(tmp.name)
    try:
        subprocess.run(
            [args.objcopy, "-O", "binary", str(elf), str(binpath)],
            check=True,
        )
        data = binpath.read_bytes()
    finally:
        binpath.unlink(missing_ok=True)

    if not data:
        sys.exit("error: image is empty; check that .text was not "
                 "garbage-collected (KEEP on .text.init in link.ld)")

    # Pad to a whole number of 32-bit words
    if len(data) % 4:
        data += b"\x00" * (4 - len(data) % 4)

    words = [int.from_bytes(data[i:i + 4], "little")
             for i in range(0, len(data), 4)]

    if len(words) > args.depth:
        sys.exit(f"error: image is {len(words)} words but memory holds "
                 f"{args.depth}. Increase blk_mem_gen depth and MEM_DEPTH.")

    out = Path(args.coe)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w") as f:
        f.write("memory_initialization_radix=16;\n")
        f.write("memory_initialization_vector=\n")
        for i, w in enumerate(words):
            sep = ";" if i == len(words) - 1 else ","
            f.write(f"{w:08x}{sep}\n")

    used = 100.0 * len(words) / args.depth
    print(f"{elf.name}: {len(words)} words ({len(data)} bytes), "
          f"{used:.1f}% of {args.depth}")
    print(f"base 0x{args.base:08x} .. 0x{args.base + len(data) - 1:08x}")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
