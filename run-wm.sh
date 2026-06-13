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
for p in wmpat wterm newterm echo cat ls uptime sysinfo vic guess \
         wc head tail grep rev tac uniq fold cmp seq cut sort hexdump \
         touch mkdir rmdir rm mv cp stat du tree find clear \
         ps free df top run cc make objdump pager hexedit; do
    if [ -f "$B/$p.cse" ]; then
        python3 scripts/fat32_add_file.py build/disk.img addfilebin "$p.cse" "$B/$p.cse" >/dev/null
    fi
done
# a sample source so `run greet.cst` / `cc greet.cst` work out of the box (needs
# /caustic.cse + the /std tree, seeded below).
[ -f userspace/greet.cst ] && python3 scripts/fat32_add_file.py build/disk.img addfilebin greet.cst userspace/greet.cst >/dev/null
python3 scripts/fat32_add_file.py build/disk.img addfile hello.txt \
    "ola do CausticOS! este arquivo veio do disco FAT32 via cat." >/dev/null

# Ship the self-hosted compiler: the converged caustic.cse (byte-identical
# across 4 on-device bootstrap rounds — see run-bootstrap.sh) + its whole
# source tree, so the OS comes WITH a working compiler you can run from a
# terminal, Unix-tradition style:
#   caustic /src/main.cst -o /out.cse --target=caustic-x86_64 --stack-size=8388608 -q
if [ -f build/caustic.cse ]; then
    python3 scripts/fat32_add_file.py build/disk.img addfilebin caustic.cse build/caustic.cse >/dev/null
    # the standalone assembler + linker (scripts/build-tools.sh), so the OS has
    # the whole toolchain: `caustic` one-shot, or caustic-as | caustic-ld staged.
    for tool in caustic-as caustic-ld; do
        if [ -f "build/$tool.cse" ]; then
            python3 scripts/fat32_add_file.py build/disk.img addfilebin "$tool.cse" "build/$tool.cse" >/dev/null
        fi
    done
    if [ -d /tmp/srcsnap/src ]; then
        python3 scripts/fat32_mirror.py build/disk.img \
            /tmp/srcsnap/src /tmp/srcsnap/std \
            /tmp/srcsnap/caustic-assembler /tmp/srcsnap/caustic-linker >/dev/null
        echo "disk seeded: /init.cse(wm) + tools + /caustic.cse (self-hosted) + source tree"
    else
        echo "disk seeded: /init.cse(wm) + tools + /caustic.cse (no source tree — run run-bootstrap.sh to snapshot it)"
    fi
else
    echo "disk seeded: /init.cse(wm) + wmpat + tools + hello.txt"
fi

DISPLAY_ARGS=()
if [ "${HEADLESS:-0}" = "1" ]; then
    rm -f /tmp/cwm-mon /tmp/cwm-qmp
    DISPLAY_ARGS=(-display none -monitor unix:/tmp/cwm-mon,server,nowait
                  -qmp unix:/tmp/cwm-qmp,server,nowait)
    echo "headless: monitor at /tmp/cwm-mon (screendump/sendkey),"
    echo "          QMP at /tmp/cwm-qmp (input-send-event abs for the tablet)"
else
    # The guest mouse is a relative PS/2 device, so the host pointer must be
    # GRABBED for it to track. Native Wayland refuses QEMU's classic pointer
    # grab — route GTK through XWayland, where click-to-grab works.
    # (The real fix is an absolute-pointing virtio-tablet driver in the
    # guest; until then: click inside to capture, Ctrl+Alt+G to release.)
    if [ -n "$WAYLAND_DISPLAY" ]; then
        export GDK_BACKEND=x11
    fi
    echo "booting with a display — CLICK INSIDE to capture the mouse,"
    echo "Ctrl+Alt+G releases it. Alt+Tab / Super+Enter / Super+Q / drag..."
fi

exec qemu-system-x86_64 \
    -cdrom build/causticos.iso -m 128M -machine q35 -smp 2 \
    -drive id=disk,file=build/disk.img,if=none,format=raw \
    -device ahci,id=ahci -device ide-hd,drive=disk,bus=ahci.0 \
    -netdev user,id=net0 -device e1000,netdev=net0,mac=52:54:00:12:34:56 -device virtio-tablet-pci -netdev user,id=net1 -device virtio-net-pci,netdev=net1,mac=52:54:00:12:34:57,disable-legacy=on,disable-modern=off \
    -boot d -serial stdio -no-reboot "${DISPLAY_ARGS[@]}"
