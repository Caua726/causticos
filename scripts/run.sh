#!/bin/bash
set -e

CAUSTIC_DIR="/run/media/caua/Caua/caua/Documentos/Projetos-Pessoais/Caustic"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$PROJECT_DIR"

echo "==> Compiling kernel..."
$CAUSTIC_DIR/caustic -c kernel/main.cst

echo "==> Assembling..."
$CAUSTIC_DIR/caustic-as kernel/main.cst.s

echo "==> Linking (freestanding, higher-half)..."
mkdir -p build
$CAUSTIC_DIR/caustic-ld --freestanding --entry=_kernel_start \
    --base=0xFFFFFFFF80000000 kernel/main.cst.s.o -o build/kernel.elf

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

echo "==> Booting in QEMU..."
qemu-system-x86_64 -cdrom build/causticos.iso -m 128M
