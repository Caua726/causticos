#!/usr/bin/env bash
# runall must report a delayed child's actual nonzero exit, not a timeout's zero.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/portable.sh

WORK=$(mktemp -d "${TMPDIR:-/tmp}/causticos-runall.XXXXXX")
KEEP="${KEEP:-0}"
QPID=''
cleanup() {
    if [[ -n "$QPID" ]]; then
        kill -9 "$QPID" 2>/dev/null || true
        wait "$QPID" 2>/dev/null || true
    fi
    if [[ "$KEEP" = 0 ]]; then rm -rf "$WORK";
    else echo "runallwait: artifacts kept in $WORK"; fi
}
trap cleanup EXIT

caustic -q --target=caustic-x86_64 userspace/tests/runall_wait_child.cst -o "$WORK/slow.cse"
"$PY" scripts/mkroot.py --profile base --init runall --img "$WORK/root.img" \
    --add "$WORK/slow.cse:/u64t.cse" -q
ISO="${ROOTED_ISO:-$WORK/test.iso}"
if [[ -z "${ROOTED_ISO:-}" ]]; then
    bash scripts/mkiso.sh --cmdline 'root=ahci-p0' --out "$ISO" >/dev/null
fi
QEMU_ISO="$ISO"
QEMU_DISK="$WORK/root.img"
QEMU_MEM=64M
QEMU_SMP=1
QEMU_ACCEL="${QEMU_ACCEL:-$(qemu_accel)}"
QEMU_HTTPD_PORT=18993
source scripts/qemu-args.sh
qemu-system-x86_64 "${QEMU_ARGS[@]}" -serial stdio -display none > "$WORK/serial.log" 2>&1 &
QPID=$!
DEADLINE=$((SECONDS + ${TOUT:-20}))
while kill -0 "$QPID" 2>/dev/null && (( SECONDS < DEADLINE )); do
    if grep -q 'runall: DONE' "$WORK/serial.log" \
        && grep -q 'sys.proc_exit: code=1' "$WORK/serial.log"; then break; fi
    sleep .1
done
if ! grep -q '^runall: <<< u64t exit=23[[:space:]]*$' "$WORK/serial.log" \
    || ! grep -q '^runall: 1 ran, 1 failed[[:space:]]*$' "$WORK/serial.log" \
    || ! grep -q '^sys.proc_exit: code=1[[:space:]]*$' "$WORK/serial.log"; then
    KEEP=1
    echo 'FAIL: runall did not collect and report the delayed nonzero exit'
    cat "$WORK/serial.log"
    exit 1
fi
echo '=== runallwait: PASS (delayed exit 23; runner exits 1) ==='
