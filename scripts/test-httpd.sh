#!/bin/bash
# test-httpd.sh — start httpd inside the guest and fetch from it, from outside.
#
# Everything else in this stack dials out. httpd is the only thing that
# answers, and a passive open is genuinely different code: a SYN arriving
# unsolicited, a four-tuple the guest did not choose, an accept queue. netd has
# had that path since TCP landed and no client had ever used it.
#
# A server test with no external client is a test of nothing, so the client
# here is curl on the host, reaching in through QEMU's hostfwd — SLIRP lets the
# guest dial out freely and lets nothing dial in, so the forward is the only
# door. And the bytes are checked: a 200 with the wrong body is not a pass.
#
# The command is TYPED at the shell prompt, in the background, the same way a
# person would start a server. That covers the shell's job control and the
# per-command netd endpoint at the same time.
#
#   scripts/test-httpd.sh
set -e
cd "$(cd "$(dirname "$0")/.." && pwd)"

FWD=18081
GOT=/tmp/httpd-got.bin

[ -f build/causticos.iso ] || { echo "build/causticos.iso missing"; exit 1; }
[ -f userspace/build/httpd.cse ] || { echo "userspace not built"; exit 1; }

# A file to serve, with content the host can check byte for byte.
python3 - <<'PY'
import pathlib
pathlib.Path('build/httpd-payload.bin').write_bytes(
    bytes(((i * 31 + 7) & 0xFF) for i in range(4096)))
PY

bash scripts/seed-disk.sh shell --no-build >/dev/null
python3 scripts/fat32_add_file.py build/disk.img addfilebin served.bin \
    build/httpd-payload.bin >/dev/null

MON=/tmp/causticos-httpd-mon.$$
LOG=$(mktemp)
QEMU_DISK=build/disk.img
QEMU_KVM=1
QEMU_HTTPD_PORT=$FWD
source scripts/qemu-args.sh

qemu-system-x86_64 "${QEMU_ARGS[@]}" \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio -display none > "$LOG" 2>&1 &
QPID=$!

mon() { printf '%s\n' "$1" | socat - "unix-connect:$MON" >/dev/null 2>&1 || true; }
cleanup() {
    kill -9 $QPID 2>/dev/null || true; wait $QPID 2>/dev/null || true
    rm -f "$MON"
}
trap cleanup EXIT

for _ in $(seq 1 300); do
    tr -d '\000' < "$LOG" | grep -q "shell: netd up" && break
    kill -0 $QPID 2>/dev/null || break
    sleep 0.1
done
for _ in $(seq 1 200); do
    tr -d '\000' < "$LOG" | grep -q "netd: dhcp bound" && break
    sleep 0.1
done

key_of() {
    case "$1" in
        [a-z0-9]) printf '%s' "$1" ;;
        [A-Z]) printf 'shift-%s' "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" ;;
        ' ') printf 'spc' ;;
        '-') printf 'minus' ;;
        '/') printf 'slash' ;;
        '.') printf 'dot' ;;
        ':') printf 'shift-semicolon' ;;
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

# In the background, so the shell stays usable and the server keeps running.
type_line "httpd -q -p 8080 -r / &"

# Wait for it to say it is listening rather than sleeping a guess.
UP=0
for _ in $(seq 1 200); do
    if tr -d '\000' < "$LOG" | grep -q "httpd: listening"; then UP=1; break; fi
    kill -0 $QPID 2>/dev/null || break
    sleep 0.1
done
if [ "$UP" != 1 ]; then
    echo "FAIL: httpd never reported listening"
    tr -d '\000' < "$LOG" | grep -E "shell:|netd:|httpd" | tail -20
    exit 1
fi

# The fetch, from outside, through the forward.
CODE=$(curl -s -o "$GOT" -w '%{http_code}' --max-time 20 \
    "http://127.0.0.1:$FWD/served.bin" || echo "000")
echo "curl: HTTP $CODE, $(stat -c%s "$GOT" 2>/dev/null || echo 0) bytes"

if [ "$CODE" != "200" ]; then
    echo "FAIL: expected 200, got $CODE"
    tr -d '\000' < "$LOG" | grep -E "httpd|netd:" | tail -20
    exit 1
fi

python3 - "$GOT" <<'PY'
import sys
got = open(sys.argv[1], 'rb').read()
want = bytes(((i * 31 + 7) & 0xFF) for i in range(4096))
if got != want:
    for i, (a, b) in enumerate(zip(got, want)):
        if a != b:
            print(f"FAIL: byte {i} is {a}, should be {b}")
            sys.exit(1)
    print(f"FAIL: length {len(got)}, should be {len(want)}")
    sys.exit(1)
print("  ok   served 4096 bytes to a client on the host, every one correct")
PY

# A path that is not there must be a 404, not a hang and not a 200 of
# something else.
CODE404=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    "http://127.0.0.1:$FWD/nothing-here" || echo "000")
if [ "$CODE404" != "404" ]; then
    echo "FAIL: missing file gave $CODE404, expected 404"
    exit 1
fi
echo "  ok   a missing file is 404"

# And traversal is refused rather than normalised.
CODETRAV=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --path-as-is \
    "http://127.0.0.1:$FWD/../etc/ca.pem" || echo "000")
if [ "$CODETRAV" = "200" ]; then
    echo "FAIL: path traversal served a file outside the root"
    exit 1
fi
echo "  ok   path traversal refused ($CODETRAV)"

echo "=== httpd: PASS ==="
