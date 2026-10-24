#!/usr/bin/env bash
# Add the boot-logo hook to an xDuoo X3II firmware package (update.upt).
#
# usage:  sudo tools/build_update.sh <path/to/update.upt> [output.upt]
#
# Input is meant to be SinuXVR's custom firmware
# (https://github.com/SinuXVR/xDuoo-X3II-custom-firmware), any of its
# variants. The output is the same package with two extra files in the
# root filesystem:
#     /usr/bin/bootlogo_flash.sh
#     /etc/init.d/S92_01_bootlogo
# Kernel and bootloader are copied unchanged; only the rootfs md5 in
# update.txt is updated. Run on Linux, as root (the image keeps the
# original file owners, which needs root to reproduce).
#
# needs: mkfs.ubifs (mtd-utils), genisoimage, ubireader_extract_files
#        (pip install ubi_reader), bsdtar (libarchive-tools) or 7z, md5sum

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: sudo $0 <update.upt> [output.upt]"
IN=$(realpath "$1")
OUT=$(realpath -m "${2:-update_bootlogo.upt}")
REPO=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$IN" ] || die "not found: $IN"
[ "$(id -u)" = 0 ] || die "run as root (sudo), needed to keep file ownership inside the image"
for t in mkfs.ubifs genisoimage ubireader_extract_files md5sum; do
    command -v "$t" >/dev/null || die "missing tool: $t"
done

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir "$W/iso"

echo "1/5 unpacking $IN"
if command -v bsdtar >/dev/null; then
    bsdtar -xf "$IN" -C "$W/iso"
elif command -v 7z >/dev/null; then
    7z x -y -o"$W/iso" "$IN" >/dev/null
else
    die "need bsdtar or 7z to open the .upt (it is an ISO image)"
fi
# normalise names to lower case without ISO version suffix
for f in "$W/iso"/*; do
    n=$(basename "$f" | tr 'A-Z' 'a-z' | sed 's/;1$//')
    [ "$(basename "$f")" = "$n" ] || mv "$f" "$W/iso/$n"
done
for f in update.txt system.ubi uimage.bin; do
    [ -f "$W/iso/$f" ] || die "$f not found in package, is this an X3II update.upt?"
done

echo "2/5 extracting root filesystem"
ubireader_extract_files -k -o "$W/rootfs" "$W/iso/system.ubi" >/dev/null
[ -x "$W/rootfs/usr/bin/hiby_player" ] || die "extracted rootfs looks wrong (no /usr/bin/hiby_player)"

echo "3/5 adding boot-logo hook"
OWN=$(stat -c '%u:%g' "$W/rootfs/etc/init.d/rcS")
install -m 0775 -o "${OWN%:*}" -g "${OWN#*:}" "$REPO/firmware/bootlogo_flash.sh" "$W/rootfs/usr/bin/bootlogo_flash.sh"
install -m 0775 -o "${OWN%:*}" -g "${OWN#*:}" "$REPO/firmware/S92_01_bootlogo"   "$W/rootfs/etc/init.d/S92_01_bootlogo"
if grep -q $'\r' "$W/rootfs/usr/bin/bootlogo_flash.sh" "$W/rootfs/etc/init.d/S92_01_bootlogo"; then
    die "the firmware scripts have Windows line endings, convert them to LF first"
fi

echo "4/5 rebuilding system.ubi"
# same parameters as the original image: 2 KiB pages, 128 KiB blocks, LZO
mkfs.ubifs -x lzo -d "$W/rootfs" -e 0x1F000 -c 1024 -m 0x800 -o "$W/iso/system.ubi"
MD5=$(md5sum "$W/iso/system.ubi" | cut -d' ' -f1)
awk -v md5="$MD5" '
    /^[a-z_]+=\{/ { sec = $1 }
    sec ~ /^rootfs=/ && /md5=/ { sub(/md5=[0-9a-fA-F]+/, "md5=" md5) }
    { print }
' "$W/iso/update.txt" > "$W/update.txt.new"
mv "$W/update.txt.new" "$W/iso/update.txt"

echo "5/5 packing $OUT"
genisoimage -quiet -r -o "$OUT" "$W/iso"

# verify every md5 listed in update.txt against the packed files
mkdir "$W/check"
if command -v bsdtar >/dev/null; then bsdtar -xf "$OUT" -C "$W/check"; else 7z x -y -o"$W/check" "$OUT" >/dev/null; fi
ok=1
while read -r path sum; do
    real=$(md5sum "$W/check/$path" | cut -d' ' -f1)
    if [ "$real" = "$sum" ]; then echo "   md5 ok  $path"; else echo "   MD5 MISMATCH  $path"; ok=0; fi
done < <(awk -F= '/file_path=/ { sub(/^autoupdate\//, "", $2); p = $2 } /md5=/ { print p, $2 }' "$W/check/update.txt")
[ $ok = 1 ] || die "package check failed"
echo "done: $OUT"
echo "copy it to the SD card root as update.upt and run Firmware update on the player"
