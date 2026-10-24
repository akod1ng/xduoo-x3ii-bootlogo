#!/bin/sh
# xDuoo X3II boot-logo flasher
#
# The very first picture shown at power-on is NOT part of the themes or the
# system image. The bootloader (u-boot) copies 307200 bytes from the start of
# the "logo" flash partition straight into the screen buffer:
#     240 x 320 pixels, 32 bit per pixel (B,G,R,0 byte order), no header.
#
# usage:  sh bootlogo_flash.sh <logo.bin> [backup_dir]
#
# What it does:
#   1. checks logo.bin is exactly 307200 bytes
#   2. backs up the original logo (once) to <backup_dir>/original_logo.bin
#      and the whole partition to <backup_dir>/logo_partition_backup.bin
#   3. refuses to touch anything if there is a bad block in the logo area
#   4. erases only the blocks the logo occupies, writes the new logo, keeping
#      any bytes that sat behind the old logo in those blocks unchanged
#   5. reads it back and compares; if that fails the old content is restored
#
# Only the "logo" partition is written. Bootloader, kernel and system are
# never touched.

LOGO_SIZE=307200
IN="$1"
BK="${2:-/tmp}"
TMP=/tmp/bootlogo.$$

log()  { echo "[bootlogo] $*"; }
fail() { log "ERROR: $*"; rm -rf "$TMP"; exit 1; }

[ -n "$IN" ] || fail "usage: sh $0 <logo.bin> [backup_dir]"
[ -f "$IN" ] || fail "file not found: $IN"
SIZE=$(wc -c < "$IN" | tr -d ' ')
[ "$SIZE" = "$LOGO_SIZE" ] || fail "$IN is $SIZE bytes, expected $LOGO_SIZE (240x320 at 32 bit)"

LINE=$(grep '"logo"' /proc/mtd)
[ -n "$LINE" ] || fail "no \"logo\" partition found in /proc/mtd"
MTD=/dev/$(echo "$LINE" | cut -d: -f1)
PARTSIZE=$(( 0x$(echo "$LINE" | awk '{print $2}') ))
ERASESIZE=$(( 0x$(echo "$LINE" | awk '{print $3}') ))
[ "$ERASESIZE" -gt 0 ] || fail "could not read erase size from: $LINE"
BLOCKS=$(( (LOGO_SIZE + ERASESIZE - 1) / ERASESIZE ))
REGION=$(( BLOCKS * ERASESIZE ))
[ "$REGION" -le "$PARTSIZE" ] || fail "logo partition is too small"
log "partition $MTD  size=$PARTSIZE  erase=$ERASESIZE  using $BLOCKS blocks"

mkdir -p "$TMP" "$BK" || fail "cannot create $TMP or $BK"

# current content of the area we are going to rewrite
nanddump -q --bb=skipbad -l $REGION -f "$TMP/old.bin" "$MTD" || fail "reading $MTD failed"
nanddump -q --bb=padbad  -l $REGION -f "$TMP/pad.bin" "$MTD" || fail "reading $MTD failed"
[ "$(wc -c < "$TMP/old.bin" | tr -d ' ')" = "$REGION" ] || fail "short read from $MTD"
cmp -s "$TMP/old.bin" "$TMP/pad.bin" || fail "bad block inside the logo area, not touching it"
rm -f "$TMP/pad.bin"

# one-time backups (never overwritten)
if [ ! -f "$BK/original_logo.bin" ]; then
    dd if="$TMP/old.bin" of="$BK/original_logo.bin" bs=1024 count=$(( LOGO_SIZE / 1024 )) 2>/dev/null \
        || fail "could not write backup to $BK"
    log "saved original logo to $BK/original_logo.bin"
fi
if [ ! -f "$BK/logo_partition_backup.bin" ]; then
    nanddump -q --bb=skipbad -f "$BK/logo_partition_backup.bin" "$MTD" \
        && log "saved full partition to $BK/logo_partition_backup.bin"
fi
sync

# new image = new logo + whatever followed the old logo inside those blocks
dd if="$TMP/old.bin" of="$TMP/tail.bin" bs=1024 skip=$(( LOGO_SIZE / 1024 )) 2>/dev/null
cat "$IN" "$TMP/tail.bin" > "$TMP/new.bin"
[ "$(wc -c < "$TMP/new.bin" | tr -d ' ')" = "$REGION" ] || fail "internal size mismatch"

if cmp -s "$TMP/new.bin" "$TMP/old.bin"; then
    log "this logo is already installed, nothing to do"
    rm -rf "$TMP"; exit 0
fi

restore() {
    log "restoring previous content"
    flash_erase -q "$MTD" 0 $BLOCKS
    nandwrite -q -p "$MTD" "$TMP/old.bin"
}

log "erasing $BLOCKS blocks"
flash_erase -q "$MTD" 0 $BLOCKS || fail "erase failed (nothing was written)"
log "writing new logo"
nandwrite -q -p "$MTD" "$TMP/new.bin" || { restore; fail "write failed, old logo restored"; }

nanddump -q --bb=skipbad -l $REGION -f "$TMP/check.bin" "$MTD"
if ! cmp -s "$TMP/new.bin" "$TMP/check.bin"; then
    restore; fail "verify failed, old logo restored"
fi
sync
rm -rf "$TMP"
log "done - new boot logo is installed, it shows on the next power-on"
exit 0
