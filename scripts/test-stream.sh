#!/bin/bash
# test-stream.sh — audio from the host machine, played in the guest as it arrives.
#
# This is where the two halves of the project meet. A WAV is served by a real
# HTTP server on this machine; the guest fetches it over TCP through the
# emulated NIC and feeds the samples to the converter WHILE the rest of the
# file is still on the wire. Nothing is downloaded first.
#
# The claim that makes it more than a download is what happens to the socket
# when the audio arrives faster than 48000 frames a second: aplay's write
# blocks on the hardware clock, so nothing is read, so the receive window
# closes, so the server stops sending. A DAC in a virtual machine ends up
# pacing a TCP connection — with no rate limiter anywhere and nothing
# negotiating it.
#
# WHAT IS CHECKED, and why it is the recording rather than the log. The audio
# has to come out at the right pitch, at the right amplitude, for the right
# length, and — the part that matters for streaming — WITHOUT GAPS.
#
# IT DOES NOT PASS YET, AND THE REASON IS NOT IN THE AUDIO PATH.
#
# Measured here: the guest receives at about 82 KiB/s. 48 kHz stereo needs 187,
# mono needs 94, so the converter waits on the network and the tone comes out
# stretched with silence in the holes. The pcap says why, and it is not
# bandwidth — three stalls of 1.2 to 1.8 seconds account for four fifths of the
# transfer, and a stall that long is a retransmission timeout. Packets are
# being lost.
#
# They are lost because netd blocks. tcp_notify drains a connection's receive
# buffer straight into the client's channel with a blocking write, so a client
# that stops reading — which is exactly what a player does while it is playing
# — stops the whole daemon. netd is then not draining the NIC either, the
# port's 16 KiB ring overflows, and the sender finds out by timing out.
#
# And because the TCP buffer is drained the moment anything lands in it, the
# advertised window never shrinks: every packet in the capture says 16384, so
# the server keeps sending at full speed into a receiver that has stopped. The
# backpressure exists — it is in the channel — but it is BELOW the layer that
# could tell the sender about it.
#
# The fix belongs in netd, not here: deliver only what the client's channel can
# take without blocking, and leave the rest in the TCP receive buffer where it
# will close the window and slow the sender down. That is what flow control is
# for. It would speed up every large transfer, not only audio — a wget writing
# to FAT32 hits the same wall.
#
# Until then this script is a measurement rather than a gate, which is why it
# is not in scripts/test-userspace.sh.

set -e
cd "$(cd "$(dirname "$0")/.." && pwd)"

FREQ=1000
SECS=3
PORT=17790
WAV=/tmp/causticos-stream.wav
LOG=/tmp/causticos-stream.log
SERVED=build/streamed.wav

[ -f build/causticos.iso ] || { echo "build/causticos.iso missing"; exit 1; }
[ -f userspace/build/aplay.cse ] || { echo "aplay not built"; exit 1; }

# MONO, and the reason is measured rather than assumed. This stack sustains
# about 100 KiB/s end to end; 48 kHz stereo is 187 KiB/s, so the converter
# would spend two periods in three waiting on the network and no amount of
# buffering fixes a source that is permanently slower than the sink. One
# channel is 94 KiB/s, which fits — and aplay widens it to stereo on the way
# in, so the device still plays exactly what it opened with.
python3 scripts/make-tone-wav.py "$SERVED" --freq "$FREQ" --seconds "$SECS" \
    --rate 48000 --channels 1 --amplitude 0.50

bash scripts/seed-disk.sh shell --no-build >/dev/null

# The server is on THIS machine. SLIRP presents the host as 10.0.2.2, which is
# the only address the guest can reach without a forward — and the point of the
# test is that the audio crosses a real socket, not a pipe.
python3 scripts/http-server.py "$PORT" 120 >/tmp/stream-server.log 2>&1 &
SRV=$!
sleep 0.4

MON=/tmp/causticos-stream-mon.$$
rm -f "$WAV"
QEMU_DISK=build/disk.img
QEMU_KVM=1
QEMU_HTTPD_PORT=18089
QEMU_WAV="$WAV"
QEMU_PCAP="${QEMU_PCAP:-}"
source scripts/qemu-args.sh

qemu-system-x86_64 "${QEMU_ARGS[@]}" \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio -display none > "$LOG" 2>&1 &
QPID=$!
mon() { printf '%s\n' "$1" | socat - "unix-connect:$MON" >/dev/null 2>&1 || true; }
cleanup() {
    kill -9 $QPID 2>/dev/null || true; wait $QPID 2>/dev/null || true
    kill $SRV 2>/dev/null || true; wait $SRV 2>/dev/null || true
    rm -f "$MON"
}
trap cleanup EXIT

for _ in $(seq 1 600); do
    tr -d '\000' < "$LOG" | grep -q "netd: dhcp bound" && break
    kill -0 $QPID 2>/dev/null || break
    sleep 0.1
done
tr -d '\000' < "$LOG" | grep -q "netd: dhcp bound" \
    || { echo "FAIL: the guest never got an address"; tr -d '\000' < "$LOG" | tail -10; exit 1; }

key_of() {
    case "$1" in
        [a-z0-9]) printf '%s' "$1" ;;
        ' ') printf 'spc' ;; '-') printf 'minus' ;;
        '/') printf 'slash' ;; '.') printf 'dot' ;;
        ':') printf 'shift-semicolon' ;;
        *) echo "no key name for '$1'" >&2; exit 1 ;;
    esac
}
type_line() {
    echo "typing: $1"
    local i K
    for (( i=0; i<${#1}; i++ )); do K=$(key_of "${1:$i:1}"); mon "sendkey $K"; done
    mon "sendkey ret"
}

type_line "aplay http://10.0.2.2:$PORT/streamed.wav"

DONE=0
for _ in $(seq 1 900); do
    # Match the OUTCOMES, not "any line beginning with aplay:". The pattern
    # was (streamed|.*), which matches everything — including the "streaming"
    # line printed at the START — so the wait ended the moment playback began.
    if tr -d '\000' < "$LOG" | grep -qE "^aplay: (streamed|played) |^aplay: [a-z].*(failed|cannot|not |no )"; then
        DONE=1; break
    fi
    kill -0 $QPID 2>/dev/null || break
    sleep 0.1
done
echo "guest said:"
tr -d '\000' < "$LOG" | grep "^aplay:" | sed 's/^/  /'
tr -d '\000' < "$LOG" | grep -q "^aplay: streamed" \
    || { echo "FAIL: the stream did not play (log: $LOG)"
         tr -d '\000' < "$LOG" | tail -12; exit 1; }

sleep 0.5
mon "quit"
for _ in $(seq 1 50); do kill -0 $QPID 2>/dev/null || break; sleep 0.1; done
kill -9 $QPID 2>/dev/null || true; wait $QPID 2>/dev/null || true

[ -f "$WAV" ] || { echo "FAIL: qemu wrote no wav"; exit 1; }

# The gap tolerance is the whole point. 30 ms is under three periods: a stall
# anywhere between the server's socket and the converter shows up here, and a
# guest that fetched the file first and played it afterwards would still have
# to have played it without holes.
python3 scripts/check-wav.py "$WAV" \
    --freq "$FREQ" --seconds "$SECS" --rate 48000 \
    --tolerance-hz 20 --min-amplitude 0.35 --max-gap-ms 30

echo "=== stream: PASS ==="
