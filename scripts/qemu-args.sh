# qemu-args.sh — the ONE definition of the virtual machine causticos boots on.
#
# Sourced by scripts/qemu.sh (which `caustic-mk run run` drives) and by every
# scripts/test-*.sh. Before this file existed the same device line was
# copy-pasted into four scripts and had already drifted — verify ran under KVM
# and run.sh under TCG, which nobody meant. A driver that only enumerates in
# three of the four is a bug you find at the worst possible moment.
#
# Usage — set the knobs, source, then splice the array in:
#
#     source "$(dirname "$0")/qemu-args.sh"
#     qemu-system-x86_64 "${QEMU_ARGS[@]}" -serial stdio -display none
#
# Knobs, all read at source time:
#
#   QEMU_ISO    boot ISO                             (default build/causticos.iso)
#   QEMU_DISK   FAT32 image for AHCI, "" → no disk   (default "")
#   QEMU_MEM    guest RAM                            (default 64M)
#   QEMU_ACCEL  kvm|whpx|hvf|tcg                     (default tcg)
#   QEMU_KVM    legacy: 1 means the same as QEMU_ACCEL=kvm
#   QEMU_SMP    CPU count, "" → let qemu default     (default "")
#   QEMU_PCAP   file to dump net0 traffic to, "" off (default "")
#   QEMU_WAV    file to record guest audio into, "" off (default "")
#
# The disk defaults to NONE because the ISO carries its own root now. Attaching
# one is something a test asks for when the disk is what it is testing.
#
# 64M is measured, not assumed. The ISO is ~7 MB, but the root inside it is a
# SPARSE container (~2.3 MB of non-zero sectors) that the kernel expands into a
# full FAT32 in RAM — the EXPANDED volume, not the ISO, is what costs memory.
# At the 45 MiB mkroot defaults to, the whole desktop comes up in a 64M machine.
# (FAT32 needs 65525 clusters to be FAT32 at all, so ~32.5 MiB is the floor
# below which the kernel refuses the volume, and says so.)
#
# QEMU_PCAP is the highest-leverage debugging knob in the tree: when a packet
# doesn't arrive, open the pcap in Wireshark and read the wrong byte instead of
# guessing at it.
#
# QEMU_WAV is the same idea for sound, and it is the ONLY way to check audio
# without a person listening: the guest plays a tone, QEMU writes the samples
# to a file, and scripts/check-wav.py measures the frequency and the amplitude
# that came out. Without it "the driver works" would mean "it did not crash".

# Sourced directly by the test scripts too, so it pulls in the host
# differences itself rather than trusting every caller to have done it.
. "$(dirname "${BASH_SOURCE[0]}")/portable.sh"

QEMU_ISO="${QEMU_ISO:-build/causticos.iso}"
QEMU_DISK="${QEMU_DISK:-}"
QEMU_MEM="${QEMU_MEM:-64M}"
# QEMU_KVM=1 is the older spelling and still means kvm.
if [ "${QEMU_KVM:-0}" = "1" ]; then QEMU_ACCEL="${QEMU_ACCEL:-kvm}"; fi
QEMU_ACCEL="${QEMU_ACCEL:-tcg}"
QEMU_SMP="${QEMU_SMP:-}"
QEMU_PCAP="${QEMU_PCAP:-}"
QEMU_WAV="${QEMU_WAV:-}"

# The audio backend, decided before the device line that references it and
# spliced into QEMU_ARGS itself rather than into a second array — a second
# array is a second thing every caller has to remember, and the first one to
# forget it was verify.sh, which then failed every run with a machine that
# would not start.
#
# `wav` records at the rate the guest actually plays at, so check-wav.py
# measures the guest's clock and not QEMU's resampler.
if [ -n "$QEMU_WAV" ]; then
    QEMU_AUDIO_BACKEND=("wav,id=snd0,path=$QEMU_WAV,out.frequency=48000,out.channels=2,out.format=s16")
    # The wav backend RECORDS what the guest plays and has no input side at
    # all — QEMU cannot open an ADC on it. So the card it backs is an
    # output-only card, and says so with streams=1. Leaving the capture
    # stream declared would mean advertising a converter with no clock behind
    # it: the guest would open it, wait for frames that can never arrive, and
    # the honest report would be a driver bug that is not one.
    QEMU_SND_STREAMS=1
else
    QEMU_AUDIO_BACKEND=("none,id=snd0")
    # `none` is a full-duplex backend: it consumes playback and produces
    # silence for capture, both on QEMU's clock. That is what lets the boot
    # smoke exercise the capture path on every ordinary run.
    QEMU_SND_STREAMS=2
fi

QEMU_ARGS=(
    -cdrom "$QEMU_ISO"
    -m "$QEMU_MEM"
    -machine q35

    # NIC 0 — Intel 82540EM. Real silicon QEMU emulates faithfully, so the
    # same driver runs on metal.
    # hostfwd is the only way in. SLIRP lets the guest dial out freely and
    # lets nothing dial in, which is right for everything except a server:
    # httpd listens inside, and without a forward there is no client anywhere
    # that could reach it. QEMU_HTTPD_PORT lets a test pick its own so two
    # runs do not fight over one number.
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${QEMU_HTTPD_PORT:-18080}-:8080"
    -device e1000,netdev=net0,mac=52:54:00:12:34:56

    # NIC 1 — modern virtio-net. disable-legacy/disable-modern pin the device
    # to the 1.1 transport kernel/drivers/virtio.cst speaks; without them QEMU
    # offers a transitional device and feature negotiation fails.
    -netdev user,id=net1
    -device virtio-net-pci,netdev=net1,mac=52:54:00:12:34:57,disable-legacy=on,disable-modern=off

    # Absolute pointer — the guest cursor tracks the host cursor with no grab.
    -device virtio-tablet-pci

    # Sound. The backend is `none` for every ordinary run — the DMA engine
    # still runs on QEMU's clock, which is all the driver needs to be
    # exercised — and `wav` when a test wants to READ what the guest played.
    -audiodev "${QEMU_AUDIO_BACKEND[0]}"
    -device "virtio-sound-pci,audiodev=snd0,streams=$QEMU_SND_STREAMS,disable-legacy=on,disable-modern=off"

    # -boot d forces the CD first: the FAT32 image has a valid MBR and BIOS
    # would otherwise try to boot from it.
    -boot d
    -no-reboot
)

# Storage: one AHCI controller and one SATA disk, only when a disk was asked
# for. Note the live root outranks a disk (storage.PRIO_LIVE_ROOT beats
# PRIO_DISK), so attaching one to a live ISO gives the guest a second volume,
# not a different root — booting FROM the disk means an ISO built --no-live.
if [ -n "$QEMU_DISK" ]; then
    QEMU_ARGS+=(
        -drive "id=disk,file=$QEMU_DISK,if=none,format=raw"
        -device ahci,id=ahci
        -device ide-hd,drive=disk,bus=ahci.0
    )
fi

# The accelerator by name — kvm on Linux, whpx on Windows, hvf on macOS, tcg
# anywhere. -enable-kvm is not a portable spelling of "go fast": on a host
# without KVM it is a startup error, not a fallback.
if [ "$QEMU_ACCEL" != "tcg" ]; then
    QEMU_ARGS+=(-accel "$QEMU_ACCEL" -cpu host)
fi

if [ -n "$QEMU_SMP" ]; then
    QEMU_ARGS+=(-smp "$QEMU_SMP")
fi

if [ -n "$QEMU_PCAP" ]; then
    QEMU_ARGS+=(-object "filter-dump,id=dump0,netdev=net0,file=$QEMU_PCAP")
fi
