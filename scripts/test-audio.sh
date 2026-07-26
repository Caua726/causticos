#!/bin/bash
# test-audio.sh — play a tone in the guest and MEASURE what came out.
#
# Every other test in this tree can check its own answer: a checksum matches,
# a certificate verifies, a frame arrives. Audio cannot. A driver that
# programs the wrong sample rate, points the engine at the wrong page, or
# never gets a period interrupt reads back perfectly from every register and
# produces silence, noise, or a tone at twice the pitch — and nothing inside
# the guest can tell the difference, because from in there the samples left
# correctly.
#
# So the check is on the outside. QEMU's `wav` audio backend writes every
# sample the guest's converter consumed into a file on the host, and
# scripts/check-wav.py measures its frequency, its amplitude, its duration and
# whether it has gaps. The guest plays a tone the host generated, so the host
# knows exactly what the answer should be.
#
# That is the whole reason this is worth the trouble: without it, "audio
# works" would mean "it did not crash".
#
#   scripts/test-audio.sh
set -e
cd "$(cd "$(dirname "$0")/.." && pwd)"

FREQ=1000
SECONDS_OF_TONE=2
WAV=/tmp/causticos-audio.wav
TONE=build/tone.wav

[ -f build/causticos.iso ] || { echo "build/causticos.iso missing"; exit 1; }
[ -f userspace/build/aplay.cse ] || { echo "aplay not built"; exit 1; }

python3 scripts/make-tone-wav.py "$TONE" --freq "$FREQ" \
    --seconds "$SECONDS_OF_TONE" --rate 48000 --channels 2

# Its own image, so this test can run beside the others rather than
# fighting them for build/disk.img.
DISK=build/disk-audio.img
SEED_DISK="$DISK" bash scripts/seed-disk.sh shell --no-build >/dev/null
python3 scripts/fat32_add_file.py "$DISK" addfilebin tone.wav "$TONE" >/dev/null

MON=/tmp/causticos-audio-mon.$$
LOG=/tmp/causticos-audio.log
rm -f "$WAV"
QEMU_DISK="$DISK"
QEMU_KVM=1
QEMU_HTTPD_PORT="${QEMU_HTTPD_PORT:-18085}"
QEMU_WAV="$WAV"
source scripts/qemu-args.sh

qemu-system-x86_64 "${QEMU_ARGS[@]}" \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio -display none > "$LOG" 2>&1 &
QPID=$!

mon() { printf '%s\n' "$1" | socat - "unix-connect:$MON" >/dev/null 2>&1 || true; }
cleanup() {
    kill -9 $QPID 2>/dev/null || true; wait $QPID 2>/dev/null || true
    rm -f "$MON"
}
trap cleanup EXIT

for _ in $(seq 1 400); do
    tr -d '\000' < "$LOG" | grep -q "shell: ready" && break
    tr -d '\000' < "$LOG" | grep -q "shell: netd up" && break
    kill -0 $QPID 2>/dev/null || break
    sleep 0.1
done

key_of() {
    case "$1" in
        [a-z0-9]) printf '%s' "$1" ;;
        ' ') printf 'spc' ;;
        '-') printf 'minus' ;;
        '/') printf 'slash' ;;
        '.') printf 'dot' ;;
        *)  echo "no key name for '$1'" >&2; exit 1 ;;
    esac
}

type_line() {
    echo "typing: $1"
    local i K
    for (( i=0; i<${#1}; i++ )); do
        K=$(key_of "${1:$i:1}")
        mon "sendkey $K"
    done
    mon "sendkey ret"
}

# Typed at the real prompt, like a person would. That also covers the shell
# handing a fresh device fd to a child, which no in-guest self-test reaches.
type_line "aplay /tone.wav"

DONE=0
for _ in $(seq 1 400); do
    # The outcomes, not any line at all: (played|.*) matches everything.
    if tr -d '\000' < "$LOG" | grep -qE "^aplay: played |^aplay: [a-z].*(failed|cannot|not |no )"; then
        DONE=1; break
    fi
    kill -0 $QPID 2>/dev/null || break
    sleep 0.1
done

APLAY_LINE=$(tr -d '\000' < "$LOG" | grep -E "^aplay:" | head -2 || true)
echo "guest said: ${APLAY_LINE:-<nothing>}"
if [ "$DONE" != 1 ]; then
    echo "FAIL: aplay never reported finishing (log: $LOG)"
    tr -d '\000' < "$LOG" | tail -25
    exit 1
fi
if ! echo "$APLAY_LINE" | grep -q "played"; then
    echo "FAIL: aplay refused to play the file"
    exit 1
fi

# Quit through the monitor rather than killing qemu: the wav backend patches
# the RIFF length field on a clean exit, and while check-wav.py copes with a
# zero there, a file written properly is one less thing to explain.
mon "quit"
for _ in $(seq 1 50); do
    kill -0 $QPID 2>/dev/null || break
    sleep 0.1
done
kill -9 $QPID 2>/dev/null || true
wait $QPID 2>/dev/null || true

[ -f "$WAV" ] || { echo "FAIL: qemu wrote no wav file"; exit 1; }
echo "recorded: $(stat -c%s "$WAV") bytes"

# The tolerance on frequency is tight — 20 Hz on 1000 — because every way this
# can go wrong moves the pitch by a factor, not by a percent.
python3 scripts/check-wav.py "$WAV" \
    --freq "$FREQ" --seconds "$SECONDS_OF_TONE" --rate 48000 \
    --tolerance-hz 20 --min-amplitude 0.2 --max-gap-ms 30

echo "=== audio: PASS ==="
