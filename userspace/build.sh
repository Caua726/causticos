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

# A .cse output is named ".cse" or ".cse.<ext>", and the default <ext> is "exe"
# so the polyglot form runs on Windows by double-click. Nothing here is a
# polyglot — these are CausticOS programs the kernel loads by name from a FAT32
# image — so ask for the plain suffix. Older compilers do not know the flag and
# already produced ".cse", so it is only passed when it is understood.
# Probed by asking the compiler to parse it with no input: a compiler that
# knows the flag complains about the missing file, one that does not complains
# about the flag. Probing with --version does not work — the driver rejects
# the unknown option before it ever gets there.
CSEEXT=""
if ! "$CAUSTIC" --extension=cse 2>&1 | grep -q "unknown option"; then
    CSEEXT="--extension=cse"
fi

OUT="$HERE/build"; mkdir -p "$OUT"
cd "$OUT"; rm -rf .caustic            # the module cache lands in cwd

# No --stack-size: term.cst's putc is recursive (tab → spaces), but the compiler
# now grows recursive programs' stacks on demand (dynamic-stack), so no program
# declares one — non-recursive ones still get an exact computed stack.
#   core: the shell, the window manager + clients, and the original demos.
#   file/text tools (category C): share userspace/futil.cst.
PROGS="shell echo cat ls uptime sysinfo vic compositor wm wmpat wterm newterm launcher guess"
PROGS="$PROGS tr wc head tail grep rev tac uniq fold cmp seq cut sort hexdump"
PROGS="$PROGS tee true false yes comm paste nl basename dirname expand unexpand"
PROGS="$PROGS nproc sleep expr base64 md5sum poweroff reboot"
PROGS="$PROGS sed"
PROGS="$PROGS diff date"
PROGS="$PROGS diff"
PROGS="$PROGS touch mkdir rmdir rm mv cp stat du tree find clear"
#   monitors (category D): read SYS_PROC_LIST / SYS_MEM_INFO / SYS_STATFS.
#   ("kill" is Ctrl+C in the terminal — the wterm is the job's parent and holds
#   the kill authority; CausticOS has no ambient pid namespace for a standalone
#   kill tool to use.)
PROGS="$PROGS ps free df top btop htop lscpu ifconfig ping netd wget"
PROGS="$PROGS nslookup arp nc httpd netsnoop"
#   audio (category G): aplay writes PCM straight at DEV_AUDIO_OUT — the
#   direct path, which is also what proves the grab stack on the new class.
PROGS="$PROGS aplay"
#   compiler front-ends (category F): spawn the embedded /caustic.cse. run +
#   cc + make compile; objdump inspects a .cse. (caustic-as / caustic-ld are
#   built separately by scripts/build-tools.sh.)
PROGS="$PROGS run cc make objdump"
#   viewers/editors (category E): full-screen, drawing through the framebuffer
#   grab stack (the WM yields while they run), like vic.
PROGS="$PROGS pager hexedit"
#   lib self-tests: run in the shell, print PASS/FAIL. Building them here keeps
#   a library honest even before its first consumer lands.
PROGS="$PROGS animt kabi u64t nett pingt linkt netdt tcpt httpt cryptot x509t tlst appt"
for p in $PROGS; do
    # programs live in subfolders (coreutils/ sysutils/ wm/ ...); find by name.
    src=$(find "$HERE" -name "$p.cst" -not -path '*/build/*' | head -1)
    [ -n "$src" ] || { echo "FAIL: no source file named $p.cst"; exit 1; }
    rm -f "$OUT/$p.cse" "$OUT/$p.cse.exe"
    if ! "$CAUSTIC" $CSEEXT --target=caustic-x86_64 "$src" -o "$OUT/$p.cse" >/dev/null 2>&1; then
        echo "FAIL building $p:"; "$CAUSTIC" $CSEEXT --target=caustic-x86_64 "$src" -o "$OUT/$p.cse"; exit 1
    fi
    # The output has to EXIST, and it has to be the one that was just made.
    # It used to be enough for the compiler to exit 0, and the size line came
    # from stat — so when a compiler stopped writing $p.cse and started writing
    # $p.cse.exe, every program kept "building" at the size of the stale file
    # left over from the last good build. Nothing was rebuilt for as long as
    # that lasted, and the only visible symptom was one new program with no
    # stale file to fall back on.
    if [ ! -f "$OUT/$p.cse" ]; then
        if [ -f "$OUT/$p.cse.exe" ]; then
            echo "FAIL: $CAUSTIC wrote $p.cse.exe instead of $p.cse."
            echo "      The compiler's output-extension convention changed under this script."
        else
            echo "FAIL: $CAUSTIC exited 0 and produced no $p.cse"
        fi
        exit 1
    fi
    printf "  %-10s %s\n" "$p.cse" "$(stat -c%s "$OUT/$p.cse")b"
done
cp "$OUT/shell.cse" "$OUT/init.cse"   # the shell is /init
echo "userspace built -> $OUT  (init.cse = shell)"
