#!/usr/bin/env bash
# qemu.sh — boot build/causticos.iso.
#
# Default is the live ISO with no disk at all: the root travels inside the image.
# --persist attaches a FAT32 disk and makes it the root instead, which is the
# only path that exercises the AHCI driver and real persistent writes.
#
# Invoked from the Causticfile:  caustic-mk run run -- [options]
set -euo pipefail

cd "$(dirname "$0")/.."

DISPLAY_MODE=gui
KVM=auto
MEM=512M
SMP=2
PERSIST=""
ISO="build/causticos.iso"
MONITOR=0
EXTRA=()

usage() {
    cat <<'EOF'
usage: caustic-mk run run -- [options] [-- <extra qemu args>]

  --headless          no window; serial on stdio (default is a window)
  --gui               force a window
  --kvm / --no-kvm    hardware virtualisation (default: use it when /dev/kvm is writable)
  -m SIZE             guest memory (default 512M)
  --smp N             cpu count (default 2)
  --persist[=PATH]    attach a FAT32 disk and boot from it instead of the live root
                      (created from the current profile if PATH does not exist)
  --iso PATH          boot a different ISO (default build/causticos.iso)
  --monitor           headless + QEMU monitor on /tmp/cos-mon and QMP on /tmp/cos-qmp

The kernel command line is NOT set here. QEMU's -append only reaches a kernel
loaded with -kernel, and this one is loaded by Limine off the ISO — so the
command line is baked in at ISO build time:

  caustic-mk run iso -- --cmdline "smoke root=sata0"
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --headless) DISPLAY_MODE=headless; shift ;;
        --gui) DISPLAY_MODE=gui; shift ;;
        --kvm) KVM=on; shift ;;
        --no-kvm) KVM=off; shift ;;
        -m) MEM="$2"; shift 2 ;;
        --smp) SMP="$2"; shift 2 ;;
        --persist) PERSIST="build/disk.img"; shift ;;
        --persist=*) PERSIST="${1#*=}"; shift ;;
        --iso) ISO="$2"; shift 2 ;;
        --monitor) MONITOR=1; DISPLAY_MODE=headless; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; EXTRA=("$@"); break ;;
        *) echo "run: unknown option '$1' (try --help)" >&2; exit 1 ;;
    esac
done

[ -f "$ISO" ] || { echo "run: $ISO missing — run 'caustic-mk run iso'" >&2; exit 1; }

ARGS=(-cdrom "$ISO" -m "$MEM" -machine q35 -smp "$SMP")

# KVM when it is actually usable. The old verify script passed -enable-kvm
# unconditionally and simply failed on a machine without it; TCG is ~10x slower
# but it is a working fallback, and saying which one is in use beats guessing
# from the boot time.
if [ "$KVM" = auto ]; then
    if [ -w /dev/kvm ]; then KVM=on; else KVM=off; fi
fi
if [ "$KVM" = on ]; then
    ARGS+=(-enable-kvm -cpu host)
else
    echo "run: no KVM (/dev/kvm not writable) — falling back to TCG, expect a slower boot" >&2
fi

# The disk. Only attached when asked for: the live root is the default and a
# stray disk on the bus is one more thing to explain when a boot misbehaves.
if [ -n "$PERSIST" ]; then
    if [ ! -f "$PERSIST" ]; then
        echo "run: $PERSIST does not exist — creating it from profile ${COS_PROFILE:-desktop}"
        python3 scripts/mkroot.py --profile "${COS_PROFILE:-desktop}" --img "$PERSIST" -q
    fi
    ARGS+=(-drive "id=disk,file=$PERSIST,if=none,format=raw"
           -device ahci,id=ahci -device ide-hd,drive=disk,bus=ahci.0)
fi

# The device set the system is actually developed against. Keep it whole: the
# drivers for all of these are exercised at boot, and dropping one silently
# stops testing it.
ARGS+=(-netdev user,id=net0 -device e1000,netdev=net0,mac=52:54:00:12:34:56
       -device virtio-tablet-pci
       -netdev user,id=net1
       -device virtio-net-pci,netdev=net1,mac=52:54:00:12:34:57,disable-legacy=on,disable-modern=off)

# -boot d forces the CD first. A FAT32 disk image has a valid MBR and BIOS will
# otherwise try to boot from it before the CD.
ARGS+=(-boot d -serial stdio -no-reboot)

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
    echo "run: ${MEM} ram, ${SMP} cpu, kvm=${KVM}, root = $PERSIST (persistent)"
else
    echo "run: ${MEM} ram, ${SMP} cpu, kvm=${KVM}, root = live (no disk attached)"
fi

exec qemu-system-x86_64 "${ARGS[@]}" ${EXTRA[@]+"${EXTRA[@]}"}
