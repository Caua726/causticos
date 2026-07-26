#!/usr/bin/env bash
source "$(dirname "$0")/portable.sh"
# libvirt.sh — build the system and boot it as a libvirt domain, under virt-manager.
#
#   caustic-mk run libvirt
#
# ONE command from an edited source file to a running desktop: it builds the
# kernel, builds the userspace, packs the ISO, redefines the domain and starts
# it. Everything downstream of a source change is stale by definition, so nothing
# here is opt-in — `--no-build` is how you say "boot what is already there", and
# it is the exception rather than the normal path.
#
# Same machine as `caustic-mk run run`, hosted by libvirtd instead of a bare
# QEMU process. Two things that buys, and they are the whole reason this exists:
#
#   * SPICE. QEMU's own GTK window does not open under native Wayland; the
#     virt-viewer/virt-manager console does, and its virtio-tablet pointer needs
#     no grab, so the window manager is usable with a mouse.
#   * A VM that outlives the shell. Close the terminal and the guest keeps
#     running; reattach with virt-manager whenever.
#
# The order is load-bearing: BUILD, then stop the domain, then define, then
# start. Build first because a failed build must leave the VM you are looking at
# alone rather than killing it for nothing; stop before touching build/disk.img
# because a running domain holds a write lock on it; redefine every time because
# a running domain pins the ISO *file* it was started with, and without a
# redefine this would cheerfully show you the previous build.
#
# qemu:///session, not qemu:///system — the session daemon runs as you and reads
# build/ with no permission or AppArmor argument. It is also why this needs no
# root.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$(pwd)"

NAME="causticos"
MEM=64M
SMP=2
ACCEL_WANT=tcg
PERSIST=""
RESEED=0
ISO="build/causticos.iso"
ISO_GIVEN=0
BUILD=1
BUILD_GIVEN=0
PROFILE="${COS_PROFILE:-desktop}"
CMDLINE=""
VIEWER=auto        # auto | console | none
ACTION=start       # start | define | stop

usage() {
    cat <<'EOF'
usage: caustic-mk run libvirt -- [options]

Builds kernel + userspace + ISO, then defines and starts the domain.

  --no-build          skip the build; boot the ISO that is already there
  --profile NAME      which programs the root image ships (default desktop)
  --cmdline "..."     bake a kernel command line into the ISO
  --persist[=PATH]    attach a FAT32 disk on SATA port 0 (default build/disk.img,
                      created from the current profile if it does not exist)
  --reseed            rebuild that disk from the current profile even if it exists
  -m SIZE             guest memory (default 64M)
  --smp N             cpu count (default 2)
  --kvm               use hardware virtualisation when the host has it
                      (default is TCG emulation, which works everywhere)
  --iso PATH          boot a different ISO; implies --no-build
  --name NAME         libvirt domain name (default causticos)
  --console           serial on this terminal (virsh console) instead of a window
  --no-viewer         start it and return; attach with virt-manager later
  --define-only       build and define the domain, do not start it
  --stop              destroy the running domain and exit (builds nothing)

The connection is $LIBVIRT_DEFAULT_URI, or qemu:///session when unset. The
rendered domain is written to build/causticos.libvirt.xml — read it when you want
to know exactly what was defined.

The kernel command line goes into the ISO at build time, not onto a QEMU
argument: -append only reaches a kernel loaded with -kernel, and this one is
loaded by Limine. That is what --cmdline above is for.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) BUILD=0; BUILD_GIVEN=1; shift ;;
        --build) BUILD=1; BUILD_GIVEN=1; shift ;;
        --profile) PROFILE="$2"; shift 2 ;;
        --profile=*) PROFILE="${1#*=}"; shift ;;
        --cmdline) CMDLINE="$2"; shift 2 ;;
        --persist) PERSIST="build/disk.img"; shift ;;
        --persist=*) PERSIST="${1#*=}"; shift ;;
        --reseed) RESEED=1; [ -n "$PERSIST" ] || PERSIST="build/disk.img"; shift ;;
        -m) MEM="$2"; shift 2 ;;
        --smp) SMP="$2"; shift 2 ;;
        --kvm) ACCEL_WANT=auto; shift ;;
        --no-kvm) ACCEL_WANT=tcg; shift ;;
        --iso) ISO="$2"; ISO_GIVEN=1; shift 2 ;;
        --name) NAME="$2"; shift 2 ;;
        --console) VIEWER=console; shift ;;
        --no-viewer) VIEWER=none; shift ;;
        --define-only) ACTION=define; shift ;;
        --stop) ACTION=stop; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "libvirt: unknown option '$1' (try --help)" >&2; exit 1 ;;
    esac
done

# ── The connection ───────────────────────────────────────────────────

command -v virsh >/dev/null 2>&1 || {
    echo "libvirt: virsh not found — install libvirt (Arch: pacman -S libvirt virt-viewer)" >&2
    exit 1
}

export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///session}"

# The session daemon is socket-activated, so "not running" usually means the
# socket was never enabled rather than anything being broken. Say which.
if ! virsh version >/dev/null 2>&1; then
    echo "libvirt: cannot reach $LIBVIRT_DEFAULT_URI" >&2
    echo "         start the user daemon:  systemctl --user start virtqemud.socket" >&2
    echo "         (older libvirt: libvirtd.socket)" >&2
    exit 1
fi

# LC_ALL=C on this one call and no further: virsh TRANSLATES domstate, so on a
# pt-BR host the answer is "executando" and a comparison against "running" is
# quietly always false — which means never stopping a running domain, and then
# redefining one that keeps showing the previous ISO. The locale is left alone
# everywhere else so the viewer still comes up in the user's language.
running() { [ "$(LC_ALL=C virsh domstate "$NAME" 2>/dev/null || true)" = "running" ]; }

if [ "$ACTION" = stop ]; then
    if running; then
        virsh destroy "$NAME" >/dev/null
        echo "libvirt: $NAME stopped"
    else
        echo "libvirt: $NAME is not running"
    fi
    exit 0
fi

# ── Build ────────────────────────────────────────────────────────────

# Naming an ISO means booting THAT file, so building one over it would be the
# opposite of what was asked. Explicit --build still wins.
if [ "$ISO_GIVEN" = 1 ] && [ "$BUILD_GIVEN" = 0 ]; then
    BUILD=0
fi

if [ "$BUILD" = 1 ]; then
    source "$(dirname "$0")/rebuild.sh"
    cos_rebuild "$PROFILE" "$CMDLINE"
fi

# ── What it boots ────────────────────────────────────────────────────

[ -f "$ISO" ] || { echo "libvirt: $ISO missing — run 'caustic-mk run build'" >&2; exit 1; }

# Stopped BEFORE the disk work, not after: a running domain holds a write lock on
# build/disk.img, and reseeding underneath it would either fail or hand the guest
# a volume that changed while it was mounted.
if running; then
    echo "libvirt: $NAME was running — stopping it to boot what is built now"
    virsh destroy "$NAME" >/dev/null
fi

if [ -n "$PERSIST" ]; then
    if [ "$RESEED" = 1 ] && [ -f "$PERSIST" ]; then
        echo "libvirt: reseeding $PERSIST from profile $PROFILE"
        rm -f "$PERSIST"
    fi
    if [ ! -f "$PERSIST" ]; then
        [ "$RESEED" = 1 ] || echo "libvirt: $PERSIST does not exist — creating it from profile $PROFILE"
        "$PY" scripts/mkroot.py --profile "$PROFILE" --img "$PERSIST" -q
    fi
fi

# TCG by default, on every host, for the same reason `run` does it: the same
# command does the same thing everywhere, with no /dev/kvm and no group
# membership. Emulation costs about 20% of boot time here — measured, 3.4s to a
# ready desktop against 2.8s. --kvm asks for that 20% back.
DOMTYPE=qemu
if [ "$ACCEL_WANT" = auto ]; then
    if [ -w /dev/kvm ]; then
        DOMTYPE=kvm
    else
        echo "libvirt: --kvm asked for, but /dev/kvm is not writable — using TCG" >&2
        echo "         (fix: usermod -aG kvm \$USER, then log in again)" >&2
    fi
fi

# libvirt wants MiB as a bare number; the flags speak QEMU's spelling.
mem_mib() {
    case "$1" in
        *[Gg]) echo $(( ${1%[Gg]} * 1024 )) ;;
        *[Mm]) echo "${1%[Mm]}" ;;
        *[Kk]) echo $(( ${1%[Kk]} / 1024 )) ;;
        *) echo "$1" ;;
    esac
}
MEM_MIB="$(mem_mib "$MEM")"

# ── The domain ───────────────────────────────────────────────────────

TEMPLATE="causticos.libvirt.xml"
OUT="build/causticos.libvirt.xml"
[ -f "$TEMPLATE" ] || { echo "libvirt: $TEMPLATE missing from the checkout" >&2; exit 1; }

# libvirt resolves nothing relative to a working directory, so every path in the
# domain is absolutised here.
abspath() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$REPO" "${1#./}" ;; esac; }
ISO_ABS="$(abspath "$ISO")"
DISK_ABS="$([ -n "$PERSIST" ] && abspath "$PERSIST" || echo "")"

# Redefining an existing domain means carrying its UUID: libvirt generates a
# fresh one for an XML that omits it, then refuses the definition because a
# domain of that name already holds a different one. Absent (first run), the
# placeholder line goes away and libvirt assigns one.
UUID="$(virsh domuuid "$NAME" 2>/dev/null | tr -d '[:space:]' || true)"
if [ -n "$UUID" ]; then UUID_EL="<uuid>$UUID</uuid>"; else UUID_EL=""; fi

# Substituted with bash's own expansion rather than sed, so a $HOME containing
# an ampersand or a slash-heavy path needs no escaping dance.
XML="$(cat "$TEMPLATE")"
XML="${XML//@UUID@/$UUID_EL}"
XML="${XML//@NAME@/$NAME}"
XML="${XML//@DOMTYPE@/$DOMTYPE}"
XML="${XML//@MEM@/$MEM_MIB}"
XML="${XML//@SMP@/$SMP}"
XML="${XML//@ISO@/$ISO_ABS}"
XML="${XML//@DISK@/$DISK_ABS}"

# No disk unless asked for. A stray volume on the bus is one more thing to
# explain when a boot misbehaves, and libvirt refuses to start a domain whose
# disk file is missing — so leaving the block in "just in case" would break the
# default path outright.
if [ -z "$PERSIST" ]; then
    XML="$(printf '%s\n' "$XML" | awk '/@DISK_BEGIN@/{skip=1} !skip; /@DISK_END@/{skip=0}')"
fi

mkdir -p build
printf '%s\n' "$XML" > "$OUT"

virsh define "$OUT" >/dev/null
echo "libvirt: defined $NAME on $LIBVIRT_DEFAULT_URI ($OUT)"

if [ -n "$PERSIST" ]; then
    echo "libvirt: ${MEM_MIB}M ram, ${SMP} cpu, type=${DOMTYPE}, disk = $PERSIST"
else
    echo "libvirt: ${MEM_MIB}M ram, ${SMP} cpu, type=${DOMTYPE}, root = live (no disk attached)"
fi

if [ "$ACTION" = define ]; then
    echo "libvirt: not started (--define-only). Start it: virsh start $NAME"
    exit 0
fi

virsh start "$NAME" >/dev/null
echo "libvirt: $NAME started"

case "$VIEWER" in
    none)
        echo "libvirt: attach with 'virt-manager' or 'virt-viewer $NAME'; serial: 'virsh console $NAME'"
        ;;
    console)
        # Attaching AFTER the start loses nothing: QEMU's pty holds the early
        # output until something reads it, and the first line off the wire
        # ("causticos v0.0.2") is measurably still there. No sleep needed here,
        # and a sleep would not be a fix if it were.
        echo "libvirt: serial console — Ctrl+] to detach (the guest keeps running)"
        exec virsh console "$NAME"
        ;;
    auto)
        if command -v virt-viewer >/dev/null 2>&1; then
            # --reconnect so the window survives a guest reboot rather than
            # closing the moment the display goes away.
            exec virt-viewer --wait --reconnect "$NAME"
        elif command -v virt-manager >/dev/null 2>&1; then
            exec virt-manager --connect "$LIBVIRT_DEFAULT_URI" --show-domain-console "$NAME"
        else
            echo "libvirt: no viewer installed (Arch: pacman -S virt-viewer)." >&2
            echo "         it is running — serial: 'virsh console $NAME'" >&2
        fi
        ;;
esac
