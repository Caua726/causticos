#!/usr/bin/env bash
source "$(dirname "$0")/portable.sh"
# qemu.sh — build the system and boot it.
#
# ONE command from an edited source file to a running desktop: kernel, userspace,
# ISO, boot. See scripts/rebuild.sh for why booting rebuilds at all; --no-build
# is how you say "boot what is already there".
#
# Default is the live ISO with no disk at all: the root travels inside the image.
# --persist attaches a FAT32 disk and makes it the root instead, which is the
# only path that exercises the AHCI driver and real persistent writes.
#
# Invoked from the Causticfile:  caustic-mk run run -- [options]
set -euo pipefail

cd "$(dirname "$0")/.."

DISPLAY_MODE=gui
ACCEL_WANT=tcg
MEM=64M
SMP=2
PERSIST=""
ISO="build/causticos.iso"
ISO_GIVEN=0
BUILD=1
BUILD_GIVEN=0
PROFILE="${COS_PROFILE:-desktop}"
CMDLINE=""
MONITOR=0
EXTRA=()

usage() {
    cat <<'EOF'
usage: caustic-mk run run -- [options] [-- <extra qemu args>]

Builds kernel + userspace + ISO, then boots it.

  --no-build          skip the build; boot the ISO that is already there
  --profile NAME      which programs the root image ships (default desktop)
  --cmdline "..."     bake a kernel command line into the ISO
  --headless          no window; serial on stdio (default is a window)
  --gui               force a window
  --kvm               use hardware virtualisation when the host has it
                      (default is TCG emulation, which works everywhere)
  -m SIZE             guest memory (default 64M)
  --smp N             cpu count (default 2)
  --persist[=PATH]    attach a FAT32 disk and boot from it instead of the live root
                      (created from the current profile if PATH does not exist)
  --iso PATH          boot a different ISO; implies --no-build
  --monitor           headless + QEMU monitor on /tmp/cos-mon and QMP on /tmp/cos-qmp

The kernel command line does NOT go on a QEMU argument. -append only reaches a
kernel loaded with -kernel, and this one is loaded by Limine off the ISO — so it
is baked in at ISO build time, which is what --cmdline above does:

  caustic-mk run run -- --cmdline "smoke root=sata0"
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) BUILD=0; BUILD_GIVEN=1; shift ;;
        --build) BUILD=1; BUILD_GIVEN=1; shift ;;
        --profile) PROFILE="$2"; shift 2 ;;
        --profile=*) PROFILE="${1#*=}"; shift ;;
        --cmdline) CMDLINE="$2"; shift 2 ;;
        --headless) DISPLAY_MODE=headless; shift ;;
        --gui) DISPLAY_MODE=gui; shift ;;
        --kvm) ACCEL_WANT=auto; shift ;;
        --no-kvm) ACCEL_WANT=tcg; shift ;;
        -m) MEM="$2"; shift 2 ;;
        --smp) SMP="$2"; shift 2 ;;
        --persist) PERSIST="build/disk.img"; shift ;;
        --persist=*) PERSIST="${1#*=}"; shift ;;
        --iso) ISO="$2"; ISO_GIVEN=1; shift 2 ;;
        --monitor) MONITOR=1; DISPLAY_MODE=headless; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; EXTRA=("$@"); break ;;
        *) echo "run: unknown option '$1' (try --help)" >&2; exit 1 ;;
    esac
done

# Naming an ISO means booting THAT file, so building one over it would be the
# opposite of what was asked. Explicit --build still wins.
if [ "$ISO_GIVEN" = 1 ] && [ "$BUILD_GIVEN" = 0 ]; then
    BUILD=0
fi

if [ "$BUILD" = 1 ]; then
    source "$(dirname "$0")/rebuild.sh"
    cos_rebuild "$PROFILE" "$CMDLINE"
fi

[ -f "$ISO" ] || { echo "run: $ISO missing — run 'caustic-mk run iso'" >&2; exit 1; }

# KVM when it is actually usable. Passing -enable-kvm unconditionally simply
# fails on a machine without it; TCG is ~10x slower but it works, and saying
# which one is in use beats inferring it from the boot time.
# TCG by default, on every host. Emulation costs about 20% of boot time here
# — measured, 3.4s to a ready desktop against 2.8s accelerated — and in return
# the same command does the same thing on Linux, WSL, Windows and macOS, with
# no /dev/kvm, no group membership and no nested-virtualisation setting. Pass
# --kvm when you want that 20% back.
if [ "$ACCEL_WANT" = auto ]; then
    ACCEL="$(qemu_accel)"
    if [ "$ACCEL" = tcg ]; then
        echo "run: --kvm asked for, but this host offers no accelerator — using TCG" >&2
    fi
else
    ACCEL=tcg
fi

# The disk. Only attached when asked for: the live root is the default, and a
# stray disk on the bus is one more thing to explain when a boot misbehaves.
if [ -n "$PERSIST" ] && [ ! -f "$PERSIST" ]; then
    echo "run: $PERSIST does not exist — creating it from profile $PROFILE"
    "$PY" scripts/mkroot.py --profile "$PROFILE" --img "$PERSIST" -q
fi

# The machine is defined in exactly one place. This script decides POLICY (which
# ISO, how much memory, whether a disk is attached, KVM or not) and qemu-args.sh
# owns the device line — so a driver can never be exercised here and missing from
# a test, which is how the device set drifted before it existed.
QEMU_ISO="$ISO" QEMU_MEM="$MEM" QEMU_SMP="$SMP" QEMU_DISK="$PERSIST" \
QEMU_ACCEL="$ACCEL"
export QEMU_ISO QEMU_MEM QEMU_SMP QEMU_DISK QEMU_ACCEL
source "$(dirname "$0")/qemu-args.sh"
ARGS=("${QEMU_ARGS[@]}" -serial stdio)

if [ "$DISPLAY_MODE" = headless ]; then
    ARGS+=(-display none)
    if [ "$MONITOR" = 1 ]; then
        rm -f /tmp/cos-mon /tmp/cos-qmp
        ARGS+=(-monitor unix:/tmp/cos-mon,server,nowait -qmp unix:/tmp/cos-qmp,server,nowait)
        echo "run: monitor on /tmp/cos-mon (screendump/sendkey), QMP on /tmp/cos-qmp"
    fi
else
    # The guest's PS/2 mouse is relative, so the host pointer has to be GRABBED
    # for it to track, and native Wayland refuses QEMU's classic grab. Route GTK
    # through XWayland, where click-to-grab works. (The virtio-tablet above is
    # absolute and needs no grab — this is for the PS/2 path.)
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then
        export GDK_BACKEND=x11
    fi
    echo "run: click inside to capture the mouse, Ctrl+Alt+G releases it"
fi

if [ -n "$PERSIST" ]; then
    echo "run: ${MEM} ram, ${SMP} cpu, accel=${ACCEL}, root = $PERSIST (persistent)"
else
    echo "run: ${MEM} ram, ${SMP} cpu, accel=${ACCEL}, root = live (no disk attached)"
fi

exec qemu-system-x86_64 "${ARGS[@]}" ${EXTRA[@]+"${EXTRA[@]}"}
