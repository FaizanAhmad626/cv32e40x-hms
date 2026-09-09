#!/usr/bin/env python3
"""
elf2coe.py - convert an ELF into a Xilinx .coe file for blk_mem_gen.

Usage:
    elf2coe.py <input.elf> <output.coe>

Reads the ELF's program headers directly instead of shelling out to objcopy,
so it needs no toolchain on PATH and does not care which compiler built the
file: GNU (riscv32-unknown-elf-*), SEGGER (riscv32-none-elf-*), 32- or 64-bit,
Linux, WSL or native Windows all work the same way.

An ELF is a container. The bytes that belong in memory live in its PT_LOAD
program headers, each tagged with the address it loads at. They are copied
into a flat image starting at the lowest load address, any gap between them
left as zeros, and written out as one 32-bit little-endian word per line in
hex. Word 0 of the file is word 0 of the BRAM.

Segments that reserve space but store no bytes, such as .bss and .stack,
contribute nothing here; crt0 zeroes .bss at boot.
"""

import argparse
import struct
import sys
from pathlib import Path

PT_LOAD = 1


def load_segments(blob):
    """Return [(load_address, data)] for each PT_LOAD segment holding data."""
    if blob[:4] != b"\x7fELF":
        sys.exit("error: not an ELF file")

    if blob[4] == 2:                            # 64-bit
        ph_off, = struct.unpack_from("<Q", blob, 32)
        ph_size, ph_num = struct.unpack_from("<HH", blob, 54)
        phdr = "<I4xQ8xQQ"                      # type, offset, paddr, filesz
    else:                                       # 32-bit
        ph_off, = struct.unpack_from("<I", blob, 28)
        ph_size, ph_num = struct.unpack_from("<HH", blob, 42)
        phdr = "<II4xII"                        # type, offset, paddr, filesz

    segments = []
    for i in range(ph_num):
        p_type, p_offset, p_paddr, p_filesz = struct.unpack_from(
            phdr, blob, ph_off + i * ph_size)
        if p_type == PT_LOAD and p_filesz:
            segments.append((p_paddr, blob[p_offset:p_offset + p_filesz]))
    return segments


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("elf")
    ap.add_argument("coe")
    args = ap.parse_args()

    segments = load_segments(Path(args.elf).read_bytes())

    start = min(addr for addr, _ in segments)
    size = max(addr + len(data) for addr, data in segments) - start
    image = bytearray(size)
    for addr, data in segments:
        image[addr - start:addr - start + len(data)] = data

    # Pad to a whole number of 32-bit words
    if len(image) % 4:
        image += b"\x00" * (4 - len(image) % 4)

    words = [int.from_bytes(image[i:i + 4], "little")
             for i in range(0, len(image), 4)]

    with Path(args.coe).open("w") as f:
        f.write("memory_initialization_radix=16;\n")
        f.write("memory_initialization_vector=\n")
        f.write(",\n".join(f"{w:08x}" for w in words) + ";\n")


if __name__ == "__main__":
    main()
