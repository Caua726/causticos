#!/bin/bash
# test-record.sh — capture in the guest, then read the file back off the disk.
#
# The mirror of test-audio.sh, and it needs the opposite machine. That test
# runs with QEMU's `wav` backend, which RECORDS what the guest played and has
# no input side at all, so the card it backs is output-only. This one runs the
# ordinary machine — `none`, which is full duplex — and checks what the guest
# WROTE rather than what it played.
#
# WHAT THIS PROVES, SAID PLAINLY. The frame count, the rate, the channel count
# and the header are the guest's own work and are checked exactly. The CONTENT
# is whatever QEMU's input carries, and every backend that can be driven from a
# script carries digital silence — none of them has a source. So an all-zero
# recording here is a CORRECT recording of what was offered, and asserting
# "the samples are what the host sent" is not something this machine can do.
# What it CAN do, and what would catch a broken capture path, is assert that
# the right NUMBER of frames arrived, at the right rate, in a well-formed file.
# A driver that never fires an interrupt produces a short file; one with the
# wrong format produces the wrong count; one that writes past its ring corrupts
# the header. Run it against -audiodev pipewire with something playing and the
# same program records that instead.
#
#   scripts/test-record.sh
set -e
cd "$(cd "$(dirname "$0")/.." && pwd)"

source "$(dirname "$0")/portable.sh"

SECS=1
GOT=/tmp/causticos-recorded.wav

[ -f build/causticos.iso ] || { echo "build/causticos.iso missing"; exit 1; }
[ -f userspace/build/arecord.cse ] || { echo "arecord not built"; exit 1; }

# Its own image, so this test can run beside the others rather than
# fighting them for build/disk.img.
DISK=build/disk-record.img
"$PY" scripts/mkroot.py --profile shell --img "$DISK" -q

MON=/tmp/causticos-rec-mon.$$
LOG=/tmp/causticos-rec.log
QEMU_DISK="$DISK"
QEMU_KVM=1
QEMU_HTTPD_PORT="${QEMU_HTTPD_PORT:-18087}"
source scripts/qemu-args.sh

qemu-system-x86_64 "${QEMU_ARGS[@]}" \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio -display none > "$LOG" 2>&1 &
QPID=$!
mon() { printf '%s\n' "$1" | socat - "unix-connect:$MON" >/dev/null 2>&1 || true; }
cleanup() { kill -9 $QPID 2>/dev/null || true; wait $QPID 2>/dev/null || true; rm -f "$MON"; }
trap cleanup EXIT

for _ in $(seq 1 400); do
    tr -d '\000' < "$LOG" | grep -q "shell: ready" && break
    kill -0 $QPID 2>/dev/null || break
    sleep 0.1
done

key_of() {
    case "$1" in
        [a-z0-9]) printf '%s' "$1" ;;
        ' ') printf 'spc' ;; '-') printf 'minus' ;;
        '/') printf 'slash' ;; '.') printf 'dot' ;;
        *) echo "no key name for '$1'" >&2; exit 1 ;;
    esac
}
type_line() {
    echo "typing: $1"
    local i K
    for (( i=0; i<${#1}; i++ )); do K=$(key_of "${1:$i:1}"); mon "sendkey $K"; done
    mon "sendkey ret"
}

type_line "arecord -t $SECS /rec.wav"

DONE=0
for _ in $(seq 1 400); do
    if tr -d '\000' < "$LOG" | grep -q "^arecord: "; then DONE=1; break; fi
    kill -0 $QPID 2>/dev/null || break
    sleep 0.1
done
LINE=$(tr -d '\000' < "$LOG" | grep "^arecord: " | head -1 || true)
echo "guest said: ${LINE:-<nothing>}"
[ "$DONE" = 1 ] || { echo "FAIL: arecord never finished (log: $LOG)"; tail -20 "$LOG"; exit 1; }
echo "$LINE" | grep -q "captured" || { echo "FAIL: arecord refused to record"; exit 1; }

# Stop the machine before touching its disk: the guest may still have the file
# open and the image is being written under us otherwise.
mon "quit"
for _ in $(seq 1 50); do kill -0 $QPID 2>/dev/null || break; sleep 0.1; done
kill -9 $QPID 2>/dev/null || true; wait $QPID 2>/dev/null || true

"$PY" scripts/fat32.py "$DISK" get /rec.wav "$GOT"

"$PY" - "$GOT" "$SECS" <<'PY'
import struct, sys
path, secs = sys.argv[1], int(sys.argv[2])
d = open(path, 'rb').read()

def fail(m):
    print(f"FAIL: {m}")
    sys.exit(1)

if len(d) < 44:            fail(f"{len(d)} bytes — not even a header")
if d[0:4] != b'RIFF':      fail("no RIFF magic")
if d[8:12] != b'WAVE':     fail("not a WAVE file")
if d[12:16] != b'fmt ':    fail("no fmt chunk where one belongs")
tag, ch, rate, byterate, align, bits = struct.unpack_from('<HHIIHH', d, 20)
if tag != 1:               fail(f"format tag {tag}, expected 1 (PCM)")
if bits != 16:             fail(f"{bits} bits a sample, expected 16")
if ch != 2:                fail(f"{ch} channels, expected 2")
if rate != 48000:          fail(f"{rate} Hz, expected 48000")
if align != ch * 2:        fail(f"block align {align}, expected {ch*2}")
if byterate != rate*ch*2:  fail(f"byte rate {byterate}, expected {rate*ch*2}")
if d[36:40] != b'data':    fail("no data chunk")

declared = struct.unpack_from('<I', d, 40)[0]
actual = len(d) - 44
if declared != actual:
    fail(f"header claims {declared} bytes of audio, the file holds {actual}")
riff = struct.unpack_from('<I', d, 4)[0]
if riff != 36 + actual:
    fail(f"RIFF size {riff}, expected {36 + actual}")

frames = actual // (ch * 2)
want = rate * secs
if frames != want:
    fail(f"{frames} frames, expected exactly {want} ({secs}s at {rate} Hz)")

# The content is whatever the machine's input carried. Under `none` that is
# silence, and saying which of the two happened is more useful than asserting
# either: a recording full of samples proves the path end to end, and a silent
# one proves everything except the source.
nonzero = sum(1 for i in range(44, len(d), 2)
              if struct.unpack_from('<h', d, i)[0] != 0)
total = actual // 2
print(f"  ok   {frames} frames, {rate} Hz x{ch}, header consistent")
if nonzero:
    print(f"  ok   {nonzero}/{total} samples carry signal — a real source was recorded")
else:
    print(f"  ok   all {total} samples are silence — correct for a backend with no input")
PY

echo "=== record: PASS ==="
