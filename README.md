# xDuoo X3II boot logo

Replace the pictures the xDuoo X3II shows when you switch it on and off: the "xDuoo · Hi-Fi Digital Audio Player" splash, the plain "xDuoo" screen after it, and the "xDuoo" fade-out at shutdown.

Themes can't change these. The splash lives in a flash partition of its own that the bootloader reads before Linux starts. Firmware updates never write that partition, and the running kernel refuses to. This project adds two things to [SinuXVR's custom firmware](https://github.com/SinuXVR/xDuoo-X3II-custom-firmware):
- a start-up script that takes your pictures from the SD card and installs them;
- a 4-byte kernel patch that lets that script write the logo partition.

It also includes a converter that turns any picture into the files the script expects.

**Converter:** https://akod1ng.github.io/xduoo-x3ii-bootlogo/ (runs in the browser, nothing is uploaded)

![Converter](docs/converter.png)

> **Status.** The second start screen is confirmed working on a real player. The first hardware test of the splash found the kernel's write guard (see [The kernel guard](#the-kernel-guard)); the fix is in, and the patched build has not been confirmed on hardware yet. The shutdown frames are new as well. The colour byte order (B, G, R, 0) follows the bootloader and the factory logo, which is grey, so red/blue order isn't proven yet. If yours comes out swapped, use "Swap red and blue". Reports welcome.

## Quick start

1. **Build the firmware** (once). Get `update.upt` from [SinuXVR's repository](https://github.com/SinuXVR/xDuoo-X3II-custom-firmware) (the bigger-font and Chinese variants work too) and run:
   ```sh
   sudo tools/build_update.sh update.upt update_bootlogo.upt
   ```
   See [Building](#building-the-firmware) for requirements, or use the Docker one-liner there.
2. **Install it.** Rename the result to `update.upt`, copy it to the root of the SD card and run *System settings → Firmware update*. Themes in `.themes` on the card are kept. Keep a copy of the firmware you had before on the card under another name; see [If the player doesn't start](#if-the-player-doesnt-start).
3. **Make the pictures.** Open the [converter](https://akod1ng.github.io/xduoo-x3ii-bootlogo/), drop in a picture, position it, and download `bootlogo.zip`. Or use the command line:
   ```sh
   python3 tools/make_logo.py picture.jpg
   ```
   This writes `bootlogo/logo.bin`, `bootlogo/boot_animation.png` and `bootlogo/shutdown_animation/animation00.png` to `animation12.png`.
4. **Put them on the card.** The `bootlogo` folder goes in the root of the SD card.
5. **Start, wait, switch off, start again.** On start-up the player installs what it finds, which takes a few seconds, and writes a log to `bootlogo/flash_log.txt`. Finished items are renamed (`logo.bin.done`, `shutdown_animation.done`, …). Wait about half a minute before switching off. The shutdown animation shows on that switch-off; the new splash shows on the next power-on.

**Undo:** the first run saves the originals in `bootlogo/` (`original_logo.bin`, `original_boot_animation.png`, `original_shutdown_animation/`). Copy them back under the names above and restart.

### If the player doesn't start

The bootloader starts the separate recovery system when **Previous (⏮)**, which the kernel calls the "up" key on GPIO 37, is held while switching on. Recovery installs `update.upt` from the card. So:
1. Put a firmware you know works on the card as `update.upt`, using a card reader.
2. Hold ⏮ and switch on.

This is read from the bootloader code and hasn't been tried on hardware yet.

### Without reflashing (ADB, untested)

The player software starts `adbd` when connected over USB. With the patched kernel already installed, this may work:

```sh
adb push firmware/bootlogo_flash.sh /tmp/
adb push bootlogo/logo.bin /tmp/
adb shell sh /tmp/bootlogo_flash.sh /tmp/logo.bin /mnt/sd_0
```

## How it works

### Flash layout

From the partition table in the kernel (`uImage`, board `ingenic-x3ii`), SPI NAND with 128 KiB erase blocks and 2 KiB pages:

| mtd | name | offset | size |
|---|---|---|---|
| mtd0 | uboot | `0x0000000` | 512 KiB |
| mtd1 | **logo** | `0x0080000` | 2.5 MiB |
| mtd2 | kernel | `0x0300000` | 6 MiB |
| mtd3 | recovery | `0x0900000` | 7 MiB |
| mtd4 | rootfs | `0x1000000` | 64 MiB |
| mtd5 | data | `0x5000000` | rest |

`update.upt` is an ISO image containing `uboot.bin`, `uimage.bin` and `system.ubi` (UBIFS), and `update.txt` lists only those three. The logo partition is never part of an update.

The logo partition holds more than the logo. At offset `0x240000` it stores a 12-character hex ID, written twice, that looks like the player's Bluetooth MAC address. The flasher only rewrites the first three erase blocks (384 KiB) and keeps everything after the picture, so that ID is untouched. Don't erase the whole partition.

### The bootloader

U-Boot 2013.07 for the Ingenic X1000. With the panel in 32-bit mode it prints `draw logo` and runs

```
sfcnand read 0x80000 0x4b000 <framebuffer address>
```

That copies 0x4B000 = 307 200 bytes from the start of the logo partition straight into the framebuffer: 240 × 320 pixels × 4 bytes, no header, no compression, rows top to bottom. xDuoo's own logo uses `B G R 0` per pixel, and the converter writes the same. That logo is grey; the bootloader doesn't apply the colour correction the running system does, which is why it looks gold on screen. Your picture gets a similar cast during those first seconds.

### The kernel guard

The kernel's SPI NAND driver (`drivers/mtd/nand/jz_sfcnand.c`) refuses every write and erase below 16 MiB with `-EIO`. That covers bootloader, logo, kernel and recovery:

```
jz_sfc_nandflash_write   0x802791f4:  lui v0,0x100 ; sltu v0,a2,v0    addr < 0x1000000 -> -EIO
jz_sfc_nandflash_erase   0x802795fc:  lui v0,0x100 ; sltu v0,s2,v0    addr < 0x1000000 -> -EIO
```

On an unpatched kernel the flasher logs `MEMERASE64 ioctl failed … error 5` and changes nothing. `tools/patch_kernel.py` changes both immediates from `0x100` to `0x8`, which lowers the limit to `0x80000`, the end of the bootloader partition. The bootloader stays protected; the logo partition and everything above it become writable. Exactly 4 bytes of the 5 MiB kernel change. The script checks that each pattern occurs exactly once and repacks the gzip uImage with fresh CRCs, keeping load address, entry point and name. Firmware updates themselves run from the recovery system, which has its own kernel and isn't affected.

### The second screen and the shutdown animation

After the kernel starts, the player software (`hiby_player`) shows `/usr/resource/gui/boot_animation/animation00.png`, a 240 × 320 PNG with "xDuoo" on black. When switching off, it plays `/usr/resource/gui/shutdown_animation/animation00.png` to `animation12.png`, "xDuoo" fading to black. Both are ordinary files in the root filesystem. The converter makes the shutdown frames by fading your picture to black in 13 steps.

### What the hook does

`firmware/S92_01_bootlogo` runs at start-up in the background, so it adds no boot time. It waits for the SD card and then works through the `bootlogo` folder.

**`logo.bin`:** runs `firmware/bootlogo_flash.sh`, which:
1. checks the file is exactly 307 200 bytes;
2. finds the `logo` partition in `/proc/mtd` and reads the blocks it will rewrite;
3. refuses to continue if there is a bad block in that area;
4. saves `original_logo.bin` and a full `logo_partition_backup.bin` to the card, once only;
5. erases only the 3 blocks the logo occupies and writes the new logo plus the bytes that followed the old one in those blocks, unchanged;
6. reads it back and compares, and on a mismatch writes the old content back.

**`boot_animation.png` and `shutdown_animation/`:** copies them over the player's files after saving the originals to the card.

Only the logo partition and those PNG files are written. A bad logo means a garbled splash, and the player still boots.

## Building the firmware

`tools/build_update.sh`:
1. unpacks `update.upt`;
2. adds `usr/bin/bootlogo_flash.sh` and `etc/init.d/S92_01_bootlogo` to the root filesystem, with the same owner and mode as the other init scripts;
3. rebuilds `system.ubi` with the original parameters (`mkfs.ubifs -x lzo -e 0x1F000 -c 1024 -m 0x800`);
4. patches the kernel with `tools/patch_kernel.py`;
5. recomputes every md5 in `update.txt`, packs the ISO again, and checks every md5 in the result.

The bootloader is copied unchanged.

Linux, as root, with `mtd-utils`, `genisoimage`, `libarchive-tools` (or `p7zip`), `python3` and `ubi_reader`:

```sh
sudo apt install mtd-utils genisoimage libarchive-tools python3-pip
sudo pip install ubi_reader            # add --break-system-packages on newer distros
sudo tools/build_update.sh update.upt update_bootlogo.upt
```

On macOS or Windows, Docker does the same:

```sh
docker run --rm -v "$PWD":/w -w /w ubuntu:24.04 bash -c \
  "apt-get update -qq && apt-get install -y -qq mtd-utils genisoimage libarchive-tools python3-pip >/dev/null \
   && pip install -q --break-system-packages ubi_reader \
   && tools/build_update.sh update.upt update_bootlogo.upt"
```

Compared with SinuXVR's package, the result differs in exactly these places: the two added files in the root filesystem, the 4 kernel bytes, and the two md5 lines in `update.txt` that follow from them.

## Tests

```sh
tests/run_tests.sh
```

Runs the flasher and the start-up hook under `busybox sh` (the player's shell) against a simulated NAND partition. The simulation follows NAND rules: erase sets bytes to `0xFF` and writes can only clear bits. Cases covered: normal write, rewriting the same logo, wrong file size, restoring the backup, a bad block in the logo area, a missing logo partition, and a full hook run with logo, second screen and shutdown frames.

## Layout

```
firmware/bootlogo_flash.sh   writes logo.bin into the logo partition (runs on the player)
firmware/S92_01_bootlogo     init script that installs everything from the SD card at start-up
tools/build_update.sh        adds both to an update.upt and patches the kernel
tools/patch_kernel.py        lowers the flash driver's write guard so the logo can be written
tools/make_logo.py           picture -> logo.bin, boot_animation.png, shutdown frames (and --show logo.bin -> png)
docs/index.html              browser converter (GitHub Pages)
tests/                       simulated-flash tests for flasher and hook
```

## Credits

- [SinuXVR](https://github.com/SinuXVR/xDuoo-X3II-custom-firmware) for the custom firmware this builds on. This repository doesn't redistribute it; download it from there.
- xDuoo for the X3II. Not affiliated with xDuoo.

Modifying firmware is at your own risk.

## License

MIT for the code in this repository (see `LICENSE`). The firmware itself belongs to its respective owners.
