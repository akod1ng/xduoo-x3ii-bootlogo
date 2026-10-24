#!/usr/bin/env python3
"""Stand-ins for nanddump, flash_erase and nandwrite that act on a file.

Invoked through symlinks named after the tool. The fake NAND lives in
$SIM_DIR/<mtdN>.img with 128 KiB erase blocks and 2 KiB pages; block numbers
listed in $SIM_DIR/bad are treated as bad blocks. Writes follow NAND rules:
erase sets bytes to 0xFF, a write can only clear bits.
"""
import os
import sys

SIM = os.environ["SIM_DIR"]
ES, PG = 0x20000, 0x800
tool = os.path.basename(sys.argv[0])
args = sys.argv[1:]
bad_path = os.path.join(SIM, "bad")
bad = set(int(x) for x in open(bad_path).read().split()) if os.path.exists(bad_path) else set()


def img(dev):
    return os.path.join(SIM, os.path.basename(dev) + ".img")


if tool == "nanddump":
    bb, length, out, dev, i = "padbad", None, None, None, 0
    while i < len(args):
        x = args[i]
        if x.startswith("--bb="):
            bb = x[5:]
        elif x == "-l":
            length = int(args[i + 1], 0); i += 1
        elif x == "-f":
            out = args[i + 1]; i += 1
        elif not x.startswith("-"):
            dev = x
        i += 1
    data = open(img(dev), "rb").read()
    blocks = []
    for b in range(len(data) // ES):
        if b in bad:
            if bb == "skipbad":
                continue
            blocks.append(b"\xff" * ES)
        else:
            blocks.append(data[b * ES:(b + 1) * ES])
    res = b"".join(blocks)
    open(out, "wb").write(res if length is None else res[:length])

elif tool == "flash_erase":
    dev, start, count = [x for x in args if not x.startswith("-")]
    data = bytearray(open(img(dev), "rb").read())
    for b in range(int(start), int(start) + int(count)):
        if b not in bad:
            data[b * ES:(b + 1) * ES] = b"\xff" * ES
    open(img(dev), "wb").write(data)

elif tool == "nandwrite":
    dev, src = [x for x in args if not x.startswith("-")]
    data = bytearray(open(img(dev), "rb").read())
    new = open(src, "rb").read()
    if len(new) % PG:
        new += b"\xff" * (PG - len(new) % PG)
    pos, b = 0, 0
    while pos < len(new):
        while b in bad:
            b += 1
        for k, v in enumerate(new[pos:pos + ES]):
            data[b * ES + k] &= v
        pos += ES
        b += 1
    open(img(dev), "wb").write(data)

else:
    sys.exit(f"unknown tool {tool}")
