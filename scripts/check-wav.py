#!/usr/bin/env python3
"""check-wav.py — measure what the guest actually played.

QEMU's `wav` audio backend writes every sample the guest's DAC consumed into
a file. This reads that file and answers the only questions that matter about
an audio driver, none of which a register dump can answer:

  - Did samples come out at all, and how many? A driver that programs the
    engine correctly and never gets an interrupt produces a valid, empty file.
  - Are they at the right frequency? A wrong format or a wrong divisor is
    inaudible in a register read and obvious in a tone: 1 kHz played at
    twice the rate is 2 kHz.
  - Is the amplitude right, and is it on both channels? A channel swap, a
    stuck mute or an EAPD nobody set gives silence on one side.
  - Is the tone CONTINUOUS? Underruns are the failure this whole design is
    built around, and they show up as gaps of silence in the middle.

Usage:
    check-wav.py FILE --freq 1000 --seconds 2 [--rate 48000]
                      [--tolerance-hz 20] [--min-amplitude 0.2]
                      [--max-gap-ms 25]

Exit status 0 and a one-line summary if everything holds, non-zero and the
specific measurement that failed otherwise.

No numpy: the DFT here is a single Goertzel bin, which is a dozen lines and
removes a dependency from the test path.
"""

import argparse
import math
import struct
import sys


def die(msg):
    print(f"check-wav: FAIL {msg}")
    sys.exit(1)


def read_wav(path):
    """Return (rate, channels, bits, frames as list of per-channel lists)."""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 44 or data[0:4] != b"RIFF" or data[8:12] != b"WAVE":
        die(f"{path} is not a RIFF/WAVE file ({len(data)} bytes)")

    pos = 12
    fmt = None
    samples = None
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        (csz,) = struct.unpack("<I", data[pos + 4:pos + 8])
        body = data[pos + 8:pos + 8 + csz]
        if cid == b"fmt ":
            fmt = struct.unpack("<HHIIHH", body[:16])
        elif cid == b"data":
            # QEMU writes the header with a zero length and patches it on
            # clean exit. A killed qemu leaves it zero, and trusting it would
            # report "no audio" for a file full of audio — so when the field
            # says zero, take everything to the end.
            samples = body if csz else data[pos + 8:]
        pos += 8 + csz + (csz & 1)

    if fmt is None:
        die("no fmt chunk")
    if samples is None:
        die("no data chunk")
    tag, channels, rate, _byterate, _align, bits = fmt
    if tag != 1 or bits != 16:
        die(f"expected 16-bit PCM, got tag={tag} bits={bits}")

    n = len(samples) // (2 * channels)
    chans = [[0.0] * n for _ in range(channels)]
    for i in range(n):
        base = i * 2 * channels
        for c in range(channels):
            (v,) = struct.unpack("<h", samples[base + 2 * c:base + 2 * c + 2])
            chans[c][i] = v / 32768.0
    return rate, channels, bits, chans


def goertzel(x, rate, freq):
    """Magnitude of one DFT bin, normalised so a full-scale sine gives ~0.5."""
    n = len(x)
    if n == 0:
        return 0.0
    k = int(0.5 + n * freq / rate)
    w = 2.0 * math.pi * k / n
    coeff = 2.0 * math.cos(w)
    s1 = 0.0
    s2 = 0.0
    for v in x:
        s0 = v + coeff * s1 - s2
        s2 = s1
        s1 = s0
    power = s1 * s1 + s2 * s2 - coeff * s1 * s2
    return math.sqrt(max(power, 0.0)) / (n / 2.0)


def dominant_freq(x, rate):
    """Peak frequency by zero crossings of the DC-removed signal.

    Cheaper and more direct than a full spectrum for a single tone, and it
    fails loudly on noise (crossings become erratic) rather than quietly
    picking a bin.
    """
    if len(x) < 4:
        return 0.0
    mean = sum(x) / len(x)
    y = [v - mean for v in x]
    crossings = 0
    first = None
    last = None
    for i in range(1, len(y)):
        if y[i - 1] < 0.0 <= y[i]:
            crossings += 1
            if first is None:
                first = i
            last = i
    if crossings < 2 or first is None or last == first:
        return 0.0
    periods = crossings - 1
    span = (last - first) / rate
    return periods / span if span > 0 else 0.0


def longest_gap_ms(x, rate, floor_amp, window_ms=5.0):
    """Longest run of near-silence, in milliseconds.

    Measured in windows rather than per sample: a sine passes through zero
    every half period, and calling that silence would report a gap in a
    perfectly continuous tone.
    """
    win = max(1, int(rate * window_ms / 1000.0))
    worst = 0
    run = 0
    for start in range(0, len(x) - win + 1, win):
        peak = max(abs(v) for v in x[start:start + win])
        if peak < floor_amp:
            run += 1
            worst = max(worst, run)
        else:
            run = 0
    return worst * window_ms


def active_span(chans, floor_amp, rate, pad_ms=2.0):
    """First and last frame with signal, across all channels.

    QEMU's wav backend starts writing the moment the machine starts, so the
    file holds every second of silence between boot and the program playing
    anything, and a trailing tail after it stops. Measuring the FILE would
    therefore measure how long the guest took to reach a shell. What is being
    tested is the tone, so the tone is what gets cut out — and how much was
    trimmed is reported, because a long lead-in is information (it is the
    boot) and a long tail is a different kind of information (it is an engine
    that kept running after close).
    """
    n = len(chans[0])
    first = None
    last = None
    for i in range(n):
        if any(abs(c[i]) >= floor_amp for c in chans):
            if first is None:
                first = i
            last = i
    if first is None:
        return None, None
    pad = int(rate * pad_ms / 1000.0)
    return max(0, first - pad), min(n, last + 1 + pad)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--freq", type=float, required=True,
                    help="tone the guest was told to play, in Hz")
    ap.add_argument("--seconds", type=float, required=True,
                    help="how long it was told to play for")
    ap.add_argument("--rate", type=int, default=48000)
    ap.add_argument("--tolerance-hz", type=float, default=20.0)
    ap.add_argument("--min-amplitude", type=float, default=0.2)
    ap.add_argument("--max-gap-ms", type=float, default=25.0)
    ap.add_argument("--duration-tolerance", type=float, default=0.25,
                    help="fraction of --seconds the sample count may differ by")
    args = ap.parse_args()

    rate, channels, _bits, chans = read_wav(args.file)
    if rate != args.rate:
        die(f"file is {rate} Hz, expected {args.rate}")
    if channels < 1:
        die("no channels")

    total_frames = len(chans[0])
    if total_frames == 0:
        die("the file has no samples — the guest played nothing")

    # Cut the boot silence off the front and the tail off the back; what is
    # left is what the guest actually played.
    floor = args.min_amplitude * 0.25
    lo_i, hi_i = active_span(chans, floor, rate)
    if lo_i is None:
        die(f"the file is {total_frames / rate:.3f}s of silence — "
            f"nothing ever reached the converter")
    chans = [c[lo_i:hi_i] for c in chans]
    frames = len(chans[0])
    got_seconds = frames / rate
    lead_in = lo_i / rate
    tail = (total_frames - hi_i) / rate

    # Duration. This is what catches a stream that started and stopped early,
    # which is the shape an underrun storm or a lost interrupt takes.
    low = args.seconds * (1.0 - args.duration_tolerance)
    high = args.seconds * (1.0 + args.duration_tolerance)
    if not (low <= got_seconds <= high):
        die(f"{got_seconds:.3f}s of audio, expected {args.seconds:.3f}s "
            f"(+-{args.duration_tolerance * 100:.0f}%) "
            f"[lead-in {lead_in:.2f}s, tail {tail:.2f}s]")

    problems = []
    summary = []
    for c in range(channels):
        x = chans[c]
        peak = max(abs(v) for v in x)
        mag = goertzel(x, rate, args.freq)
        f = dominant_freq(x, rate)
        gap = longest_gap_ms(x, rate, args.min_amplitude * 0.25)
        summary.append(f"ch{c}: {f:.1f}Hz peak={peak:.2f} bin={mag:.3f} "
                       f"gap={gap:.0f}ms")
        if peak < args.min_amplitude:
            problems.append(f"ch{c} peak {peak:.3f} < {args.min_amplitude}")
        if abs(f - args.freq) > args.tolerance_hz:
            problems.append(f"ch{c} tone {f:.1f}Hz, expected {args.freq:.1f}Hz "
                            f"(+-{args.tolerance_hz})")
        # The energy at the expected bin must dominate the signal: a peak
        # amplitude with the energy somewhere else is noise, not a tone.
        if mag < 0.25 * peak:
            problems.append(f"ch{c} energy is not at {args.freq:.0f}Hz "
                            f"(bin {mag:.3f} vs peak {peak:.3f})")
        if gap > args.max_gap_ms:
            problems.append(f"ch{c} silent for {gap:.0f}ms in the middle "
                            f"(underrun?)")

    if problems:
        for p in problems:
            print(f"check-wav: FAIL {p}")
        print("check-wav: " + " | ".join(summary))
        sys.exit(1)

    print(f"check-wav: PASS {got_seconds:.3f}s {rate}Hz x{channels} — "
          + " | ".join(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
