#!/usr/bin/env bash
# Runs firmware/bootlogo_flash.sh against a simulated logo partition.
# Uses busybox sh (the player's shell) when installed, otherwise sh.
#   tests/run_tests.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export SIM_DIR="$T/dev"

mkdir -p "$T/bin"
for t in nanddump flash_erase nandwrite; do ln -s "$HERE/mtdmock.py" "$T/bin/$t"; done
chmod +x "$HERE/mtdmock.py"

SH=sh
if command -v busybox >/dev/null; then
    SH="$(command -v busybox) sh"
    mkdir -p "$T/bb"
    for c in sh wc cut awk dd cmp cat grep tr mkdir rm sync mv cp date sleep head; do ln -s "$(command -v busybox)" "$T/bb/$c"; done
    TPATH="$T/bin:$T/bb:$(dirname "$(command -v python3)")"
else
    TPATH="$T/bin:$PATH"
fi

sed "s#/proc/mtd#$T/proc_mtd#" "$REPO/firmware/bootlogo_flash.sh" > "$T/flash.sh"
run() { (cd "$T" && env PATH="$TPATH" $SH flash.sh "$@"); }

reset() {
    rm -rf "$T/dev" "$T/bk"; mkdir -p "$T/dev" "$T/bk"
    printf 'dev:    size   erasesize  name\nmtd0: 00080000 00020000 "uboot"\nmtd1: 00280000 00020000 "logo"\n' > "$T/proc_mtd"
    python3 - "$T" <<'EOF'
import random, sys
t = sys.argv[1]; random.seed(1)
orig = bytes(random.getrandbits(8) for _ in range(307200))
tail = b"TAILDATA" * ((393216 - 307200) // 8)
rest = bytes(random.getrandbits(8) for _ in range(0x280000 - 393216))
open(f"{t}/dev/mtd1.img", "wb").write(orig + tail + rest)
open(f"{t}/orig_part.bin", "wb").write(orig + tail + rest)
open(f"{t}/new_logo.bin", "wb").write(bytes((i * 7) & 0xFF for i in range(307200)))
open(f"{t}/bad_size.bin", "wb").write(b"x" * 1000)
EOF
}

fails=0
check() { if [ "$1" = "$2" ]; then echo "  ok    $3"; else echo "  FAIL  $3 (got $1, want $2)"; fails=$((fails + 1)); fi; }
py() { python3 -c "$1" "$T"; }

echo "write a new logo"; reset
run new_logo.bin bk >/dev/null; check $? 0 "exit code"
check "$(py 'import sys;t=sys.argv[1];d=open(t+"/dev/mtd1.img","rb").read();print(d[:307200]==open(t+"/new_logo.bin","rb").read())')" True "logo written"
check "$(py 'import sys;t=sys.argv[1];d=open(t+"/dev/mtd1.img","rb").read();o=open(t+"/orig_part.bin","rb").read();print(d[307200:]==o[307200:])')" True "rest of partition unchanged"
check "$(py 'import sys;t=sys.argv[1];print(open(t+"/bk/original_logo.bin","rb").read()==open(t+"/orig_part.bin","rb").read()[:307200])')" True "original logo backed up"
check "$(py 'import sys;t=sys.argv[1];print(open(t+"/bk/logo_partition_backup.bin","rb").read()==open(t+"/orig_part.bin","rb").read())')" True "full partition backed up"

echo "same logo again"
out=$(run new_logo.bin bk); check $? 0 "exit code"
case "$out" in *"already installed"*) check yes yes "detected as already installed";; *) check no yes "detected as already installed";; esac

echo "wrong file size"
run bad_size.bin bk >/dev/null; check $? 1 "rejected"

echo "restore the backup"
run bk/original_logo.bin bk >/dev/null; check $? 0 "exit code"
check "$(py 'import sys;t=sys.argv[1];print(open(t+"/dev/mtd1.img","rb").read()==open(t+"/orig_part.bin","rb").read())')" True "partition back to original"

echo "bad block inside the logo area"; reset; echo 1 > "$T/dev/bad"
run new_logo.bin bk >/dev/null; check $? 1 "refused"
check "$(py 'import sys;t=sys.argv[1];print(open(t+"/dev/mtd1.img","rb").read()==open(t+"/orig_part.bin","rb").read())')" True "partition untouched"

echo "no logo partition"; reset; grep -v logo "$T/proc_mtd" > "$T/p2"; mv "$T/p2" "$T/proc_mtd"
run new_logo.bin bk >/dev/null; check $? 1 "refused"

echo
if [ $fails = 0 ]; then echo "all tests passed ($SH)"; else echo "$fails test(s) failed"; exit 1; fi
