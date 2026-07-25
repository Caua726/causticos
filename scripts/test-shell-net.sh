#!/bin/bash
# test-shell-net.sh — type wget at the real shell prompt and check what lands
# on the disk.
#
# Every other network test spawns netd itself and hands the child a channel by
# hand. That proves the mechanism and says nothing about whether the machine
# you actually boot is wired up: /init has to start netd, the shell has to mint
# an endpoint per command, and the endpoint has to arrive on the fd the program
# looks at. A gap in any of those is invisible to a test that does the wiring
# itself.
#
# So this one does nothing by hand. It seeds the shell-flavour disk, boots it,
# and TYPES — through the QEMU monitor, one keystroke at a time, the way a
# person would. The shell's output goes to the framebuffer and there is no
# display, so the verdict is not read from the screen: the file wget wrote is
# lifted off the FAT32 image afterwards and compared byte for byte against what
# the server was asked to send.
#
#   scripts/test-shell-net.sh
set -e
cd "$(cd "$(dirname "$0")/.." && pwd)"

PORT=17781
PAYLOAD=/tmp/shellnet-expect.bin
GOT=/tmp/shellnet-got.bin

[ -f build/causticos.iso ] || { echo "build/causticos.iso missing — NOBOOT=1 scripts/run.sh"; exit 1; }
[ -f userspace/build/wget.cse ] || { echo "userspace not built"; exit 1; }

bash scripts/seed-disk.sh shell --no-build >/dev/null

python3 scripts/http-server.py "$PORT" 90 >/tmp/shellnet-srv.log 2>&1 &
SRV=$!

MON=/tmp/causticos-shellnet-mon.$$
LOG=$(mktemp)
QEMU_DISK=build/disk.img
QEMU_KVM=1
source scripts/qemu-args.sh

qemu-system-x86_64 "${QEMU_ARGS[@]}" \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio -display none > "$LOG" 2>&1 &
QPID=$!

mon() { printf '%s\n' "$1" | socat - "unix-connect:$MON" >/dev/null 2>&1 || true; }
cleanup() {
    kill -9 $QPID 2>/dev/null || true; wait $QPID 2>/dev/null || true
    kill $SRV 2>/dev/null || true; wait $SRV 2>/dev/null || true
    rm -f "$MON"
}
trap cleanup EXIT

# Wait for the shell to say the stack is up. Typing before that races the
# prompt and the keystrokes go nowhere.
UP=0
for _ in $(seq 1 300); do
    if tr -d '\000' < "$LOG" | grep -q "shell: netd up"; then UP=1; break; fi
    if tr -d '\000' < "$LOG" | grep -q "shell: no netd"; then
        echo "FAIL: the shell booted without a network stack"
        tr -d '\000' < "$LOG" | grep -E "shell:|netd:" | head
        exit 1
    fi
    kill -0 $QPID 2>/dev/null || break
    sleep 0.1
done
[ "$UP" = 1 ] || { echo "FAIL: shell never reported netd up"; tail -20 "$LOG"; exit 1; }

# A lease before the command, or the first thing wget does is fail to resolve.
for _ in $(seq 1 200); do
    tr -d '\000' < "$LOG" | grep -q "netd: dhcp bound" && break
    sleep 0.1
done

# ASCII to QEMU key names. Only what the command below needs — a table that
# claimed to cover the alphabet and did not would fail as a wrong command line
# rather than as a missing key.
key_of() {
    case "$1" in
        [a-z0-9]) printf '%s' "$1" ;;
        [A-Z]) printf 'shift-%s' "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" ;;
        ' ') printf 'spc' ;;
        '-') printf 'minus' ;;
        '/') printf 'slash' ;;
        '.') printf 'dot' ;;
        ':') printf 'shift-semicolon' ;;
        *)  echo "no key name for '$1'" >&2; exit 1 ;;
    esac
}

CMD="wget -q -O /o.bin http://10.0.2.2:$PORT/f.bin"
echo "typing: $CMD"
for (( i=0; i<${#CMD}; i++ )); do
    K=$(key_of "${CMD:$i:1}")
    mon "sendkey $K"
done
mon "sendkey ret"

# wget has to resolve, connect, transfer 64 KiB and close the file. Poll the
# image rather than sleeping a fixed time: the disk is the only signal there
# is, since the shell's output went to a framebuffer nobody is looking at.
OK=0
for _ in $(seq 1 120); do
    sleep 0.5
    if python3 scripts/fat32_get.py build/disk.img o.bin "$GOT" >/dev/null 2>&1; then
        if [ "$(stat -c%s "$GOT" 2>/dev/null || echo 0)" = "65536" ]; then OK=1; break; fi
    fi
    kill -0 $QPID 2>/dev/null || break
done

if [ "$OK" != 1 ]; then
    echo "FAIL: /o.bin never reached 65536 bytes on the disk"
    tr -d '\000' < "$LOG" | grep -E "shell:|netd:|panic|EXCEPTION" | tail -20
    exit 1
fi

python3 - "$GOT" <<'PY'
import sys
got = open(sys.argv[1], 'rb').read()
want = bytes(((i * 31 + 7) & 0xFF) for i in range(65536))
if got != want:
    for i, (a, b) in enumerate(zip(got, want)):
        if a != b:
            print(f"FAIL: byte {i} is {a}, should be {b}")
            sys.exit(1)
    print(f"FAIL: length {len(got)}, should be {len(want)}")
    sys.exit(1)
print("  ok   typed at the prompt, 65536 bytes, every one correct")
PY

echo "=== shell-net: PASS ==="
