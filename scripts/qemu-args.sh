# qemu-args.sh — the ONE definition of the virtual machine causticos boots on.
#
# Sourced by scripts/run.sh, scripts/verify.sh, run-wm.sh and run-shell.sh.
# Before this file existed the same device line was copy-pasted into four
# scripts and had already drifted (verify ran under KVM, run.sh under TCG,
# nobody meant that). A driver that only enumerates in three of the four is a
# bug you find at the worst moment, so the machine is defined here once.
#
# Not sourced by run-bootstrap.sh: the self-host round deliberately boots a
# bare machine (no NIC, no tablet) and its own memory/disk sizing.
#
# Usage — set the knobs, source, then splice the array in:
#
#     source "$(dirname "$0")/qemu-args.sh"
#     qemu-system-x86_64 "${QEMU_ARGS[@]}" -serial stdio -display none
#
# Knobs, all read at source time:
#
#   QEMU_ISO    boot ISO                            (default build/causticos.iso)
#   QEMU_DISK   FAT32 image handed to AHCI          (default build/disk.img)
#   QEMU_MEM    guest RAM                           (default 128M)
#   QEMU_KVM    1 → -enable-kvm -cpu host           (default 0)
#   QEMU_SMP    CPU count, "" → let qemu default    (default "")
#   QEMU_PCAP   file to dump net0 traffic to, "" off (default "")
#
# QEMU_PCAP is the highest-leverage debugging knob in the tree: when a packet
# doesn't arrive, open the pcap in Wireshark and read the wrong byte instead of
# guessing at it.

QEMU_ISO="${QEMU_ISO:-build/causticos.iso}"
QEMU_DISK="${QEMU_DISK:-build/disk.img}"
QEMU_MEM="${QEMU_MEM:-128M}"
QEMU_KVM="${QEMU_KVM:-0}"
QEMU_SMP="${QEMU_SMP:-}"
QEMU_PCAP="${QEMU_PCAP:-}"

QEMU_ARGS=(
    -cdrom "$QEMU_ISO"
    -m "$QEMU_MEM"
    -machine q35

    # Storage: one AHCI controller, one SATA disk carrying the FAT32 root.
    -drive "id=disk,file=$QEMU_DISK,if=none,format=raw"
    -device ahci,id=ahci
    -device ide-hd,drive=disk,bus=ahci.0

    # NIC 0 — Intel 82540EM. Real silicon QEMU emulates faithfully, so the
    # same driver runs on metal.
    -netdev user,id=net0
    -device e1000,netdev=net0,mac=52:54:00:12:34:56

    # NIC 1 — modern virtio-net. disable-legacy/disable-modern pin the device
    # to the 1.1 transport kernel/drivers/virtio.cst speaks; without them QEMU
    # offers a transitional device and feature negotiation fails.
    -netdev user,id=net1
    -device virtio-net-pci,netdev=net1,mac=52:54:00:12:34:57,disable-legacy=on,disable-modern=off

    # Absolute pointer — the guest cursor tracks the host cursor with no grab.
    -device virtio-tablet-pci

    # -boot d forces the CD first: the FAT32 image has a valid MBR and BIOS
    # would otherwise try to boot from it.
    -boot d
    -no-reboot
)

if [ "$QEMU_KVM" = "1" ]; then
    QEMU_ARGS+=(-enable-kvm -cpu host)
fi

if [ -n "$QEMU_SMP" ]; then
    QEMU_ARGS+=(-smp "$QEMU_SMP")
fi

if [ -n "$QEMU_PCAP" ]; then
    QEMU_ARGS+=(-object "filter-dump,id=dump0,netdev=net0,file=$QEMU_PCAP")
fi
