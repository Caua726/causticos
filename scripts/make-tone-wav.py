#!/usr/bin/env python3
"""make-tone-wav.py — the known signal the audio path is measured against.

Generated rather than committed, for the same reason the test certificates
are: a binary fixture in the repository is a fact nobody can check by reading
the diff. Here the whole point is that the host knows EXACTLY what it asked
the guest to play, so it can measure what came back.

    make-tone-wav.py OUT.wav [--freq 1000] [--seconds 2] [--rate 48000]
                             [--channels 2] [--amplitude 0.6]

The tone is faded in and out over a few milliseconds. Not cosmetics: a sine
that starts at full amplitude has a step discontinuity at sample zero, which
is a click with energy across the whole spectrum — and a click at the start
looks exactly like the artefact an underrun leaves, so the fade keeps the
measurement about the driver rather than about the fixture.
"""

import argparse
import math
import struct
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--freq", type=float, default=1000.0)
    ap.add_argument("--seconds", type=float, default=2.0)
    ap.add_argument("--rate", type=int, default=48000)
    ap.add_argument("--channels", type=int, default=2)
    ap.add_argument("--amplitude", type=float, default=0.6)
    ap.add_argument("--fade-ms", type=float, default=5.0)
    args = ap.parse_args()

    n = int(args.rate * args.seconds)
    fade = max(1, int(args.rate * args.fade_ms / 1000.0))
    body = bytearray()
    for i in range(n):
        v = args.amplitude * math.sin(2.0 * math.pi * args.freq * i / args.rate)
        if i < fade:
            v *= i / fade
        elif i >= n - fade:
            v *= (n - 1 - i) / fade
        s = int(max(-1.0, min(1.0, v)) * 32767)
        for _ in range(args.channels):
            body += struct.pack("<h", s)

    hdr = (b"RIFF" + struct.pack("<I", 36 + len(body)) + b"WAVEfmt "
           + struct.pack("<IHHIIHH", 16, 1, args.channels, args.rate,
                         args.rate * args.channels * 2, args.channels * 2, 16)
           + b"data" + struct.pack("<I", len(body)))
    with open(args.out, "wb") as f:
        f.write(hdr + bytes(body))
    print(f"make-tone-wav: {args.out} {args.freq:.0f}Hz {args.seconds}s "
          f"{args.rate}Hz x{args.channels} ({len(body) + 44} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
