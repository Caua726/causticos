#!/bin/bash
# run-wm.sh — build the userspace programs, seed the FAT32 disk with the
# window manager as /init (+ the clients and tools), and boot QEMU.
#
#   ./run-wm.sh             — with a display: Alt+Tab cycles focus,
#                             Super+Enter opens a window, Super+Q closes it,
#                             drag titlebars once the mouse slice lands
#   HEADLESS=1 ./run-wm.sh  — no display; the QEMU monitor listens on
#                             /tmp/cwm-mon for automation:
#                               echo screendump /tmp/wm.ppm | socat - unix:/tmp/cwm-mon
#                               echo sendkey alt-tab        | socat - unix:/tmp/cwm-mon
#
# Requires build/causticos.iso (build the kernel first: scripts/run.sh).
set -e
cd "$(dirname "$0")"

[ -f build/causticos.iso ] || { echo "build/causticos.iso missing — run scripts/run.sh once to build the kernel"; exit 1; }

bash userspace/build.sh
B=userspace/build

qemu-img create -f raw build/disk.img 64M >/dev/null
mkfs.fat -F 32 -n CAUSTICOS build/disk.img >/dev/null
python3 scripts/fat32_add_file.py build/disk.img addfilebin init.cse "$B/wm.cse" >/dev/null
for p in wmpat wterm echo cat ls uptime sysinfo vic; do
    if [ -f "$B/$p.cse" ]; then
        python3 scripts/fat32_add_file.py build/disk.img addfilebin "$p.cse" "$B/$p.cse" >/dev/null
    fi
done
python3 scripts/fat32_add_file.py build/disk.img addfile hello.txt \
    "ola do CausticOS! este arquivo veio do disco FAT32 via cat." >/dev/null
echo "disk seeded: /init.cse(wm) + wmpat + tools + hello.txt"

DISPLAY_ARGS=()
if [ "${HEADLESS:-0}" = "1" ]; then
    rm -f /tmp/cwm-mon
    DISPLAY_ARGS=(-display none -monitor unix:/tmp/cwm-mon,server,nowait)
    echo "headless: monitor at /tmp/cwm-mon (screendump / sendkey)"
else
    echo "booting with a display — Alt+Tab / Super+Enter / Super+Q..."
fi

exec qemu-system-x86_64 \
    -cdrom build/causticos.iso -m 128M -machine q35 \
    -drive id=disk,file=build/disk.img,if=none,format=raw \
    -device ahci,id=ahci -device ide-hd,drive=disk,bus=ahci.0 \
    -netdev user,id=net0 -device e1000,netdev=net0,mac=52:54:00:12:34:56 \
    -boot d -serial stdio -no-reboot "${DISPLAY_ARGS[@]}"
