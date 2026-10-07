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
#   QEMU_FIRMWARE  bios|uefi                         (default bios)
#
# The disk defaults to NONE because the ISO carries its own root now. Attaching
# one is something a test asks for when the disk is what it is testing.
#
# 64M is measured, not assumed. The ISO is ~7 MB, but the root inside it is a
# SPARSE container (~2.3 MB of non-zero sectors) that the kernel expands into a
# full FAT32 in RAM — the EXPANDED volume, not the ISO, is what costs memory.
# At the 33 MiB mkroot defaults to, the desktop comes up in a 64M machine with
# about 13 MB free, which is what makes it a machine you can run things on
# rather than one that merely boots.
#
# (FAT32 needs 65525 clusters to be FAT32 at all, so 66581 sectors ≈ 32.5 MiB is
# the floor below which the kernel refuses the volume, and says so. 33 MiB is
# one megabyte over it. The volume is 93% empty and that is not slack to trim:
# a smaller FAT32 does not exist.)
#
# UEFI needs 128M, not 64M, and the difference is not ours to remove. Limine sets
# 64 MiB aside for the firmware below 4 GiB before it loads anything (its UEFI
# init_memmap, unconditionally), and OVMF itself is holding some 45 MB of boot-
# services memory at that point; the kernel and its modules have to fit in what
# is left. At 116M and below the loader halts with "High memory allocator: Out
# of memory" before the kernel exists. Once booted, the kernel takes back all of
# the firmware's boot-time memory (pmm.reclaim_boot), so a 128M UEFI machine
# ends up with more free RAM than a 64M BIOS one, not less.
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
QEMU_FIRMWARE="${QEMU_FIRMWARE:-bios}"

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
    # A second SLIRP instance must use a distinct subnet: both instances'
    # default DHCP leases are otherwise 10.0.2.15, with overlapping routes.
    -netdev user,id=net1,net=10.0.3.0/24
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

# UEFI: OVMF on two flash devices, the firmware read-only and its variable
# store. The store is the distribution's template under snapshot=on: the
# firmware writes boot entries into it, and those writes land in a throwaway
# overlay instead — so the template stays untouched (it is usually not ours to
# write), parallel machines never share a store, and no copy is left behind.
# scripts/ovmf.py finds the firmware the way libvirt does, from QEMU's own
# descriptors.
if [ "$QEMU_FIRMWARE" = uefi ]; then
    if ! _ovmf="$("$PY" "$(dirname "${BASH_SOURCE[0]}")/ovmf.py")"; then
        echo "qemu-args: UEFI asked for, and there is no firmware to boot it with" >&2
        exit 1
    fi
    _ovmf_code="$(printf '%s\n' "$_ovmf" | sed -n 1p)"
    _ovmf_vars="$(printf '%s\n' "$_ovmf" | sed -n 2p)"
    QEMU_ARGS+=(-drive "if=pflash,format=raw,readonly=on,file=$(hostpath "$_ovmf_code")")
    if [ -n "$_ovmf_vars" ]; then
        QEMU_ARGS+=(-drive "if=pflash,format=raw,snapshot=on,file=$(hostpath "$_ovmf_vars")")
    fi
elif [ "$QEMU_FIRMWARE" != bios ]; then
    echo "qemu-args: QEMU_FIRMWARE is '$QEMU_FIRMWARE'; it takes bios or uefi" >&2
    exit 1
fi

if [ -n "$QEMU_PCAP" ]; then
    QEMU_ARGS+=(-object "filter-dump,id=dump0,netdev=net0,file=$QEMU_PCAP")
fi
