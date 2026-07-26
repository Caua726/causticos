#!/bin/bash
# test-soundd.sh — two programs audible at once, and one taking the device away.
#
# This is the milestone the whole audio design was shaped around, and it is two
# claims that can only be checked from outside the guest:
#
#   MIXING     Two clients play DIFFERENT tones — 1 kHz and 1.5 kHz — and both
#              must be present in the recording at their own amplitude.
#
#              Different, because the first version of this test used the same
#              tone twice and measured the amplitude of the sum. Two coherent
#              sines do not add by amplitude, they add by PHASE: 0.3 + 0.3 is
#              anywhere from 0 to 0.6 depending on how far apart the two
#              clients happened to start, and the run that exposed this
#              measured exactly 0.3 — the reading for one voice — while soundd
#              was demonstrably mixing two. Separate frequencies cannot
#              interfere, so each bin answers for its own client and the
#              question has one answer.
#
#   PREEMPTION Then aplay takes the device directly, playing 400 Hz. soundd is
#              not stopped, not told, and not asked: the grab stack puts aplay
#              on top, soundd's ring stops being played and its cursor freezes.
#              When aplay exits the stream comes back and soundd resumes.
#              The recording must therefore read 1 kHz, then 400 Hz, then
#              1 kHz — and the middle section must have NO 1 kHz in it, which
#              is the part that proves the muted holder really was muted
#              rather than merely quieter.
#
# The analysis is per-segment rather than whole-file, so check-wav.py is not
# the right tool here: it answers "is this one tone", and the point is that it
# is three.
set -e
cd "$(cd "$(dirname "$0")/.." && pwd)"

source "$(dirname "$0")/portable.sh"

WAV=/tmp/causticos-soundd.wav
LOG=/tmp/causticos-soundd.log
MIXHZ=1000
MIXHZ2=1500
PREEMPTHZ=400
SECS=2

[ -f build/causticos.iso ] || { echo "build/causticos.iso missing"; exit 1; }
[ -f userspace/build/soundd.cse ] || { echo "soundd not built"; exit 1; }

"$PY" scripts/make-tone-wav.py build/mix.wav --freq "$MIXHZ" --seconds "$SECS" \
    --rate 48000 --channels 2 --amplitude 0.30
"$PY" scripts/make-tone-wav.py build/mix2.wav --freq "$MIXHZ2" --seconds "$SECS" \
    --rate 48000 --channels 2 --amplitude 0.30
"$PY" scripts/make-tone-wav.py build/low.wav --freq "$PREEMPTHZ" --seconds 1 \
    --rate 48000 --channels 2 --amplitude 0.60

# Its own image, so this test can run beside the others rather than
# fighting them for build/disk.img.
DISK=build/disk-soundd.img
"$PY" scripts/mkroot.py --profile shell --img "$DISK" -q \
    --add build/mix.wav --add build/mix2.wav --add build/low.wav

MON=/tmp/causticos-soundd-mon.$$
rm -f "$WAV"
QEMU_DISK="$DISK"
QEMU_KVM=1
QEMU_HTTPD_PORT="${QEMU_HTTPD_PORT:-18088}"
QEMU_WAV="$WAV"
source scripts/qemu-args.sh

qemu-system-x86_64 "${QEMU_ARGS[@]}" \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio -display none > "$LOG" 2>&1 &
QPID=$!
mon() { printf '%s\n' "$1" | socat - "unix-connect:$MON" >/dev/null 2>&1 || true; }
cleanup() { kill -9 $QPID 2>/dev/null || true; wait $QPID 2>/dev/null || true; rm -f "$MON"; }
trap cleanup EXIT

# Wait for the SERVICES, not for the prompt. "shell: ready" is printed before
# netd and soundd are started, so waiting on it and then asking whether soundd
# is up asks the question a second too early — and gets "no" every time.
for _ in $(seq 1 600); do
    tr -d '\000' < "$LOG" | grep -qE "shell: (soundd up|no soundd)" && break
    kill -0 $QPID 2>/dev/null || break
    sleep 0.1
done
tr -d '\000' < "$LOG" | grep -q "shell: soundd up" \
    || { echo "FAIL: the shell did not bring soundd up"
         tr -d '\000' < "$LOG" | grep -E "soundd|shell:" | tail -15; exit 1; }

key_of() {
    case "$1" in
        [a-z0-9]) printf '%s' "$1" ;;
        ' ') printf 'spc' ;; '-') printf 'minus' ;;
        '/') printf 'slash' ;; '.') printf 'dot' ;;
        '&') printf 'shift-7' ;;
        *) echo "no key name for '$1'" >&2; exit 1 ;;
    esac
}
type_line() {
    echo "typing: $1"
    local i K
    for (( i=0; i<${#1}; i++ )); do K=$(key_of "${1:$i:1}"); mon "sendkey $K"; done
    mon "sendkey ret"
}

# Two voices at once, both in the background so the shell stays usable.
type_line "aplay -m /mix.wav &"
sleep 0.3
type_line "aplay -m /mix2.wav &"

# Let the mix establish itself, then take the device away from underneath it.
sleep 0.8
type_line "aplay /low.wav"

# And wait for the whole thing to finish.
for _ in $(seq 1 300); do
    N=$(tr -d '\000' < "$LOG" | grep -c "^aplay: played" || true)
    [ "$N" -ge 3 ] && break
    kill -0 $QPID 2>/dev/null || break
    sleep 0.1
done
echo "guest said:"
tr -d '\000' < "$LOG" | grep "^aplay:" | sed 's/^/  /'

sleep 0.5
mon "quit"
for _ in $(seq 1 50); do kill -0 $QPID 2>/dev/null || break; sleep 0.1; done
kill -9 $QPID 2>/dev/null || true; wait $QPID 2>/dev/null || true

[ -f "$WAV" ] || { echo "FAIL: qemu wrote no wav"; exit 1; }

"$PY" - "$WAV" "$MIXHZ" "$MIXHZ2" "$PREEMPTHZ" <<'PY'
import math, struct, sys
path = sys.argv[1]
mixhz, mixhz2, lowhz = (float(a) for a in sys.argv[2:5])
d = open(path, 'rb').read()
rate = struct.unpack_from('<I', d, 24)[0]
ch = struct.unpack_from('<H', d, 22)[0]
body = d[44:]
n = len(body) // (2 * ch)
x = [struct.unpack_from('<h', body, i * 2 * ch)[0] / 32768.0 for i in range(n)]

def goertzel(seg, freq):
    N = len(seg)
    if N < 8:
        return 0.0
    k = int(0.5 + N * freq / rate)
    w = 2.0 * math.pi * k / N
    coeff = 2.0 * math.cos(w)
    s1 = s2 = 0.0
    for v in seg:
        s0 = v + coeff * s1 - s2
        s2, s1 = s1, s0
    p = s1 * s1 + s2 * s2 - coeff * s1 * s2
    return math.sqrt(max(p, 0.0)) / (N / 2.0)

# Cut the leading and trailing silence: QEMU records from the moment the
# machine starts, so most of the file is the guest booting.
floor = 0.02
first = next((i for i, v in enumerate(x) if abs(v) >= floor), None)
last = next((i for i in range(len(x) - 1, -1, -1) if abs(x[i]) >= floor), None)
if first is None:
    print("FAIL: the recording is silence — nothing ever played")
    sys.exit(1)
x = x[first:last + 1]
print(f"  audio spans {len(x)/rate:.2f}s of a {n/rate:.2f}s recording")

# Find the preempting tone: the window where lowhz dominates.
win = int(rate * 0.05)
best_i, best_v = 0, 0.0
for i in range(0, len(x) - win, win):
    v = goertzel(x[i:i + win], lowhz)
    if v > best_v:
        best_v, best_i = v, i
if best_v < 0.15:
    print(f"FAIL: never heard the {lowhz:.0f}Hz tone that took the device "
          f"(strongest bin {best_v:.3f})")
    sys.exit(1)

# Widen to the whole run of it.
lo = best_i
while lo - win >= 0 and goertzel(x[lo - win:lo], lowhz) > 0.15:
    lo -= win
hi = best_i + win
while hi + win < len(x) and goertzel(x[hi:hi + win], lowhz) > 0.15:
    hi += win

before, during, after = x[:lo], x[lo:hi], x[hi:]
print(f"  before {len(before)/rate:.2f}s | preempting {len(during)/rate:.2f}s "
      f"| after {len(after)/rate:.2f}s")

fails = []
WIN = int(rate * 0.2)

def best(seg, freq):
    """The strongest 0.2s window of `freq` in `seg`.

    A window rather than the segment average, because the segments are not
    uniform and should not be: the second client starts a moment after the
    first, and the last one to finish plays on alone. Averaging across those
    edges dilutes a perfectly steady tone into a number that looks like a
    starving one — which it did, and cost an afternoon of chasing a mixer bug
    that was not there. The question is "was this client ever properly
    audible", and a window answers exactly that."""
    if len(seg) < WIN:
        return 0.0
    return max(goertzel(seg[i:i + WIN], freq)
               for i in range(0, len(seg) - WIN, WIN // 2))

def worst_case(seg, freq):
    """The strongest window again — used where the claim is that a tone is
    ABSENT, so the strongest is the one that has to be small."""
    return best(seg, freq)

b1, b2 = best(before, mixhz), best(before, mixhz2)
if b1 < 0.22 or b2 < 0.22:
    fails.append(f"the two clients were never both audible: {b1:.3f} at "
                 f"{mixhz:.0f}Hz, {b2:.3f} at {mixhz2:.0f}Hz "
                 f"(each plays a 0.30 tone)")
else:
    print(f"  ok   both clients audible at once: {b1:.3f} at {mixhz:.0f}Hz "
          f"and {b2:.3f} at {mixhz2:.0f}Hz")

d_low = best(during, lowhz)
if d_low < 0.25:
    fails.append(f"never heard the tone that took the device: {d_low:.3f}")
else:
    print(f"  ok   aplay took the device: {d_low:.3f} at {lowhz:.0f}Hz")

# THE POINT. A displaced holder is muted, not merely quieter: if any of
# soundd's samples were still reaching the converter, the strongest window of
# either voice would show it.
d1, d2 = worst_case(during, mixhz), worst_case(during, mixhz2)
if d1 > 0.08 or d2 > 0.08:
    fails.append(f"soundd was still audible while displaced: {d1:.3f} / {d2:.3f}")
else:
    print(f"  ok   soundd went silent while displaced: {d1:.3f} / {d2:.3f}")

a1, a2 = best(after, mixhz), best(after, mixhz2)
if a1 < 0.22 or a2 < 0.22:
    fails.append(f"soundd did not resume with both voices: {a1:.3f} / {a2:.3f}")
else:
    print(f"  ok   and resumed with both voices: {a1:.3f} / {a2:.3f}")

if fails:
    for f in fails:
        print(f"FAIL: {f}")
    sys.exit(1)
PY

echo "=== soundd: PASS ==="
