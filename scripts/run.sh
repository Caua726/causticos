#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$PROJECT_DIR"

echo "==> Compiling kernel..."
# kernel modules live in subfolders (kernel/arch, kernel/mm, ...); the module
# names stay simple ('use "pmm.cst"') and resolve via these --path search dirs.
KPATH="--path kernel --path kernel/arch --path kernel/time --path kernel/mm --path kernel/task --path kernel/drivers --path kernel/fs --path kernel/ipc --path kernel/sys --path kernel/lib --path kernel/test --path font"
caustic -c kernel/main.cst $KPATH

echo "==> Assembling..."
caustic-as kernel/main.cst.s
# cdvrspec_data.s .incbin's the .cdvrspec text blobs — re-assemble it every
# build so editing a driver's .cdvrspec (e.g. its `device { class }` block)
# actually reaches the kernel. Skipping this leaves a stale .s.o and the build
# silently runs the old specs (or none).
caustic-as kernel/cdvrspec_data.s
caustic-as kernel/smp_asm.s
caustic-as kernel/syscall_entry.s
caustic-as kernel/random_asm.s

echo "==> Linking (freestanding, higher-half)..."
mkdir -p build
# --strip: omits symbol/section tables. Limine inspects section
# headers when they're present and the resulting load behaviour
# diverges from program-header-only mode; kernels consistently page-
# fault inside sched.init when linked non-stripped. The bug isn't in
# caustic-ld (its section layout is correct post-2026-04-19 fix) so
# much as in Limine's interaction with embedded symtab/strtab, so
# kernels stay stripped by policy.
caustic-ld --strip --freestanding --entry=_kernel_start \
    --base=0xFFFFFFFF80000000 \
    kernel/main.cst.s.o kernel/cdvrspec_data.s.o kernel/smp_asm.s.o \
    kernel/syscall_entry.s.o kernel/random_asm.s.o \
    -o build/kernel.elf

echo "==> Creating ISO..."
mkdir -p build/iso/boot/limine build/iso/EFI/BOOT
cp build/kernel.elf build/iso/boot/
cp limine.conf build/iso/boot/limine/
cp /usr/share/limine/limine-bios.sys build/iso/boot/limine/
cp /usr/share/limine/limine-bios-cd.bin build/iso/boot/limine/
cp /usr/share/limine/limine-uefi-cd.bin build/iso/boot/limine/
cp /usr/share/limine/BOOTX64.EFI build/iso/EFI/BOOT/

xorriso -as mkisofs -b boot/limine/limine-bios-cd.bin -no-emul-boot \
    -boot-load-size 4 -boot-info-table --efi-boot boot/limine/limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    build/iso -o build/causticos.iso 2>/dev/null

limine bios-install build/causticos.iso 2>/dev/null

# Disk image — created once, reseeded each run so every boot starts
# from a known set of test fixtures and the kernel can exercise the
# full create/unlink/rename cycle without interference.
if [ "${RESEED_DISK:-1}" = "1" ]; then
    echo "==> Reseeding FAT32 fixture disk..."
    qemu-img create -f raw build/disk.img 64M >/dev/null
    mkfs.fat -F 32 -n CAUSTICOS build/disk.img >/dev/null
    python3 scripts/fat32_add_file.py build/disk.img addfile hello.txt \
        "Hello from causticos FAT32!" >/dev/null
    python3 scripts/fat32_add_file.py build/disk.img addfile bigfile.bin \
        "$(python3 -c 'print("A"*600 + "B"*600)')" >/dev/null
    python3 scripts/fat32_add_file.py build/disk.img addfile \
        "long-name-with-spaces and mixed case.txt" "LFN content here" >/dev/null
    python3 scripts/fat32_add_file.py build/disk.img mkdir docs >/dev/null
    python3 scripts/fat32_add_file.py build/disk.img addfile readme.md \
        "# Docs readme\n\nInside docs subdir." 8 >/dev/null
    # /init.cse — the first userspace program the kernel launches from disk
    # (boot→userspace handoff). A stub today; the terminal replaces it later.
    python3 scripts/make_init_cse.py build/init.cse >/dev/null
    python3 scripts/fat32_add_file.py build/disk.img addfilebin init.cse build/init.cse >/dev/null
fi

# NOBOOT=1 stops after producing build/causticos.iso — what verify.sh consumes,
# and what you want when the next step is a 20-run sweep rather than one boot.
if [ "${NOBOOT:-0}" = "1" ]; then
    echo "==> Built build/causticos.iso (NOBOOT=1, not booting)"
    exit 0
fi

echo "==> Booting in QEMU..."
# The machine itself (disks, NICs, pointer) is defined once in qemu-args.sh.
# PCAP=<file> on the command line dumps net0 traffic for Wireshark.
QEMU_PCAP="${PCAP:-}"
source scripts/qemu-args.sh
qemu-system-x86_64 \
    "${QEMU_ARGS[@]}" \
    -serial stdio \
    -display none \
    "$@"
