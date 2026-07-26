#!/bin/bash
# test-cse-forms.sh — every shape a .cse comes in, loaded by the real loader.
#
# The toolchain emits three, and they are genuinely different files:
#
#   pure    CST_ container at offset 0. What a CausticOS-only build makes.
#   compat  MZ at offset 0 (a Windows PE), a Linux ELF further in, a shell stub
#           that picks one — and the CausticOS body somewhere inside, found
#           through the CST* mini-header at 0x40.
#   bundle  the same polyglot shape with more carried in it.
#
# Only the first was ever exercised. The other two go down a different path in
# kernel/sys/cse.cst — one that parses a header whose layout changed twice
# without this side noticing, so it was reading a body offset out of the middle
# of a shell script and loading whatever was there.
#
# A format with three shapes needs three tests. This runs the same trivial
# program in each form, typed at the real prompt, and each one has to print its
# own name.
#
#   scripts/test-cse-forms.sh
set -e
cd "$(cd "$(dirname "$0")/.." && pwd)"

source "$(dirname "$0")/portable.sh"

CAUSTIC="${CAUSTIC:-$HOME/.local/bin/caustic}"
[ -x "$CAUSTIC" ] || { echo "no caustic at $CAUSTIC"; exit 1; }
[ -f build/causticos.iso ] || { echo "build/causticos.iso missing"; exit 1; }

WORK=build/cse-forms
rm -rf "$WORK"; mkdir -p "$WORK"

# One source, three builds. It uses NOTHING — no imports, no syscalls — and
# reports by its exit code, which the kernel prints on the serial line when the
# process is reaped.
#
# That is forced, not a preference: a polyglot is compiled for Windows and
# Linux as well, so a program that reaches for a CausticOS syscall cannot be
# built in that form at all ("must be portable — no raw syscall()"). The exit
# code costs nothing and is observed by the kernel rather than the program,
# which makes it a better witness anyway: it proves the image was loaded AND
# ran to completion, not merely that something printed.
cat > "$WORK/form.cst" <<'EOF'
fn main() as i32 { return cast(i32, 77); }
EOF

# Prints the built file's path on stdout; everything a person reads goes to
# stderr, so the caller can capture one without the other.
build_form() {
    local name="$1"; shift
    rm -f "$WORK/$name.cse" "$WORK/$name.cse.exe"
    if ! "$CAUSTIC" --target=caustic-x86_64 "$@" "$WORK/form.cst" \
            -o "$WORK/$name.cse" >/tmp/cse-form-$name.log 2>&1; then
        echo "FAIL: building $name" >&2
        tail -5 /tmp/cse-form-$name.log >&2
        exit 1
    fi
    # A polyglot is named .cse.exe on purpose (Windows will not run it without
    # the suffix); the guest does not care what it is called.
    local out="$WORK/$name.cse"
    [ -f "$out" ] || out="$WORK/$name.cse.exe"
    [ -f "$out" ] || { echo "FAIL: $name produced no output" >&2; exit 1; }
    printf '%-8s %-22s offset0=%s\n' "$name" "$(basename "$out")" \
        "$(head -c4 "$out" | tr -c '[:print:]' '.')" >&2
    echo "$out"
}

# The polyglot orchestrator spawns sub-builds whose debug files land in the
# CURRENT directory, not next to -o. Left alone they show up as untracked
# junk in the repo root, which is how build artefacts end up committed.
cleanup_pdb() { rm -f ./*.cse.exe.__cse_*.pdb ./*.__cse_*.pdb; }
trap cleanup_pdb EXIT

echo "=== building the three forms ==="
PURE=$(build_form pure   --extension=cse)
COMPAT=$(build_form compat --mode=compat)
BUNDLE=$(build_form bundle --mode=bundle)

# Its own image, so this test can run beside the others rather than
# fighting them for build/disk.img.
DISK=build/disk-cse-forms.img
"$PY" scripts/mkroot.py --profile shell --img "$DISK" -q \
    --add "$PURE:/fpure.cse" --add "$COMPAT:/fcompat.cse" --add "$BUNDLE:/fbundle.cse"

MON=/tmp/causticos-cseforms-mon.$$
LOG=/tmp/causticos-cseforms.log
QEMU_DISK="$DISK"
QEMU_KVM=1
QEMU_HTTPD_PORT="${QEMU_HTTPD_PORT:-18086}"
source scripts/qemu-args.sh

qemu-system-x86_64 "${QEMU_ARGS[@]}" \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio -display none > "$LOG" 2>&1 &
QPID=$!
mon() { printf '%s\n' "$1" | socat - "unix-connect:$MON" >/dev/null 2>&1 || true; }
cleanup() {
    kill -9 $QPID 2>/dev/null || true; wait $QPID 2>/dev/null || true
    rm -f "$MON"
    cleanup_pdb
}
trap cleanup EXIT

for _ in $(seq 1 400); do
    tr -d '\000' < "$LOG" | grep -q "shell: ready" && break
    kill -0 $QPID 2>/dev/null || break
    sleep 0.1
done

key_of() {
    case "$1" in
        [a-z0-9]) printf '%s' "$1" ;;
        ' ') printf 'spc' ;; '-') printf 'minus' ;;
        '/') printf 'slash' ;; '.') printf 'dot' ;;
        *) echo "no key name for '$1'" >&2; exit 1 ;;
    esac
}
type_line() {
    local i K
    for (( i=0; i<${#1}; i++ )); do K=$(key_of "${1:$i:1}"); mon "sendkey $K"; done
    mon "sendkey ret"
}

FAILED=0
for form in pure compat bundle; do
    BEFORE=$(tr -d '\000' < "$LOG" | grep -c "sys.proc_exit: code=77" || true)
    ERRB=$(tr -d '\000' < "$LOG" | grep -c "^cse: " || true)
    # The shell appends ".cse" itself — it resolves a bare name to
    # /<name>.cse — so typing the suffix would ask for "fpure.cse.cse".
    echo "typing: f$form"
    type_line "f$form"
    OK=0
    for _ in $(seq 1 150); do
        NOW=$(tr -d '\000' < "$LOG" | grep -c "sys.proc_exit: code=77" || true)
        if [ "$NOW" -gt "$BEFORE" ]; then OK=1; break; fi
        kill -0 $QPID 2>/dev/null || break
        sleep 0.1
    done
    ERRA=$(tr -d '\000' < "$LOG" | grep -c "^cse: " || true)
    if [ "$OK" = 1 ] && [ "$ERRA" = "$ERRB" ]; then
        echo "  ok   $form loaded and ran to completion"
    else
        echo "  FAIL $form did not run"
        tr -d '\000' < "$LOG" | grep -E "^cse: |spawn" | tail -3
        FAILED=1
    fi
done

if [ "$FAILED" != 0 ]; then
    echo "=== cse-forms: FAIL (log: $LOG) ==="
    exit 1
fi
echo "=== cse-forms: PASS (pure, compat and bundle all load) ==="
