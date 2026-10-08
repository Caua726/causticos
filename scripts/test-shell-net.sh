#!/bin/bash
# test-shell-net.sh — type wget at the real shell prompt and check what
# lands on disk, including failed-download output preservation.
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
# The trust store goes on as a FILE at the path wget reads (/etc/ca.pem). It
# used to be handed over as a CA_PEM environment variable, which nothing has
# read for a long time — so the guest booted with no test CA, refused the
# server's certificate exactly as it should, and the test read that correct
# refusal as a broken TLS stack.
"$PY" scripts/mkroot.py --profile shell --img "$DISK" -q \
    --add "build/certs/ca.pem:/etc/ca.pem"

"$PY" scripts/http-server.py "$PORT" 200 >/tmp/shellnet-srv.log 2>&1 &
SRV=$!
"$PY" scripts/http-server.py "$TLS_PORT" 200 \
    build/certs/srvchain.pem build/certs/srv.key >/tmp/shellnet-tls.log 2>&1 &
SRV_TLS=$!

MON=/tmp/causticos-shellnet-mon.$$
LOG=$(mktemp)
QEMU_DISK="$DISK"
QEMU_KVM=1
# The live root inside the ISO outranks an attached disk (prio 100 vs 10), so a
# seeded disk alone is never mounted — the kernel boots the ISO's own desktop
# root and every check here looks at the wrong system. root= on the command line
# is what says "mount THIS one", and it is why the disk is still a disk: the
# host reads results back out of it after the boot, which a volatile RAM root
# cannot offer.
# ROOTED_ISO lets a caller hand us one that is already built. mkiso stages
# through a single build/iso directory, so eight of these running at once —
# which is how test-userspace.sh drives them — would tread on each other.
if [ -n "${ROOTED_ISO:-}" ]; then
    QEMU_ISO="$ROOTED_ISO"
else
    QEMU_ISO=build/test-shell-net.iso
    bash scripts/mkiso.sh --cmdline "root=ahci-p0" --out "$QEMU_ISO" >/dev/null
fi
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
        '>') printf 'shift-dot' ;;
        '|') printf 'shift-backslash' ;;
        '&') printf 'shift-7' ;;
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
        # fat32.py, not fat32_get.py: the four host-side FAT32 scripts were
        # consolidated into one with subcommands and this call kept the dead
        # name. With stderr swallowed it looked exactly like "the file is not
        # there yet" — every iteration, until the loop gave up and blamed the
        # guest for a download that had in fact arrived.
        if "$PY" scripts/fat32.py "$DISK" get "$name" "$GOT" >/dev/null 2>&1; then
            if [ "$(stat -c%s "$GOT" 2>/dev/null || echo 0)" = "$want" ]; then return 0; fi
        fi
        kill -0 $QPID 2>/dev/null || return 1
    done
    return 1
}

check_blob() {
    "$PY" - "$GOT" "$1" "${2:-65536}" <<'PY'
import sys
got = open(sys.argv[1], 'rb').read()
want = bytes(((i * 31 + 7) & 0xFF) for i in range(int(sys.argv[3])))
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

# Failure must not publish a new empty file or truncate an existing output.
# The conditional marker waits for wget's actual exit status, not just a file
# appearing while the foreground command is still running.
type_line "wget -q -O /rejected.bin http://10.0.2.2:$PORT/missing || touch /status404"
wait_for_file status404 0 || { echo "FAIL: HTTP 404 did not return failure"; exit 1; }
if "$PY" scripts/fat32.py "$DISK" get rejected.bin "$GOT" >/dev/null 2>&1; then
    echo "FAIL: HTTP 404 left /rejected.bin behind"
    exit 1
fi
echo "  ok   HTTP 404 returns failure without creating the output"

type_line "wget -q -O /o.bin http://10.0.2.2:$PORT/missing || touch /statuskeep"
wait_for_file statuskeep 0 || { echo "FAIL: replacement HTTP 404 did not return failure"; exit 1; }
"$PY" scripts/fat32.py "$DISK" get o.bin "$GOT" >/dev/null
check_blob "HTTP 404 preserves every byte of an existing output"

type_line "wget -q -O /o.bin http://10.0.2.2:$PORT/chunked && touch /statusreplace"
wait_for_file statusreplace 0 || { echo "FAIL: successful replacement did not complete"; exit 1; }
"$PY" scripts/fat32.py "$DISK" get o.bin "$GOT" >/dev/null
check_blob "successful chunked response replaces the existing output" 5000

type_line "wget -q -O /o.bin http://10.0.2.2:$PORT/truncated || touch /statustruncated"
wait_for_file statustruncated 0 || { echo "FAIL: truncated body did not return failure"; exit 1; }
"$PY" scripts/fat32.py "$DISK" get o.bin "$GOT" >/dev/null
check_blob "truncated body preserves the complete previous output" 5000

type_line "wget -q -O /zero.bin http://10.0.2.2:$PORT/empty && touch /statuszero"
wait_for_file statuszero 0 || { echo "FAIL: empty successful body did not return success"; exit 1; }
wait_for_file zero.bin 0 || { echo "FAIL: empty successful body has no output"; exit 1; }
echo "  ok   a successful empty body publishes an empty file"

# An unrelated disconnected port must not make a working route "offline".
mon "set_link net1 off"
type_line "wget -q -O /one-link.bin http://10.0.2.2:$PORT/f.bin"
wait_for_file one-link.bin 65536 || { echo "FAIL: an unrelated down link blocked HTTP"; exit 1; }
check_blob "primary route works while the secondary link is down"

mon "set_link net0 off"
type_line "wget -q -O /offline.bin http://10.0.2.2:$PORT/f.bin || touch /statusoffline"
wait_for_file statusoffline 0 || { echo "FAIL: disconnected request did not return failure"; exit 1; }
if "$PY" scripts/fat32.py "$DISK" get offline.bin "$GOT" >/dev/null 2>&1; then
    echo "FAIL: disconnected request left an output"
    exit 1
fi
echo "  ok   both links down returns failure without publishing an output"

mon "set_link net0 on"
mon "set_link net1 on"
type_line "wget -q -O /recovered.bin http://10.0.2.2:$PORT/f.bin"
wait_for_file recovered.bin 65536 || { echo "FAIL: HTTP did not recover after link restoration"; exit 1; }
check_blob "HTTP recovers after restoring both links"

echo "=== shell-net: PASS ==="
