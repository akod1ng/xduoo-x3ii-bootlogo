#!/usr/bin/env python3
"""Let the running X3II kernel write the "logo" flash partition.

    python3 tools/patch_kernel.py uimage.bin uimage_patched.bin

The SPI NAND driver (drivers/mtd/nand/jz_sfcnand.c) refuses every erase and
write below 16 MiB with -EIO. That covers bootloader, logo, kernel and
recovery, so from the normal system the logo can't be changed:

    jz_sfc_nandflash_write:   lui v0,0x100 ; sltu v0,a2,v0   -> addr < 0x1000000 ? -EIO
    jz_sfc_nandflash_erase:   lui v0,0x100 ; sltu v0,s2,v0   -> addr < 0x1000000 ? -EIO

This lowers both limits to 0x80000, the end of the bootloader partition, so the
bootloader stays protected and everything from the logo partition up becomes
writable. Exactly two 16-bit immediates change; the script checks that each
pattern occurs exactly once and that nothing else differs, then repacks the
gzip uImage with fresh CRCs (same load address, entry point and name).
"""
import gzip
import struct
import sys
import zlib

UIMAGE_MAGIC = 0x27051956
OLD_LIMIT, NEW_LIMIT = 0x0100, 0x0008          # lui immediates: 0x1000000 -> 0x80000
GUARDS = {
    "write": (0x3C020100, 0x00C2102B),          # lui v0,0x100 ; sltu v0,a2,v0
    "erase": (0x3C020100, 0x0242102B),          # lui v0,0x100 ; sltu v0,s2,v0
}


def die(msg):
    sys.exit(f"error: {msg}")


def main():
    if len(sys.argv) != 3:
        die("usage: patch_kernel.py <uimage.bin> <output.bin>")
    raw = open(sys.argv[1], "rb").read()
    hdr = raw[:64]
    (magic, hcrc, tstamp, size, load, ep, dcrc, os_, arch, typ, comp, name) = struct.unpack(">IIIIIIIBBBB32s", hdr)
    if magic != UIMAGE_MAGIC:
        die("not a uImage")
    if comp != 1:
        die(f"expected a gzip compressed kernel, compression type is {comp}")
    if zlib.crc32(hdr[:4] + b"\0\0\0\0" + hdr[8:]) & 0xFFFFFFFF != hcrc:
        die("header CRC mismatch in input")
    data = raw[64:64 + size]
    if zlib.crc32(data) & 0xFFFFFFFF != dcrc:
        die("data CRC mismatch in input")
    kernel = bytearray(gzip.decompress(data))
    print(f"kernel {name.rstrip(b'\0').decode()}  load 0x{load:08x}  entry 0x{ep:08x}  {len(kernel)} bytes unpacked")

    for label, (lui, sltu) in GUARDS.items():
        pat = struct.pack("<II", lui, sltu)
        hits = []
        i = kernel.find(pat)
        while i >= 0:
            if i % 4 == 0:
                hits.append(i)
            i = kernel.find(pat, i + 1)
        if len(hits) == 0:
            new = struct.pack("<II", (lui & 0xFFFF0000) | NEW_LIMIT, sltu)
            if kernel.find(new) >= 0:
                die(f"{label} guard is already patched")
            die(f"{label} guard not found, this kernel is different from the one this was written for")
        if len(hits) > 1:
            die(f"{label} guard found {len(hits)} times, refusing to guess")
        off = hits[0]
        struct.pack_into("<I", kernel, off, (lui & 0xFFFF0000) | NEW_LIMIT)
        print(f"  {label:5} guard at 0x{load + off:08x}: limit 0x{OLD_LIMIT << 16:x} -> 0x{NEW_LIMIT << 16:x}")

    original = gzip.decompress(data)
    changed = [i for i in range(len(original)) if original[i] != kernel[i]]
    if len(changed) != 4 or len(kernel) != len(original):
        die(f"unexpected difference after patching ({len(changed)} bytes changed)")

    new_data = gzip.compress(bytes(kernel), compresslevel=9, mtime=0)
    new_data = new_data[:9] + data[9:10] + new_data[10:]   # keep the original gzip OS byte (Unix)
    if gzip.decompress(new_data) != bytes(kernel):
        die("recompression check failed")
    new_hdr = struct.pack(">IIIIIIIBBBB32s", UIMAGE_MAGIC, 0, tstamp, len(new_data), load, ep,
                          zlib.crc32(new_data) & 0xFFFFFFFF, os_, arch, typ, comp, name)
    new_hdr = new_hdr[:4] + struct.pack(">I", zlib.crc32(new_hdr) & 0xFFFFFFFF) + new_hdr[8:]
    out = new_hdr + new_data
    # u-boot loads 4 MiB from the kernel partition: sfcnand read 0x300000 0x400000 ...
    if len(out) > 0x400000:
        die(f"patched image is {len(out)} bytes, more than the 4 MiB the bootloader loads")
    open(sys.argv[2], "wb").write(out)
    print(f"wrote {sys.argv[2]}  ({len(out)} bytes, was {len(raw)})")


if __name__ == "__main__":
    main()
