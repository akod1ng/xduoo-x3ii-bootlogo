#!/usr/bin/env python3
"""Make an xDuoo X3II boot logo from any picture (command-line version of docs/index.html).

    python3 tools/make_logo.py picture.jpg              -> bootlogo/logo.bin, boot_animation.png, shutdown_animation/
    python3 tools/make_logo.py picture.png --fit --bg "#202020"
    python3 tools/make_logo.py --show original_logo.bin  -> original_logo.png (decode a .bin to check it)

The logo is 240 x 320 pixels, 4 bytes per pixel in B, G, R, 0 order (307 200 bytes),
exactly what the bootloader copies from the "logo" flash partition into the screen.
Copy the resulting bootlogo folder to the root of the SD card. Needs Pillow.
"""
import argparse
import os
import sys

try:
    from PIL import Image, ImageOps
except ImportError:
    sys.exit("Pillow is needed: pip install Pillow")

W, H = 240, 320
LOGO_BYTES = W * H * 4


def frame(img, fit, bg):
    img = ImageOps.exif_transpose(img).convert("RGBA")
    if fit:
        img = ImageOps.contain(img, (W, H), Image.LANCZOS)
    else:
        img = ImageOps.fit(img, (W, H), Image.LANCZOS)
    canvas = Image.new("RGBA", (W, H), bg)
    canvas.alpha_composite(img, ((W - img.width) // 2, (H - img.height) // 2))
    return canvas.convert("RGB")


def to_logo(rgb, swap):
    raw = rgb.tobytes()                      # R G B R G B ...
    out = bytearray(LOGO_BYTES)              # 4th byte stays 0x00, as in xDuoo's own logo
    out[0::4] = raw[0::3] if swap else raw[2::3]
    out[1::4] = raw[1::3]
    out[2::4] = raw[2::3] if swap else raw[0::3]
    return bytes(out)


def from_logo(data, swap):
    data = data[:LOGO_BYTES]
    if len(data) < LOGO_BYTES:
        sys.exit(f"file has {len(data)} bytes, a logo needs {LOGO_BYTES}")
    rgb = bytearray(W * H * 3)
    rgb[0::3] = data[0::4] if swap else data[2::4]
    rgb[1::3] = data[1::4]
    rgb[2::3] = data[2::4] if swap else data[0::4]
    return Image.frombytes("RGB", (W, H), bytes(rgb))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("picture", nargs="?", help="any picture Pillow can open")
    ap.add_argument("-o", "--out", default="bootlogo", help="output folder (default: bootlogo)")
    ap.add_argument("--fit", action="store_true", help="show the whole picture instead of filling the screen")
    ap.add_argument("--bg", default="#000000", help="background colour where the picture doesn't cover (default black)")
    ap.add_argument("--swap", action="store_true", help="swap red and blue (only if colours come out wrong)")
    ap.add_argument("--no-animation", action="store_true", help="don't write boot_animation.png")
    ap.add_argument("--no-shutdown", action="store_true", help="don't write the shutdown_animation frames")
    ap.add_argument("--show", metavar="BIN", help="decode a logo .bin to a PNG instead")
    a = ap.parse_args()

    if a.show:
        with open(a.show, "rb") as f:
            img = from_logo(f.read(), a.swap)
        dest = os.path.splitext(a.show)[0] + ".png"
        img.save(dest)
        print(f"wrote {dest}")
        return

    if not a.picture:
        ap.error("give a picture, or --show file.bin")
    rgb = frame(Image.open(a.picture), a.fit, a.bg)
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "logo.bin"), "wb") as f:
        f.write(to_logo(rgb, a.swap))
    print(f"wrote {os.path.join(a.out, 'logo.bin')}")
    if not a.no_animation:
        rgb.save(os.path.join(a.out, "boot_animation.png"))
        print(f"wrote {os.path.join(a.out, 'boot_animation.png')}")
    if not a.no_shutdown:
        sd = os.path.join(a.out, "shutdown_animation")
        os.makedirs(sd, exist_ok=True)
        black = Image.new("RGB", (W, H))
        for i, step in enumerate(fade_frames(rgb, black)):
            step.save(os.path.join(sd, f"animation{i:02d}.png"))
        print(f"wrote {sd}/animation00.png ... animation{SHUTDOWN_FRAMES - 1:02d}.png")
    print("copy the folder to the root of the SD card and restart the player")


SHUTDOWN_FRAMES = 13


def fade_frames(rgb, black):
    """13 frames from the full picture down to black, like xDuoo's own shutdown animation."""
    return [Image.blend(rgb, black, i / (SHUTDOWN_FRAMES - 1)) for i in range(SHUTDOWN_FRAMES)]


if __name__ == "__main__":
    main()
