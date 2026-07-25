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
for p in echo cat ls uptime sysinfo vic btop ps top free df grep wc sort head tail; do
    python3 scripts/fat32_add_file.py build/disk.img addfilebin "$p.cse" "$B/$p.cse" >/dev/null
done
python3 scripts/fat32_add_file.py build/disk.img addfile hello.txt \
    "ola do CausticOS! este arquivo veio do disco FAT32 via cat." >/dev/null
echo "disk seeded: /init.cse(shell) + echo cat ls uptime sysinfo + hello.txt"
echo "booting with a display — type into the QEMU window..."

source scripts/qemu-args.sh
exec qemu-system-x86_64 "${QEMU_ARGS[@]}" -serial stdio
