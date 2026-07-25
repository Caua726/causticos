#!/usr/bin/env python3
"""check-ksym-lens.py — validate the hand-counted lengths in ksym registrations.

A driver publishes its callbacks by name so the .cdvrspec text can refer to
them, and the name arrives as a (pointer, length) pair the author counted by
hand:

    ksym_bind.name_ptr = cast(*u8, "e1000.e1000_bind");
    ksym_bind.name_len = 16;

Get the count wrong and the symbol never resolves. The boot message is
"specparse: unresolved ksym" — loud about the failure, silent about the cause,
and the cause is always this. Renaming a module (pcitest -> e1000) changes
every one of these at once, which is exactly when it happens.

    scripts/check-ksym-lens.py           # report mismatches, exit 1 if any
    scripts/check-ksym-lens.py --fix     # rewrite the lengths in place

Also checks the other direction: every name a .cdvrspec references must be
registered by some .cst, and vice versa. An unreferenced ksym is dead weight;
a referenced-but-unregistered one is a boot failure waiting for that device to
appear in a machine.
"""

import re
import sys
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent

# name_ptr and its name_len, in that order, possibly with the struct field
# prefix differing in whitespace. The pair is always adjacent in practice.
PAIR = re.compile(
    r'(?P<lhs>[A-Za-z0-9_]+)\.name_ptr\s*=\s*cast\(\*u8,\s*"(?P<name>[^"]*)"\)\s*;'
    r'(?P<between>\s*)'
    r'(?P=lhs)\.name_len\s*=\s*(?P<len>\d+)\s*;'
)

# A .cdvrspec refers to callbacks as `key: module.fn` inside lifecycle /
# device / implements blocks. Bare keys (bus: pci, irq: auto) have no dot.
SPEC_REF = re.compile(r'^\s*[a-z_]+\s*:\s*([A-Za-z0-9_]+\.[A-Za-z0-9_]+)\s*$', re.M)


def main() -> int:
    fix = "--fix" in sys.argv
    bad = 0
    fixed = 0
    registered: dict[str, pathlib.Path] = {}

    for path in sorted(ROOT.glob("kernel/**/*.cst")):
        text = path.read_text()
        out = []
        last = 0
        touched = False
        for m in PAIR.finditer(text):
            name = m.group("name")
            declared = int(m.group("len"))
            actual = len(name.encode())
            registered[name] = path
            if declared == actual:
                continue
            rel = path.relative_to(ROOT)
            line = text.count("\n", 0, m.start()) + 1
            if fix:
                out.append(text[last:m.start("len")])
                out.append(str(actual))
                last = m.end("len")
                touched = True
                fixed += 1
                print(f"  fixed {rel}:{line}  \"{name}\" {declared} -> {actual}")
            else:
                bad += 1
                print(f"  {rel}:{line}  \"{name}\" declares {declared}, is {actual}")
        if touched:
            out.append(text[last:])
            path.write_text("".join(out))

    # Cross-check against what the driver specs actually ask for.
    referenced: dict[str, pathlib.Path] = {}
    for path in sorted(ROOT.glob("kernel/**/*.cdvrspec")):
        for ref in SPEC_REF.findall(path.read_text()):
            referenced[ref] = path

    for name, path in sorted(referenced.items()):
        if name not in registered:
            rel = path.relative_to(ROOT)
            print(f"  {rel}: references '{name}', which no .cst registers")
            bad += 1

    unused = sorted(set(registered) - set(referenced))
    if unused:
        # Not an error: several are called through ksym.lookup by other kernel
        # code rather than named in a spec. Worth printing so a genuinely dead
        # one is visible.
        print(f"  note: {len(unused)} registered but not named by any spec: "
              + ", ".join(unused))

    if fix:
        print(f"check-ksym-lens: fixed {fixed}")
        return 0
    if bad:
        print(f"check-ksym-lens: {bad} problem(s)")
        return 1
    print(f"check-ksym-lens: {len(registered)} registrations OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
