#!/bin/bash
# run-test.sh — boot one userspace self-test headless and report its verdict.
#
#   scripts/run-test.sh u64t [timeout_s] [extra files...]
#
# Seeds a scratch FAT32 image with <prog>.cse as /init, boots it under KVM with
# no display, and prints the serial output. Exit status is 0 only if the program
# printed "<prog>: ALL PASS" and nothing exploded.
#
# Why /init rather than typing at the shell: a self-test that has to be driven
# by hand is a self-test that stops being run. This form is scriptable, is what
# a CI gate would call, and takes a couple of seconds.
#
# The program's own stdout IS the serial line when it runs as /init, so tests
# that mirror to both (the say() idiom) print every line twice here. That is the
# cost of a test that also works from the framebuffer shell; ignore the echo.
set -e
cd "$(cd "$(dirname "$0")/.." && pwd)"

PROG="${1:?usage: run-test.sh <prog> [timeout_s] [extra files...]}"
TOUT="${2:-30}"
shift 2 2>/dev/null || shift 1

CSE="userspace/build/$PROG.cse"
[ -f "$CSE" ] || { echo "$CSE missing — run userspace/build.sh first"; exit 1; }
[ -f build/causticos.iso ] || { echo "build/causticos.iso missing — NOBOOT=1 scripts/run.sh"; exit 1; }

IMG="build/test-$PROG.img"
qemu-img create -f raw "$IMG" 64M >/dev/null 2>&1
mkfs.fat -F 32 -n CAUSTICOS "$IMG" >/dev/null 2>&1
python3 scripts/fat32_add_file.py "$IMG" addfilebin init.cse "$CSE" >/dev/null
for extra in "$@"; do
    python3 scripts/fat32_add_file.py "$IMG" addfilebin "$(basename "$extra")" "$extra" >/dev/null
done

LOG=$(mktemp)
QEMU_DISK="$IMG"
QEMU_KVM=1
source scripts/qemu-args.sh
timeout "$TOUT" qemu-system-x86_64 "${QEMU_ARGS[@]}" \
    -serial stdio -display none > "$LOG" 2>&1 || true

# The kernel interleaves NUL bytes into serial output; strip them or grep
# silently misses every marker.
RAW=$(tr -d '\000' < "$LOG")
rm -f "$LOG"

echo "$RAW" | grep -E "^  (ok|FAIL) |^$PROG:|panic:|EXCEPTION|#GP|#PF" || true

if echo "$RAW" | grep -qE "panic:|EXCEPTION|#GP|#PF|kernel halted"; then
    echo "=== $PROG: KERNEL FAULT ==="
    echo "$RAW" | grep -E "panic:|EXCEPTION|#GP|#PF|kernel halted" | head -3
    exit 1
fi
if echo "$RAW" | grep -q "$PROG: ALL PASS"; then
    echo "=== $PROG: PASS ==="
    exit 0
fi
echo "=== $PROG: FAIL (no ALL PASS marker — timeout?) ==="
exit 1
