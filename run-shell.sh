#!/bin/bash
# run-shell.sh — build the userspace programs, seed the FAT32 disk with the shell
# as /init + the tools, and boot QEMU with a display so you can type into the
# framebuffer shell. Serial (markers) still prints to this terminal.
#
#   ./run-shell.sh
#
# Requires build/causticos.iso (build the kernel first: scripts/run.sh). The
# userspace programs live in userspace/ and are compiled by userspace/build.sh
# against the sibling Caustic compiler (set CAUSTIC_DIR to override its location).
# Try at the prompt: help / sysinfo / echo oi / uptime / ls / cat hello.txt.
set -e
cd "$(dirname "$0")"

[ -f build/causticos.iso ] || { echo "build/causticos.iso missing — run scripts/run.sh once to build the kernel"; exit 1; }

bash userspace/build.sh
B=userspace/build

qemu-img create -f raw build/disk.img 64M >/dev/null
mkfs.fat -F 32 -n CAUSTICOS build/disk.img >/dev/null
python3 scripts/fat32_add_file.py build/disk.img addfilebin init.cse "$B/init.cse" >/dev/null
for p in echo cat ls uptime sysinfo vic; do
    python3 scripts/fat32_add_file.py build/disk.img addfilebin "$p.cse" "$B/$p.cse" >/dev/null
done
python3 scripts/fat32_add_file.py build/disk.img addfile hello.txt \
    "ola do CausticOS! este arquivo veio do disco FAT32 via cat." >/dev/null
echo "disk seeded: /init.cse(shell) + echo cat ls uptime sysinfo + hello.txt"
echo "booting with a display — type into the QEMU window..."

exec qemu-system-x86_64 \
    -cdrom build/causticos.iso -m 128M -machine q35 \
    -drive id=disk,file=build/disk.img,if=none,format=raw \
    -device ahci,id=ahci -device ide-hd,drive=disk,bus=ahci.0 \
    -netdev user,id=net0 -device e1000,netdev=net0,mac=52:54:00:12:34:56 -device virtio-tablet-pci -netdev user,id=net1 -device virtio-net-pci,netdev=net1,mac=52:54:00:12:34:57,disable-legacy=on,disable-modern=off \
    -boot d -serial stdio -no-reboot
