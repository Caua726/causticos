#!/usr/bin/env python3
"""mksym.py — the kernel's symbol table, as a boot module.

    scripts/mksym.py build/kernel.elf.map build/iso/boot/kernel.sym

The kernel is linked stripped (Limine mishandles an embedded symtab — see the
Causticfile), so on its own it knows the names of only the handful of driver
callbacks that register themselves for the spec parser. A fault in any other
function was reported as the nearest of those below it: a null write in main's
test thread came out as "near=ahci.ahci_irq+0x57a9d", 360 KB away.

The linker map has every function. This turns it into a table the kernel can
search, and mkiso.sh ships it beside the kernel as a Limine module. Ordinary
data, not part of the kernel image: generating it cannot move a single address,
so there is no second link.

Format (little endian), all offsets from the start of the file:

    0   "CKSYMTAB"
    8   u64 version (1)
    16  u64 count
    24  u64 text_end   first address past the last function
    32  count x { u64 addr, u32 name_off, u32 name_len }, sorted by addr
    ..  the names, back to back (name_off is from the start of the file)

Names are written the way the source spells them: `sched.schedule`, not
`_kernel_task_sched_cst_schedule`. Plain labels (asm, and main.cst, whose
functions are not mangled) keep theirs.
"""
import struct
import sys

MAGIC = b"CKSYMTAB"
VERSION = 1
# kernel/<dir>/<module>.cst mangles to _kernel_<dir>_<module>_cst_<name>.
KERNEL_DIRS = ("arch", "time", "mm", "task", "drivers", "fs", "ipc", "sys", "lib", "test")


def pretty(mangled):
    if "_cst_" not in mangled:
        return mangled
    path, name = mangled.split("_cst_", 1)
    path = path.lstrip("_")
    if path.startswith("kernel_"):
        path = path[len("kernel_"):]
        for d in KERNEL_DIRS:
            if path.startswith(d + "_"):
                path = path[len(d) + 1:]
                break
    elif path.startswith("font_"):
        path = path[len("font_"):]
    return path + "." + name


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: mksym.py <kernel.elf.map> <out.sym>")
    funcs = []
    data_lo = None
    with open(sys.argv[1]) as f:
        for line in f:
            p = line.split()
            if len(p) < 3 or not p[0].startswith("0x"):
                continue
            addr, kind, name = int(p[0], 16), p[1], p[2]
            if kind in ("D", "B"):
                data_lo = addr if data_lo is None else min(data_lo, addr)
            elif kind == "T":
                funcs.append((addr, name))
    if not funcs or data_lo is None:
        sys.exit("mksym: no functions or no data in the map — is it a kernel map?")
    # Section markers (__start_x/__stop_x) are labels into data that the map
    # calls T; anything at or past the first data symbol is not a function.
    # Two labels at one address (the image's _start and the first function)
    # sort the dotted, source-spelled name last, and the kernel's search takes
    # the last match: a fault there names the function.
    funcs = sorted(((a, pretty(n)) for a, n in funcs
                    if a < data_lo and not n.startswith(("__start_", "__stop_"))),
                   key=lambda e: (e[0], "." in e[1], e[1]))
    names = bytearray()
    entries = bytearray()
    hdr = 32
    base = hdr + 16 * len(funcs)
    for addr, name in funcs:
        b = name.encode()
        entries += struct.pack("<QII", addr, base + len(names), len(b))
        names += b
    out = MAGIC + struct.pack("<QQQ", VERSION, len(funcs), data_lo) + entries + names
    with open(sys.argv[2], "wb") as f:
        f.write(out)


if __name__ == "__main__":
    main()
