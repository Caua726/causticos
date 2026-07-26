#!/bin/bash
# test-shell-net.sh — type wget at the real shell prompt, twice, and check what
# lands on the disk.
#
# Every other network test spawns netd itself and hands the child a channel by
# hand. That proves the mechanism and says nothing about whether the machine you
# actually boot is wired up: /init has to start netd, the shell has to mint an
# endpoint per command, and the endpoint has to arrive on the fd the program
# looks at. A gap in any of those is invisible to a test that does the wiring
# itself.
#
# So this one does nothing by hand. It seeds the shell-flavour disk, boots it,
# and TYPES — through the QEMU monitor, one keystroke at a time, the way a
# person would. The shell's output goes to the framebuffer and there is no
# display, so the verdict is not read from the screen: the files wget wrote are
# lifted off the FAT32 image afterwards and compared byte for byte.
#
# THE SECOND COMMAND IS THE POINT. It is the same binary, the same HTTP code and
# the same argument shape, differing only in the scheme — which decides which
# Conn the bytes travel through. That is the milestone the Conn abstraction was
# written for, and it is only meaningful if both halves are checked.
#
#   scripts/test-shell-net.sh
set -e
cd "$(cd "$(dirname "$0")/.." && pwd)"

source "$(dirname "$0")/portable.sh"

PORT=17781
TLS_PORT=17784
GOT=/tmp/shellnet-got.bin

[ -f build/causticos.iso ] || { echo "build/causticos.iso missing — NOBOOT=1 scripts/run.sh"; exit 1; }
[ -f userspace/build/wget.cse ] || { echo "userspace not built"; exit 1; }
[ -f build/certs/srv.pem ] || bash scripts/make-test-certs.sh >/dev/null

# The guest trusts the test CA and nothing else, so the https fetch is checked
# against a real chain rather than waved through.
# Its own image, so this test can run beside the others rather than fighting
# them for build/disk.img — and its own trust store, because the server it
# dials is signed by the test CA and the machine's real bundle has never heard
# of it. A guest that accepted it anyway would be the bug.
DISK=build/disk-shell-net.img
CA_PEM=build/certs/ca.pem SEED_DISK="$DISK" \
    "$PY" scripts/mkroot.py --profile shell --img "$DISK" -q

"$PY" scripts/http-server.py "$PORT" 200 >/tmp/shellnet-srv.log 2>&1 &
SRV=$!
"$PY" scripts/http-server.py "$TLS_PORT" 200 \
    build/certs/srvchain.pem build/certs/srv.key >/tmp/shellnet-tls.log 2>&1 &
SRV_TLS=$!

MON=/tmp/causticos-shellnet-mon.$$
LOG=$(mktemp)
QEMU_DISK="$DISK"
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
    kill $SRV_TLS 2>/dev/null || true; wait $SRV_TLS 2>/dev/null || true
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

# ASCII to QEMU key names. Only what the commands below need — a table that
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

type_line() {
    echo "typing: $1"
    local i K
    for (( i=0; i<${#1}; i++ )); do
        K=$(key_of "${1:$i:1}")
        mon "sendkey $K"
    done
    mon "sendkey ret"
}

# Poll the image rather than sleeping a fixed time: the disk is the only signal
# there is, since the shell's output went to a framebuffer nobody is looking at.
wait_for_file() {
    local name="$1" want="$2" i
    # 20 seconds, not 120. The cap exists to catch a HANG; a download that
    # has not appeared in twenty is not going to, and waiting two minutes
    # to say so is most of what made this suite too slow to run.
    for (( i=0; i<100; i++ )); do
        sleep 0.2
        if "$PY" scripts/fat32_get.py "$DISK" "$name" "$GOT" >/dev/null 2>&1; then
            if [ "$(stat -c%s "$GOT" 2>/dev/null || echo 0)" = "$want" ]; then return 0; fi
        fi
        kill -0 $QPID 2>/dev/null || return 1
    done
    return 1
}

check_blob() {
    "$PY" - "$GOT" "$1" <<'PY'
import sys
got = open(sys.argv[1], 'rb').read()
want = bytes(((i * 31 + 7) & 0xFF) for i in range(65536))
if got != want:
    for i, (a, b) in enumerate(zip(got, want)):
        if a != b:
            print(f"FAIL: {sys.argv[2]}: byte {i} is {a}, should be {b}")
            sys.exit(1)
    print(f"FAIL: {sys.argv[2]}: length {len(got)}, should be {len(want)}")
    sys.exit(1)
print(f"  ok   {sys.argv[2]}")
PY
}

type_line "wget -q -O /o.bin http://10.0.2.2:$PORT/f.bin"
if ! wait_for_file o.bin 65536; then
    echo "FAIL: /o.bin never reached 65536 bytes on the disk"
    tr -d '\000' < "$LOG" | grep -E "shell:|netd:|panic|EXCEPTION" | tail -20
    exit 1
fi
check_blob "http,  typed at the prompt, 65536 bytes, every one correct"

# The same binary, over TLS.
type_line "wget -q -O /s.bin https://10.0.2.2:$TLS_PORT/f.bin"
if ! wait_for_file s.bin 65536; then
    echo "FAIL: /s.bin never reached 65536 bytes on the disk"
    tr -d '\000' < "$LOG" | grep -E "shell:|netd:|panic|EXCEPTION" | tail -20
    tail -5 /tmp/shellnet-tls.log
    exit 1
fi
check_blob "https, same binary, 65536 bytes, every one correct"

echo "=== shell-net: PASS ==="
