#!/usr/bin/env bash
# usb.sh — write build/causticos.iso to a removable device.
#
# The ISO is a hybrid image: the same file boots from optical media, from a USB
# stick under BIOS, and under UEFI. Because it carries the root, a stick written
# this way boots the whole system on real hardware with no other storage.
#
#   caustic-mk run usb -- /dev/sdX
#
# This DESTROYS everything on the target. It refuses to touch a device that is
# not removable, refuses one with mounted partitions, and asks before writing —
# the failure mode being guarded against is a typo that names the system disk.
set -euo pipefail

cd "$(dirname "$0")/.."

DEV="${1:-}"
ASSUME_YES=0
[ "${2:-}" = "--yes" ] && ASSUME_YES=1

if [ -z "$DEV" ]; then
    echo "usage: caustic-mk run usb -- /dev/sdX [--yes]" >&2
    echo >&2
    echo "removable block devices right now:" >&2
    lsblk -dno NAME,SIZE,RM,MODEL 2>/dev/null | awk '$3==1 {printf "  /dev/%-6s %-8s %s\n", $1, $2, substr($0, index($0,$4))}' >&2
    exit 1
fi

[ -f build/causticos.iso ] || { echo "usb: build/causticos.iso missing — run 'caustic-mk run build'" >&2; exit 1; }
[ -b "$DEV" ] || { echo "usb: $DEV is not a block device" >&2; exit 1; }

BASE="$(basename "$DEV")"
RM="$(cat "/sys/block/$BASE/removable" 2>/dev/null || echo 0)"
if [ "$RM" != "1" ]; then
    echo "usb: $DEV is not removable — refusing. Write it by hand if you are certain." >&2
    exit 1
fi

MOUNTED="$(lsblk -nro MOUNTPOINT "$DEV" 2>/dev/null | grep -v '^$' || true)"
if [ -n "$MOUNTED" ]; then
    echo "usb: $DEV has mounted partitions — unmount them first:" >&2
    echo "$MOUNTED" | sed 's/^/  /' >&2
    exit 1
fi

SIZE="$(lsblk -dno SIZE "$DEV" 2>/dev/null || echo '?')"
MODEL="$(lsblk -dno MODEL "$DEV" 2>/dev/null || echo '?')"
echo "target : $DEV  ($SIZE, $MODEL)"
echo "source : build/causticos.iso ($(stat -c%s build/causticos.iso) bytes)"
echo
echo "This ERASES everything on $DEV."

if [ "$ASSUME_YES" != 1 ]; then
    printf "Type the device name again to confirm: "
    read -r CONFIRM
    [ "$CONFIRM" = "$DEV" ] || { echo "usb: not confirmed — nothing written." >&2; exit 1; }
fi

dd if=build/causticos.iso of="$DEV" bs=4M oflag=direct conv=fsync status=progress
sync
echo "usb: written. It boots on BIOS and UEFI, and needs no other storage."
