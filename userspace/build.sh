#!/bin/bash
# build.sh — compile the CausticOS userspace programs to .cse.
#
# These are CausticOS programs (the shell + its tools), written in Caustic. They
# import the Caustic stdlib facades (std/causticos/*, std/os/causticos.cst) from
# the sibling Caustic compiler repo via ../../Caustic/std/... — so the compiler
# is found relative to here, or via $CAUSTIC_DIR. Output: ./build/<name>.cse,
# with init.cse = the shell (what the kernel launches as /init).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
CAUSTIC_DIR="${CAUSTIC_DIR:-$(cd "$HERE/../../Caustic" 2>/dev/null && pwd)}"
CAUSTIC="$CAUSTIC_DIR/caustic"
[ -x "$CAUSTIC" ] || { echo "caustic not found at '$CAUSTIC' — set CAUSTIC_DIR"; exit 1; }

OUT="$HERE/build"; mkdir -p "$OUT"
cd "$OUT"; rm -rf .caustic            # the module cache lands in cwd

# No --stack-size: term.cst's putc is recursive (tab → spaces), but the compiler
# now grows recursive programs' stacks on demand (dynamic-stack), so no program
# declares one — non-recursive ones still get an exact computed stack.
#   core: the shell, the window manager + clients, and the original demos.
#   file/text tools (category C): share userspace/futil.cst.
PROGS="shell echo cat ls uptime sysinfo vic wm wmpat wterm newterm guess"
PROGS="$PROGS tr wc head tail grep rev tac uniq fold cmp seq cut sort hexdump"
PROGS="$PROGS tee true false yes comm paste nl basename dirname expand unexpand"
PROGS="$PROGS nproc sleep expr base64 md5sum"
PROGS="$PROGS touch mkdir rmdir rm mv cp stat du tree find clear"
#   monitors (category D): read SYS_PROC_LIST / SYS_MEM_INFO / SYS_STATFS.
#   ("kill" is Ctrl+C in the terminal — the wterm is the job's parent and holds
#   the kill authority; CausticOS has no ambient pid namespace for a standalone
#   kill tool to use.)
PROGS="$PROGS ps free df top btop htop"
#   compiler front-ends (category F): spawn the embedded /caustic.cse. run +
#   cc + make compile; objdump inspects a .cse. (caustic-as / caustic-ld are
#   built separately by scripts/build-tools.sh.)
PROGS="$PROGS run cc make objdump"
#   viewers/editors (category E): full-screen, drawing through the framebuffer
#   grab stack (the WM yields while they run), like vic.
PROGS="$PROGS pager hexedit"
for p in $PROGS; do
    if ! "$CAUSTIC" --target=caustic-x86_64 "$HERE/$p.cst" -o "$OUT/$p.cse" >/dev/null 2>&1; then
        echo "FAIL building $p:"; "$CAUSTIC" --target=caustic-x86_64 "$HERE/$p.cst" -o "$OUT/$p.cse"; exit 1
    fi
    printf "  %-10s %s\n" "$p.cse" "$(stat -c%s "$OUT/$p.cse")b"
done
cp "$OUT/shell.cse" "$OUT/init.cse"   # the shell is /init
echo "userspace built -> $OUT  (init.cse = shell)"
