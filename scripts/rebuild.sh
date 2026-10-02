# rebuild.sh — "make what we are about to boot current", in one place.
#
# Sourced by the two scripts that boot the system: scripts/qemu.sh (`run`) and
# scripts/libvirt.sh (`libvirt`). Both build first and boot second, and they do
# it identically because they call the same function — the alternative was two
# copies of the same six lines, and the copy is always the one that drifts.
#
# Usage — parse the flags, then:
#
#     source "$(dirname "$0")/rebuild.sh"
#     cos_rebuild "$PROFILE" "$CMDLINE"
#
# WHY booting rebuilds at all: everything downstream of an edited source file is
# stale by definition, and a boot that silently shows the previous build is the
# most expensive kind of wrong answer — you debug the symptom of a fix you did
# not actually run. The build is incremental and costs about two seconds when
# nothing changed, which is cheaper than noticing the mistake even once.
#
# `--no-build` is the escape hatch, for booting an image you deliberately did not
# just build. Naming an ISO with `--iso` implies it.
#
# Delegated to `caustic-mk run build` rather than spelled out here: the build is
# three steps (kernel, userspace, ISO) and the Causticfile declares them once.

# cos_rebuild <profile> [cmdline]
cos_rebuild() {
    local profile="$1" cmdline="${2:-}"
    local args=(--profile "$profile")
    [ -n "$cmdline" ] && args+=(--cmdline "$cmdline")
    echo "build: kernel + userspace + iso (profile $profile)"
    caustic-mk run build -- "${args[@]}"
}

# cos_persist_iso <out> [cmdline]
#
# The ISO a disk-rooted boot needs: the same kernel and bootloader, and NO live
# root. The live root outranks every disk (root_pick prefers the module), so
# booting the ordinary ISO with a disk attached mounts the RAM copy and leaves
# the disk untouched — which is what `--persist` used to do while announcing
# "persistent". This is packaging only, from what is already built, so it runs
# even under --no-build; and qemu.sh, libvirt.sh and verify.sh all go through
# it, so the boot a user gets and the boot the suite checks are the same image.
cos_persist_iso() {
    local out="$1" cmdline="${2:-}"
    local args=(--no-live --out "$out")
    [ -n "$cmdline" ] && args+=(--cmdline "$cmdline")
    bash "$(dirname "${BASH_SOURCE[0]}")/mkiso.sh" "${args[@]}" >/dev/null
}
