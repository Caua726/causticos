#!/bin/bash
# build-tools.sh — compile the standalone assembler + linker to CSE so the OS
# ships the full toolchain (caustic + caustic-as + caustic-ld), Unix-style.
#
# The CANONICAL binaries come out of the VM: once the bootstrap has produced a
# converged caustic.cse, compile the tools ON CausticOS with it (the same way
# run-bootstrap.sh produces the compiler) and lift the .cse off the disk. This
# host cross-build is the development shortcut. NOTE: the assembler/linker pull
# in std/mem, so they need a compiler whose std defines everything they use —
# build them with the same compiler that built the current compiler.
#
# Output: build/caustic-as.cse, build/caustic-ld.cse
set -e
cd "$(dirname "$0")/.."
CAUSTIC_DIR="${CAUSTIC_DIR:-$(cd ../Caustic && pwd)}"
C="$CAUSTIC_DIR/caustic"
[ -x "$C" ] || { echo "caustic not found at $C — set CAUSTIC_DIR"; exit 1; }
mkdir -p build

echo "==> caustic-as.cse (assembler)"
( cd build && rm -rf .caustic && "$C" --target=caustic-x86_64 "$CAUSTIC_DIR/caustic-assembler/main.cst" -o caustic-as.cse >/dev/null )
echo "==> caustic-ld.cse (linker)"
( cd build && rm -rf .caustic && "$C" --target=caustic-x86_64 "$CAUSTIC_DIR/caustic-linker/main.cst" -o caustic-ld.cse >/dev/null )

echo "toolchain: caustic-as.cse $(stat -c%s build/caustic-as.cse)b, caustic-ld.cse $(stat -c%s build/caustic-ld.cse)b"
