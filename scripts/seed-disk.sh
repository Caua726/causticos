#!/bin/bash
# seed-disk.sh — (re)build the userspace and seed build/disk.img for the
# libvirt/virt-manager 'causticos' VM, WITHOUT booting. The VM boots
# build/causticos.iso (kernel) and mounts build/disk.img (this FAT32 fixture).
#
#   ./scripts/seed-disk.sh              # /init = shell (fullscreen REPL)
#   ./scripts/seed-disk.sh wm           # /init = window manager (floating windows)
#   ./scripts/seed-disk.sh wm --no-build   # reseed WM from existing build/*.cse
#
# After seeding, start the VM:
#   virsh -c qemu:///session start causticos     (or press ▶ in virt-manager)
set -e
cd "$(dirname "$0")/.."

[ -f build/causticos.iso ] || { echo "build/causticos.iso missing — build the kernel first: scripts/run.sh"; exit 1; }

MODE=shell; NOBUILD=0
for a in "$@"; do
    case "$a" in
        wm|shell) MODE="$a";;
        --no-build) NOBUILD=1;;
        *) echo "unknown arg: $a (use 'shell' | 'wm' | '--no-build')"; exit 1;;
    esac
done

[ "$NOBUILD" = "1" ] || bash userspace/build.sh
B=userspace/build
[ -f "$B/shell.cse" ] || { echo "userspace not built — run without --no-build"; exit 1; }

qemu-img create -f raw build/disk.img 64M >/dev/null
mkfs.fat -F 32 -n CAUSTICOS build/disk.img >/dev/null
addf() { [ -f "$B/$2" ] && python3 scripts/fat32_add_file.py build/disk.img addfilebin "$1" "$B/$2" >/dev/null; }

# /netd.cse is not just another tool in the list below: whichever program is
# /init opens it BY THAT NAME at startup and spawns it, and everything the
# session runs gets a channel to it. A disk without it boots to a working
# machine with no network, which is a legitimate state and is reported as one.

if [ "$MODE" = "wm" ]; then
    # /init = the compositor (the launcher); it opens the devices and spawns
    # /wm.cse, handing the device fds down via fdacts. Both must be on the disk.
    addf init.cse compositor.cse
    addf wm.cse wm.cse
    addf launcher.cse launcher.cse
    # The WM's shipped config. /var/wm/config.cst (the user's) is read after it
    # and overrides key by key; /var/wm also holds the saved layout.
    python3 scripts/fat32_add_file.py build/disk.img mkdir etc >/dev/null
    python3 scripts/fat32_add_file.py build/disk.img mkdir var/wm >/dev/null
    python3 scripts/fat32_add_file.py build/disk.img addfilebin etc/wm.cst \
        userspace/wm/wm.default.cst >/dev/null
    PROGS="wmpat wterm newterm btop echo cat ls uptime sysinfo vic guess \
           wc head tail grep rev tac uniq fold cmp seq cut sort hexdump \
           touch mkdir rmdir rm mv cp stat du tree find clear \
           ps free df top pager hexedit date poweroff reboot \
           netd ifconfig ping wget nslookup arp nc httpd netsnoop aplay arecord"
    INITNAME="compositor (launches the window manager — Super+Enter opens a window, Alt+Tab cycles, Super+Q closes)"
else
    addf init.cse shell.cse
    PROGS="echo cat ls uptime sysinfo vic btop ps top free df \
           grep wc sort head tail rev tac cut uniq \
           netd ifconfig ping wget nslookup arp nc httpd netsnoop aplay arecord"
    INITNAME="shell (type 'btop', 'ls', 'help' ...)"
fi
for p in $PROGS; do addf "$p.cse" "$p.cse"; done

# The trust store. https is refused outright without it, which is the right
# answer: a client that cannot check a certificate and connects anyway is worse
# than plain http, because plain http does not claim to be secure. CA_PEM lets
# a test seed its own anchors instead of the machine's.
CA_PEM="${CA_PEM:-/etc/ssl/certs/ca-certificates.crt}"
if [ -f "$CA_PEM" ]; then
    python3 scripts/fat32_add_file.py build/disk.img mkdir etc >/dev/null 2>&1 || true
    python3 scripts/fat32_add_file.py build/disk.img addfilebin etc/ca.pem "$CA_PEM" >/dev/null
fi
python3 scripts/fat32_add_file.py build/disk.img addfile hello.txt \
    "ola do CausticOS! este arquivo veio do disco FAT32 via cat." >/dev/null
echo "seeded build/disk.img -> /init = $INITNAME"
echo "start it:  virsh -c qemu:///session start causticos   (or ▶ in virt-manager, then open the console)"
