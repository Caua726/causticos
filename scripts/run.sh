#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$PROJECT_DIR"

echo "==> Compiling kernel..."
caustic -c kernel/main.cst

echo "==> Assembling..."
caustic-as kernel/main.cst.s

echo "==> Linking (freestanding, higher-half)..."
mkdir -p build
# --strip is REQUIRED: caustic-ld's section table writer corrupts the
# ELF once the kernel crosses ~300KB. Program headers stay correct so
# Limine still loads it, but objdump/readelf break and we saw random
# page faults until we linked stripped.
caustic-ld --strip --freestanding --entry=_kernel_start \
    --base=0xFFFFFFFF80000000 \
    kernel/main.cst.s.o kernel/cdvrspec_data.s.o \
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
fi

echo "==> Booting in QEMU..."
# -boot d forces the CD first — the 64MB FAT32 image has a valid MBR
# and BIOS would otherwise try to boot from it before the CD.
qemu-system-x86_64 \
    -cdrom build/causticos.iso \
    -m 128M \
    -machine q35 \
    -drive id=disk,file=build/disk.img,if=none,format=raw \
    -device ahci,id=ahci \
    -device ide-hd,drive=disk,bus=ahci.0 \
    -boot d \
    -serial stdio \
    -display none \
    -no-reboot \
    "$@"
