#!/usr/bin/env python3
"""gen-tzt.py — the instants userspace/tests/tzt.cst converts, with answers.

The answers come from CPython's zoneinfo reading the same compiled files the
image ships (userspace/lib/tz/zoneinfo): an independent implementation of
RFC 8536 and of POSIX TZ rules, so lib/tz is checked against something that is
not itself. The result is written to userspace/tests/tzt.cases and committed,
next to the database it was generated from; run this again after
scripts/update-tzdata.sh.

    python3 scripts/gen-tzt.py

One case a line:
    ZONE EPOCH YEAR MONTH DAY HOUR MIN SEC WDAY YDAY UTOFF ISDST ABBR
WDAY 0 is Sunday; UTOFF is seconds east of UTC.

Which instants:
  - every zone name, in January and July of 2026: each file loads, and both
    hemispheres' current rules are exercised;
  - every distinct file, at instants from 1900 to 2100: before the first
    transition, the table, the 2038 boundary, and the footer rule far ahead;
  - a set of zones whose rules use every feature the format has — negative
    daylight saving, switches at 24:00 and later or before midnight, half- and
    quarter-hour offsets, two-hour shifts, southern summers spanning the new
    year — at each transition from 1970 to 2045, one second either side.
"""
import datetime
import hashlib
import os
import sys
import zoneinfo

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ZDIR = os.path.join(ROOT, "userspace", "lib", "tz", "zoneinfo")
OUT = os.path.join(ROOT, "userspace", "tests", "tzt.cases")

FEATURED = [
    "UTC", "Factory", "Etc/GMT+3", "Etc/GMT-14",
    "America/Sao_Paulo", "America/New_York", "America/Nuuk", "America/Santiago",
    "America/Asuncion", "America/St_Johns",
    "Europe/London", "Europe/Dublin", "Europe/Lisbon",
    "Africa/Cairo", "Africa/Casablanca", "Asia/Jerusalem", "Asia/Gaza",
    "Asia/Kathmandu", "Asia/Kolkata", "Asia/Tehran",
    "Australia/Sydney", "Australia/Lord_Howe", "Pacific/Chatham",
    "Pacific/Apia", "Antarctica/Troll",
]


def utc(*a):
    return int(datetime.datetime(*a, tzinfo=datetime.timezone.utc).timestamp())


def state(z, t):
    dt = datetime.datetime.fromtimestamp(t, z)
    return int(dt.utcoffset().total_seconds()), dt.tzname()


def row(name, z, t):
    dt = datetime.datetime.fromtimestamp(t, z)
    off = int(dt.utcoffset().total_seconds())
    dst = dt.dst()
    isdst = 1 if dst is not None and dst != datetime.timedelta(0) else 0
    wday = (dt.weekday() + 1) % 7
    yday = dt.timetuple().tm_yday
    return "%s %d %d %d %d %d %d %d %d %d %d %d %s" % (
        name, t, dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second,
        wday, yday, off, isdst, dt.tzname())


def transitions(z, lo, hi):
    """Every instant in [lo, hi) at which the offset or abbreviation changes."""
    out = []
    step = 6 * 3600
    t = lo
    prev = state(z, t)
    while t < hi:
        nxt = min(t + step, hi)
        cur = state(z, nxt)
        if cur != prev:
            a, b = t, nxt              # state(a) == prev, state(b) != prev
            while b - a > 1:
                m = (a + b) // 2
                if state(z, m) == prev:
                    a = m
                else:
                    b = m
            out.append(b)
            prev = state(z, b)
            t = b
            continue
        t = nxt
        prev = cur
    return out


def main():
    names = []
    for dp, _dn, fn in os.walk(ZDIR):
        for f in fn:
            if f.startswith("+"):
                continue
            names.append(os.path.relpath(os.path.join(dp, f), ZDIR))
    names.sort()
    zones = {}
    for n in names:
        with open(os.path.join(ZDIR, n), "rb") as f:
            zones[n] = zoneinfo.ZoneInfo.from_file(f, key=n)

    rows = []
    for n in names:
        for t in (utc(2026, 1, 15, 12), utc(2026, 7, 15, 12)):
            rows.append(row(n, zones[n], t))

    seen = set()
    for n in names:
        digest = hashlib.sha256(open(os.path.join(ZDIR, n), "rb").read()).digest()
        if digest in seen:
            continue
        seen.add(digest)
        for t in (utc(1900, 6, 1), utc(1970, 1, 1), utc(1999, 12, 31, 23, 59, 59),
                  utc(2038, 1, 19, 3, 14, 8), utc(2100, 3, 1), utc(2100, 7, 1)):
            rows.append(row(n, zones[n], t))

    for n in FEATURED:
        if n not in zones:
            sys.exit("gen-tzt: %s is not in the database" % n)
        for t in transitions(zones[n], utc(1970, 1, 1), utc(2045, 1, 1)):
            rows.append(row(n, zones[n], t - 1))
            rows.append(row(n, zones[n], t))

    # The count last: a file cut short is then a failure, not fewer passes.
    with open(OUT, "w") as f:
        for r in rows:
            f.write(r + "\n")
        f.write("END %d\n" % len(rows))
    print("gen-tzt: %d cases, %d zones, %d distinct files -> %s"
          % (len(rows), len(names), len(seen), OUT))


if __name__ == "__main__":
    main()
