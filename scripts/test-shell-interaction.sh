#!/usr/bin/env bash
# test-shell-interaction.sh — exercise process listing, a pipeline, and Ctrl+C
# through the shell's real keyboard and tty, not boot-time markers.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

source "$(dirname "$0")/portable.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/causticos-interaction.XXXXXX")
DISK="$WORK/root.img"
ISO="$WORK/interaction.iso"
LOG="$WORK/serial.log"
GOT="$WORK/guest-file"
MON="$WORK/monitor.sock"
QPID=""
KEEP="${KEEP:-0}"

cleanup() {
    if [ -n "$QPID" ] && kill -0 "$QPID" 2>/dev/null; then
        kill -9 "$QPID" 2>/dev/null || true
        wait "$QPID" 2>/dev/null || true
    fi
    rm -f "$MON"
    if [ "$KEEP" = 0 ]; then
        rm -rf "$WORK"
    else
        echo "interaction: artifacts kept in $WORK"
    fi
}
trap cleanup EXIT

"$PY" scripts/mkroot.py --profile shell --img "$DISK" -q
bash scripts/mkiso.sh --cmdline "root=ahci-p0" --out "$ISO" >/dev/null

QEMU_ISO="$ISO"
QEMU_DISK="$DISK"
QEMU_MEM="64M"
QEMU_SMP="1"
QEMU_HTTPD_PORT="18991"
QEMU_ACCEL="${QEMU_ACCEL:-tcg}"
source scripts/qemu-args.sh
qemu-system-x86_64 "${QEMU_ARGS[@]}" \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio -display none > "$LOG" 2>&1 &
QPID=$!

mon() {
    printf '%s\n' "$1" | socat - "unix-connect:$MON" >/dev/null 2>&1 || true
}

fail() {
    echo "FAIL: $*"
    echo "--- guest serial ---"
    tr -d '\000' < "$LOG" | grep -E 'shell:|panic:|EXCEPTION|#PF|#GP' | tail -30 || true
    KEEP=1
    exit 1
}

for _ in $(seq 1 600); do
    RAW=$(tr -d '\000' < "$LOG")
    if [[ "$RAW" == *"shell: ready"* ]]; then break; fi
    if echo "$RAW" | grep -qE 'panic:|EXCEPTION|#PF|#GP|kernel halted'; then
        fail "shell boot failed"
    fi
    kill -0 "$QPID" 2>/dev/null || fail "QEMU exited before shell: ready"
    sleep 0.1
done
[[ "$RAW" == *"shell: ready"* ]] || fail "shell did not become ready"

key_of() {
    case "$1" in
        [a-z0-9]) printf '%s' "$1" ;;
        ' ') printf 'spc' ;;
        '-') printf 'minus' ;;
        '/') printf 'slash' ;;
        '.') printf 'dot' ;;
        '>') printf 'shift-dot' ;;
        '|') printf 'shift-backslash' ;;
        *) echo "no QEMU key name for '$1'" >&2; return 1 ;;
    esac
}

type_line() {
    local text="$1" i key
    for ((i = 0; i < ${#text}; i++)); do
        key=$(key_of "${text:$i:1}")
        mon "sendkey $key"
    done
    mon "sendkey ret"
}

wait_for_file_match() {
    local path="$1" pattern="$2"
    for _ in $(seq 1 200); do
        if "$PY" scripts/fat32.py "$DISK" get "$path" "$GOT" >/dev/null 2>&1 \
            && grep -Eq "$pattern" "$GOT"; then
            return 0
        fi
        kill -0 "$QPID" 2>/dev/null || return 1
        sleep 0.1
    done
    return 1
}

type_line 'ps > /ps.out'
wait_for_file_match ps.out 'PID  PPID  STATE[[:space:]]+NAME' \
    || fail "ps did not write its process table"
echo "interaction: ps produced a process table"

type_line 'cat /hello.txt > /hello.out'
wait_for_file_match hello.out '^ola do CausticOS!' \
    || fail "cat did not copy the shipped hello.txt"
"$PY" -c 'import pathlib, sys; raise SystemExit(0 if pathlib.Path(sys.argv[1]).read_bytes().endswith(b"\n") else 1)' "$GOT" \
    || fail "/hello.txt did not end in a newline"
echo "interaction: /hello.txt ends with newline"

type_line 'cd /definitely-not-a-directory'
sleep 0.2
type_line 'echo after-cd > /after-cd.out'
wait_for_file_match after-cd.out '^after-cd([[:space:]]|$)' \
    || fail "shell did not continue after cd rejected a missing path"
sleep 0.5
mon "screendump $WORK/cd-error.ppm"
[[ -s "$WORK/cd-error.ppm" ]] || fail "QEMU did not capture the cd diagnostic screen"
echo "interaction: captured cd error screen for visual check"

type_line 'mkdir /lib > /mkdir.out'
wait_for_file_match mkdir.out '^mkdir: /lib: already exists$' \
    || fail "mkdir did not report that the existing directory already exists"
echo "interaction: mkdir reports already exists"

type_line 'echo pipe | wc -c > /pipe.out'
wait_for_file_match pipe.out '(^|[^[:digit:]])5([^[:digit:]]|$)' \
    || fail "pipeline did not deliver the five-byte input to wc -c"
echo "interaction: pipeline delivered five bytes to wc -c"

# A one-byte `head` leaves its output unterminated. Capture the real shell
# screen so the prompt's line placement can be checked in QEMU.
type_line 'head -c 1 /hello.txt'
sleep 0.5
type_line 'echo next > /after-no-newline.out'
wait_for_file_match after-no-newline.out '^next([[:space:]]|$)' \
    || fail "shell did not accept a command after no-newline output"
sleep 0.5
mon "screendump $WORK/no-newline.ppm"
[[ -s "$WORK/no-newline.ppm" ]] || fail "QEMU did not capture the no-newline prompt screen"
echo "interaction: prompt returned after output without newline"

type_line 'sleep 60'
sleep 1
mon 'sendkey ctrl-c'
sleep 0.2
type_line 'echo resumed > /interrupt.out'
wait_for_file_match interrupt.out '^resumed([[:space:]]|$)' \
    || fail "Ctrl+C did not return the prompt for the next command"
type_line 'ps > /after-interrupt.out'
wait_for_file_match after-interrupt.out 'PID  PPID  STATE[[:space:]]+NAME' \
    || fail "ps did not run after Ctrl+C"
if grep -Eq '^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]+sleep([.]|[[:space:]]|$)' "$GOT"; then
    fail "sleep remained in the process table after Ctrl+C"
fi
echo "interaction: Ctrl+C returned the prompt and reaped sleep"

mon 'quit'
for _ in $(seq 1 50); do
    kill -0 "$QPID" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "$QPID" 2>/dev/null; then
    kill -9 "$QPID" 2>/dev/null || true
fi
wait "$QPID" 2>/dev/null || true
QPID=""
echo "=== shell-interaction: PASS ==="
