#!/bin/bash
# test-record.sh — capture in the guest, then read the file back off the disk.
#
# The mirror of test-audio.sh, and it needs the opposite machine. That test
# runs with QEMU's `wav` backend, which RECORDS what the guest played and has
# no input side at all, so the card it backs is output-only. This one gives the
# card an input that carries known samples and checks what the guest WROTE.
#
# The source is a file: SDL's `disk` audio driver (QEMU_SND_SOURCE in
# qemu-args.sh) hands the capture stream the bytes of a raw PCM file in order,
# paced by the wall clock as a sound card is by its own. The file is a 440 Hz
# sine on the left and a 1000 Hz one on the right, so a recording that is the
# same tone twice, swapped, half-rate or silent cannot pass. Checked:
#
#   - the header, the rate, the channel count, and exactly SECS seconds of
#     frames — the guest's own work;
#   - every sample: past any silence QEMU puts ahead of the source starting,
#     the recording is a contiguous run of the source file, byte for byte. A
#     dropped period, a duplicated one, a byte-swap or a channel swap breaks
#     the run.
#
#   scripts/test-record.sh
set -e
cd "$(cd "$(dirname "$0")/.." && pwd)"

source "$(dirname "$0")/portable.sh"

SECS=1
GOT=/tmp/causticos-recorded.wav
W=$(mktemp -d /tmp/causticos-rec.XXXXXX)
SRC=$W/source.raw

# The source: ten seconds, more than the guest will ask for, so it never runs
# dry. Generated here rather than kept in the tree: it is a formula.
"$PY" - "$SRC" <<'PY'
import math, struct, sys
rate, secs, amp = 48000, 10, 12000
out = bytearray()
for i in range(rate * secs):
    l = int(round(amp * math.sin(2 * math.pi * 440 * i / rate)))
    r = int(round(amp * math.sin(2 * math.pi * 1000 * i / rate)))
    out += struct.pack('<hh', l, r)
open(sys.argv[1], 'wb').write(out)
PY
QEMU_SND_SOURCE="$SRC"

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
# The live root inside the ISO outranks an attached disk (prio 100 vs 10), so a
# seeded disk alone is never mounted — the kernel boots the ISO's own desktop
# root and every check here looks at the wrong system. root= on the command line
# is what says "mount THIS one", and it is why the disk is still a disk: the
# host reads results back out of it after the boot, which a volatile RAM root
# cannot offer.
# ROOTED_ISO lets a caller hand us one that is already built. mkiso stages
# through a single build/iso directory, so eight of these running at once —
# which is how test-userspace.sh drives them — would tread on each other.
if [ -n "${ROOTED_ISO:-}" ]; then
    QEMU_ISO="$ROOTED_ISO"
else
    QEMU_ISO=build/test-record.iso
    bash scripts/mkiso.sh --cmdline "root=ahci-p0" --out "$QEMU_ISO" >/dev/null
fi
source scripts/qemu-args.sh

qemu-system-x86_64 "${QEMU_ARGS[@]}" \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio -display none > "$LOG" 2>&1 &
QPID=$!
mon() { printf '%s\n' "$1" | socat - "unix-connect:$MON" >/dev/null 2>&1 || true; }
cleanup() {
    kill -9 $QPID 2>/dev/null || true; wait $QPID 2>/dev/null || true
    rm -f "$MON"; rm -rf "$W"
}
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

"$PY" - "$GOT" "$SECS" "$SRC" <<'PY'
import struct, sys
path, secs, src = sys.argv[1], int(sys.argv[2]), sys.argv[3]
d = open(path, 'rb').read()
source = open(src, 'rb').read()

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
print(f"  ok   {frames} frames, {rate} Hz x{ch}, header consistent")

# The samples. QEMU may hand the stream silence before the source is open;
# past that, every byte must be the source's, in order, from wherever in the
# file the capture began.
audio = d[44:]
lead = 0
while lead < len(audio) and audio[lead:lead + 4] == b'\0\0\0\0':
    lead += 4
if lead == len(audio):
    fail("the recording is all silence — the source never reached the guest")
body = audio[lead:]
probe = body[:256]
start = -1
at = source.find(probe)
while at >= 0:
    if at % 4 == 0:
        start = at
        break
    at = source.find(probe, at + 1)
if start < 0:
    fail("the first recorded frames are nowhere in the source (scaled, swapped or resampled?)")
ref = source[start:start + len(body)]
if len(ref) < len(body):
    fail(f"the recording runs past the end of the {len(source)//4}-frame source")
if body != ref:
    i = next(k for k in range(len(body)) if body[k] != ref[k])
    fr = i // 4
    fail(f"frame {lead//4 + fr} differs from the source (frame {start//4 + fr} of it): "
         f"got {struct.unpack_from('<hh', body, fr*4)}, want {struct.unpack_from('<hh', ref, fr*4)}")
print(f"  ok   {len(body)//4} frames are the source, byte for byte, from its frame {start//4}"
      f"{f' after {lead//4} frames of silence' if lead else ''}")
PY

echo "=== record: PASS ==="
