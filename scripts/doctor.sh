#!/usr/bin/env bash
source "$(dirname "$0")/portable.sh"
# doctor.sh — check everything a build needs, and say how to fix what is missing.
#
# One line per check, and every failure carries its own remedy. The point is that
# a fresh clone tells you what it wants instead of failing three steps later with
# a message about something else.
#
# Note what is NOT checked: mkfs.fat and qemu-img. scripts/fat32.py formats the
# volume itself, so neither is a dependency any more.
set -uo pipefail

cd "$(dirname "$0")/.."

FAIL=0
ok()   { printf '  \033[32mok\033[0m    %-22s %s\n' "$1" "${2:-}"; }
warn() { printf '  \033[33mwarn\033[0m  %-22s %s\n' "$1" "$2"; }
bad()  { printf '  \033[31mFAIL\033[0m  %-22s %s\n' "$1" "$2"; FAIL=1; }

need_tool() {   # need_tool <name> <fix>
    local p; p="$(command -v "$1" 2>/dev/null)"
    if [ -n "$p" ]; then ok "$1" "$p"; else bad "$1" "$2"; fi
}

echo "toolchain"
need_tool caustic    "install the Caustic toolchain, or add ~/.local/bin to PATH"
need_tool caustic-as "install the Caustic toolchain, or add ~/.local/bin to PATH"
need_tool caustic-ld "install the Caustic toolchain, or add ~/.local/bin to PATH"
need_tool caustic-mk "build it: (cd ../Caustic && ./caustic-mk build caustic-mk) and copy it onto PATH"

CAUSTIC_DIR="${CAUSTIC_DIR:-$(cd .. 2>/dev/null && pwd)/Caustic}"
if [ -x "$CAUSTIC_DIR/caustic" ]; then
    ok "\$CAUSTIC_DIR" "$CAUSTIC_DIR"
else
    bad "\$CAUSTIC_DIR" "set CAUSTIC_DIR=/path/to/Caustic — userspace links against its std/"
fi

echo "bootloader"
LIMINE_DIR="${LIMINE_DIR:-/usr/share/limine}"
MISSING=""
for f in limine-bios.sys limine-bios-cd.bin limine-uefi-cd.bin BOOTX64.EFI; do
    [ -f "$LIMINE_DIR/$f" ] || MISSING="$MISSING $f"
done
if [ -z "$MISSING" ]; then
    ok "\$LIMINE_DIR" "$LIMINE_DIR"
else
    bad "\$LIMINE_DIR" "missing in $LIMINE_DIR:$MISSING — pacman -S limine, or set LIMINE_DIR"
fi
need_tool limine  "pacman -S limine"
need_tool xorriso "pacman -S libisoburn"

echo "runtime"
need_tool qemu-system-x86_64 "pacman -S qemu-system-x86"
# A QEMU with no display backend still runs — headless — and then fails to open
# a window with a message about SDL that does not mention the missing package.
# On Arch the GUI is qemu-ui-gtk, a package of its own; installing
# qemu-system-x86 alone is enough to boot and not enough to watch.
if qemu-system-x86_64 -display help 2>/dev/null | grep -qE '^\s*(gtk|sdl)$'; then
    ok "qemu display" "$(qemu-system-x86_64 -display help 2>/dev/null | grep -oE '^\s*(gtk|sdl)$' | tr -d ' ' | tr '\n' ' ')"
else
    warn "qemu display" "no gtk/sdl backend — 'run' works only with --headless. Arch: pacman -S qemu-ui-gtk"
fi

# Something has to be able to show that window.
if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    WHICH=""
    [ -n "${WAYLAND_DISPLAY:-}" ] && WHICH="wayland ($WAYLAND_DISPLAY)"
    [ -n "${DISPLAY:-}" ] && WHICH="${WHICH:+$WHICH, }X11 ($DISPLAY)"
    ok "display server" "$WHICH"
else
    warn "display server" "no DISPLAY or WAYLAND_DISPLAY — over SSH or bare WSL, use --headless"
fi

ACCEL="$(qemu_accel)"
if [ "$ACCEL" != tcg ]; then
    ok "acceleration" "$ACCEL"
else
    # Not worth alarm. This system reaches a ready desktop in 3.4s under pure
    # emulation against 2.8s accelerated — measured, not estimated. It is small
    # enough that the difference barely shows.
    warn "acceleration" "none — using TCG (measured 3.4s to desktop vs 2.8s)"
fi

PYV="$("$PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)"
if [ -n "$PYV" ]; then
    if "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3,8) else 1)'; then
        ok "$PY" "$PYV"
    else
        bad "$PY" "$PYV is too old — 3.8 or newer"
    fi
else
    bad "$PY" "install python 3.8 or newer"
fi

echo "manifest"
# Every `src` a target names has to exist, or the failure surfaces mid-build as
# a compiler error about a file nobody mentioned.
MISSING_SRC="$("$PY" - <<'PY'
import os, re, sys
bad = []
name = None
with open("userspace/Causticfile") as fh:
    for line in fh:
        line = line.split("//")[0].strip()
        m = re.match(r'target\s+"([^"]+)"', line)
        if m:
            name = m.group(1); continue
        m = re.match(r'src\s+"([^"]+)"', line)
        if m and not os.path.exists(os.path.join("userspace", m.group(1))):
            bad.append("%s -> %s" % (name, m.group(1)))
print("\n".join(bad))
PY
)"
if [ -z "$MISSING_SRC" ]; then
    NT="$(grep -c '^target ' userspace/Causticfile)"
    ok "userspace/Causticfile" "$NT targets, every src present"
else
    bad "userspace/Causticfile" "sources missing: $MISSING_SRC"
fi

# Every `bin`/`init` in every profile has to be a real target, or the image ships
# quietly short.
for p in profiles/*.profile; do
    [ -f "$p" ] || continue
    n="$(basename "$p" .profile)"
    if OUT="$("$PY" scripts/mkroot.py --profile "$n" --list 2>&1 >/dev/null)"; then
        COUNT="$("$PY" scripts/mkroot.py --profile "$n" --list 2>/dev/null | tail -1)"
        ok "profile $n" "$COUNT"
    else
        bad "profile $n" "$(echo "$OUT" | head -1)"
    fi
done

# And the same question from the other side. The check above catches a profile
# naming a program that does not exist; this one catches a program no profile
# ships — built by every `caustic-mk build all` and reachable from no ISO, which
# is a line someone forgot to add rather than a decision anyone made. It found
# kabi (whose eleven siblings were all listed), animt and guess.
#
# A warn, not a FAIL: a target can legitimately be built and not shipped for a
# while. The point is that it says so out loud instead of nobody noticing.
ORPHANS="$("$PY" - <<'PY'
import re, glob
targets = []
for line in open("userspace/Causticfile"):
    m = re.match(r'target\s+"([^"]+)"', line.split("//")[0].strip())
    if m:
        targets.append(m.group(1))
shipped = set()
for p in glob.glob("profiles/*.profile"):
    for line in open(p):
        line = line.split("#")[0].strip()
        if line.startswith("opt "):
            line = line[4:].strip()
        m = re.match(r'(?:bin|init)\s+(\S+)', line)
        if m:
            shipped.add(m.group(1))
print(" ".join(t for t in targets if t not in shipped))
PY
)"
if [ -z "$ORPHANS" ]; then
    ok "profile coverage" "every target ships in at least one profile"
else
    warn "profile coverage" "built but in no profile:$(echo " $ORPHANS")"
fi

echo
if [ "$FAIL" = 0 ]; then
    echo "doctor: everything needed is here."
else
    echo "doctor: fix the FAIL lines above, then run it again." >&2
fi
exit "$FAIL"
