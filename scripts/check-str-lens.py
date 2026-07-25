#!/usr/bin/env python3
"""check-str-lens.py — validate every hand-counted string length in the kernel.

Caustic strings carry no length, so a length is a separate literal someone
counted by hand. Two places do it, and both fail in ways that look like
something else:

  - ksym registrations. A driver publishes its callbacks by name so the
    .cdvrspec text can refer to them:

        ksym_bind.name_ptr = cast(*u8, "e1000.e1000_bind");
        ksym_bind.name_len = 16;

    Miscount and the symbol never resolves. The boot says "specparse:
    unresolved ksym" — loud about the failure, silent about the cause.
    Renaming a module gets every one of them wrong at once.

  - serial.print / serial.println. Miscount and the message is silently
    truncated or runs past its end into whatever follows in rodata:

        serial.println("NO RDSEED/RDRAND - jitter pool only", 30);
                                        prints "NO RDSEED/RDRAND - jitter po"

    Non-ASCII is where this bites hardest: an em-dash is one character and
    three bytes, so a correct-looking count is short by two. That is a real
    bug this checker found.

    scripts/check-str-lens.py           # report mismatches, exit 1 if any
    scripts/check-str-lens.py --fix     # rewrite the lengths in place

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

# serial.print("...", N) / serial.println("...", N) / fb.print(...) — a literal
# immediately followed by its own length. Only matches a plain literal: a
# variable or an expression is not something this can check.
SERIAL = re.compile(
    r'(?P<call>(?:serial|fb)\.(?:print|println|print_scaled)\s*\(\s*)'
    r'(?:cast\(\*u8,\s*)?"(?P<text>(?:[^"\\]|\\.)*)"\)?'
    r'\s*,\s*(?P<len>\d+)'
)

# Caustic string escapes, for counting what the literal actually becomes.
ESCAPES = {'n': '\n', 't': '\t', 'r': '\r', '0': '\0', '\\': '\\', '"': '"'}


def literal_bytes(text: str) -> int:
    """Byte length of the string a Caustic literal denotes."""
    out = []
    i = 0
    while i < len(text):
        if text[i] == '\\' and i + 1 < len(text):
            out.append(ESCAPES.get(text[i + 1], text[i + 1]))
            i += 2
        else:
            out.append(text[i])
            i += 1
    return len(''.join(out).encode('utf-8'))


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
        edits = []
        for m in PAIR.finditer(text):
            name = m.group("name")
            registered[name] = path
            edits.append((m.start("len"), m.end("len"), int(m.group("len")),
                          len(name.encode()), f'"{name}"'))
        for m in SERIAL.finditer(text):
            shown = m.group("text")
            if len(shown) > 40:
                shown = shown[:40] + "..."
            edits.append((m.start("len"), m.end("len"), int(m.group("len")),
                          literal_bytes(m.group("text")), f'"{shown}"'))
        edits.sort()

        for (lo, hi, declared, actual, label) in edits:
            if declared == actual:
                continue
            rel = path.relative_to(ROOT)
            line = text.count("\n", 0, lo) + 1
            if fix:
                out.append(text[last:lo])
                out.append(str(actual))
                last = hi
                touched = True
                fixed += 1
                print(f"  fixed {rel}:{line}  {label} {declared} -> {actual}")
            else:
                bad += 1
                print(f"  {rel}:{line}  {label} declares {declared}, is {actual}")
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
        print(f"check-str-lens: fixed {fixed}")
        return 0
    if bad:
        print(f"check-str-lens: {bad} problem(s)")
        return 1
    print(f"check-str-lens: {len(registered)} registrations OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
