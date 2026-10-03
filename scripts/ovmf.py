#!/usr/bin/env python3
"""ovmf.py — the UEFI firmware QEMU boots causticos with.

Prints two lines: the firmware image, and the template its variable store is
copied from (an empty line when the firmware keeps none). Exits 1, naming
every place it looked, when there is no usable firmware.

The answer comes from QEMU's own firmware descriptors (QEMU's
docs/interop/firmware.json): every distribution that packages OVMF installs
one beside it, and so do the Windows and Homebrew builds of QEMU for the copy
they bundle. libvirt reads the same files. Guessing at paths instead means a
list that is wrong on the next distribution, or the next release of this one
— Arch alone moved its OVMF once already.

The firmware must be x86_64 UEFI on a flash device for a q35 machine, and
must not insist on Secure Boot or SMM: causticos is not signed, and the
machine qemu-args.sh defines does not enable SMM. Descriptors are taken in
the spec's order — sorted by file name across the search directories, a name
in an earlier directory hiding the same name in a later one.
"""
import fnmatch
import json
import os
import subprocess
import sys

REFUSE = {"secure-boot", "enrolled-keys", "requires-smm"}


def search_dirs():
    dirs = []
    xdg = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    dirs.append(os.path.join(xdg, "qemu", "firmware"))
    dirs.append("/etc/qemu/firmware")
    dirs.append("/usr/share/qemu/firmware")
    # Wherever this QEMU keeps its data — /usr/local, Homebrew, the Windows
    # install directory — it may keep descriptors for its bundled edk2 too.
    try:
        out = subprocess.run(["qemu-system-x86_64", "-L", "help"],
                             capture_output=True, text=True, timeout=10).stdout
        for line in out.splitlines():
            d = line.strip()
            if d:
                dirs.append(os.path.join(os.path.normpath(d), "firmware"))
    except (OSError, subprocess.SubprocessError):
        pass
    seen = []
    for d in dirs:
        if d not in seen:
            seen.append(d)
    return seen


def descriptors(dirs):
    chosen = {}
    for d in dirs:
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for n in names:
            if n.endswith(".json") and n not in chosen:
                chosen[n] = os.path.join(d, n)
    return [chosen[n] for n in sorted(chosen)]


def q35_machine():
    """The versioned machine `-machine q35` stands for: descriptors name
    versions (pc-q35-*), not the alias."""
    try:
        out = subprocess.run(["qemu-system-x86_64", "-machine", "help"],
                             capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        out = ""
    for line in out.splitlines():
        if line.startswith("q35 ") and "(alias of " in line:
            return line.split("(alias of ", 1)[1].split(")", 1)[0].strip()
    return "pc-q35-"


def fits(desc, machine):
    if "uefi" not in desc.get("interface-types", []):
        return False
    if REFUSE & set(desc.get("features", [])):
        return False
    m = desc.get("mapping", {})
    if m.get("device") != "flash":
        return False
    for t in desc.get("targets", []):
        if t.get("architecture") != "x86_64":
            continue
        if any(fnmatch.fnmatch(machine, pat) for pat in t.get("machines", [])):
            return True
    return False


def main():
    dirs = search_dirs()
    machine = q35_machine()
    for path in descriptors(dirs):
        try:
            with open(path) as f:
                desc = json.load(f)
        except (OSError, ValueError):
            continue
        if not fits(desc, machine):
            continue
        m = desc["mapping"]
        code = m.get("executable", {}).get("filename", "")
        if not code or not os.path.isfile(code):
            continue
        mode = m.get("mode", "split")
        vars_ = ""
        if mode == "split":
            vars_ = m.get("nvram-template", {}).get("filename", "")
            if not vars_ or not os.path.isfile(vars_):
                continue
        elif mode != "stateless":
            continue        # "combined": one writable image; nothing ships it for x86
        print(code)
        print(vars_)
        return 0
    print("ovmf: no x86_64 UEFI firmware for QEMU on this host", file=sys.stderr)
    print("ovmf: looked for descriptors in:", file=sys.stderr)
    for d in dirs:
        print("  " + d, file=sys.stderr)
    print("ovmf: install OVMF (Arch: edk2-ovmf, Debian/Ubuntu: ovmf, Fedora: edk2-ovmf)",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
