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
printf 'AB\b' > "$WORK/backspace.bin"

"$PY" scripts/mkroot.py --profile shell --img "$DISK" --add "$WORK/backspace.bin:/backspace.bin" -q
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
        '&') printf 'shift-7' ;;
        '|') printf 'shift-backslash' ;;
        *) echo "no QEMU key name for '$1'" >&2; return 1 ;;
    esac
}

type_text() {
    local text="$1" i key
    for ((i = 0; i < ${#text}; i++)); do
        key=$(key_of "${text:$i:1}")
        mon "sendkey $key"
    done
}

type_line() {
    type_text "$1"
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
guest_file_is_exact() {
    "$PY" - "$GOT" "$1" <<'PY'
from pathlib import Path
import sys

actual = Path(sys.argv[1]).read_bytes()
expected = sys.argv[2].replace(r"\n", "\n").encode()
if actual != expected:
    print(f"expected {expected!r}, got {actual!r}", file=sys.stderr)
    raise SystemExit(1)
PY
}

red_pixel_count() {
    "$PY" - "$1" <<'PY'
from pathlib import Path
import sys

data = Path(sys.argv[1]).read_bytes()
pos = 0

def token():
    global pos
    while True:
        while pos < len(data) and data[pos] in b" \t\r\n":
            pos += 1
        if pos < len(data) and data[pos] == 35:
            end = data.find(b"\n", pos)
            if end < 0:
                raise SystemExit("unterminated PPM comment")
            pos = end + 1
            continue
        break
    start = pos
    while pos < len(data) and data[pos] not in b" \t\r\n#":
        pos += 1
    if pos == start:
        raise SystemExit("missing PPM header token")
    return data[start:pos]

magic = token()
width = int(token())
height = int(token())
maxval = int(token())
if magic != b"P6" or maxval != 255 or pos >= len(data) or data[pos] not in b" \t\r\n":
    raise SystemExit("unexpected QEMU PPM format")
if data[pos:pos + 2] == b"\r\n":
    pos += 2
else:
    pos += 1
pixels = data[pos:]
if len(pixels) != width * height * 3:
    raise SystemExit("truncated or oversized QEMU PPM raster")
red = sum(
    pixels[i] > 160 and pixels[i + 1] < 120 and pixels[i + 2] < 120
    for i in range(0, len(pixels), 3)
)
print(red)
PY
}

type_line 'ps > /ps.out'
wait_for_file_match ps.out 'PID  PPID  STATE[[:space:]]+NAME' \
    || fail "ps did not write its process table"
echo "interaction: ps produced a process table"

type_line 'cat /backspace.bin'
sleep 0.5
type_line 'echo backspace-returned > /backspace-returned.out'
wait_for_file_match backspace-returned.out '^backspace-returned([[:space:]]|$)' \
    || fail "shell did not accept a command after raw Backspace output"
sleep 0.5
mon "screendump $WORK/backspace.ppm"
[[ -s "$WORK/backspace.ppm" ]] || fail "QEMU did not capture the Backspace output screen"
echo "interaction: captured raw Backspace output screen for visual check"
type_line 'help'
sleep 0.5
type_line 'echo help-processed > /help-ready.out'
wait_for_file_match help-ready.out '^help-processed$' \
    || fail "shell did not finish the help command"
mon "screendump $WORK/help-programs.ppm"
[[ -s "$WORK/help-programs.ppm" ]] || fail "QEMU did not capture the help screen"
echo "interaction: captured help program list screen for visual check"
type_line 'help exit'
sleep 0.5
mon "screendump $WORK/help-exit.ppm"
[[ -s "$WORK/help-exit.ppm" ]] || fail "QEMU did not capture the exit help screen"
echo "interaction: captured exit help screen for visual check"
mon "screendump $WORK/color-baseline.ppm"
[[ -s "$WORK/color-baseline.ppm" ]] || fail "QEMU did not capture the baseline screen"
baseline_red=$(red_pixel_count "$WORK/color-baseline.ppm")

type_line 'missing-command-for-color-test'
sleep 0.5
type_line 'echo shell-error-processed > /shell-error-ready.out'
wait_for_file_match shell-error-ready.out '^shell-error-processed$' \
    || fail "shell did not finish the not-found command"
mon "screendump $WORK/shell-error.ppm"
[[ -s "$WORK/shell-error.ppm" ]] || fail "QEMU did not capture the shell error screen"
shell_error_red=$(red_pixel_count "$WORK/shell-error.ppm")
(( shell_error_red > baseline_red + 4 )) || fail "shell not-found diagnostic was not rendered red"
echo "interaction: shell not-found diagnostic is red"

type_line 'cat /definitely-not-a-file'
sleep 0.5
type_line 'echo program-error-processed > /program-error-ready.out'
wait_for_file_match program-error-ready.out '^program-error-processed$' \
    || fail "shell did not finish the program-error command"
mon "screendump $WORK/program-error.ppm"
[[ -s "$WORK/program-error.ppm" ]] || fail "QEMU did not capture the program error screen"
program_error_red=$(red_pixel_count "$WORK/program-error.ppm")
(( program_error_red > shell_error_red + 4 )) || fail "program stderr diagnostic was not rendered red"
echo "interaction: terminal-bound program diagnostic is red"



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


type_line 'mkdir /lib 2>&1 > /mkdir.out'
wait_for_file_match mkdir.out '^mkdir: /lib: already exists$' \
    || fail "mkdir did not report that the existing directory already exists"
guest_file_is_exact 'mkdir: /lib: already exists\n' \
    || fail "redirected mkdir error contained ANSI or extra output"
echo "interaction: mkdir reports already exists"

type_line 'rm /definitely-not-a-file 2>&1 > /rm-missing.out'
wait_for_file_match rm-missing.out '^rm: /definitely-not-a-file: no such file or directory$' \
    || fail "rm did not report the missing-file reason"
guest_file_is_exact 'rm: /definitely-not-a-file: no such file or directory\n' \
    || fail "redirected missing-file error contained ANSI or extra output"
echo "interaction: rm reports a missing file"
type_line 'rm /lib 2>&1 > /rm-directory.out'
wait_for_file_match rm-directory.out '^rm: /lib: is a directory \(use -r to remove it\)$' \
    || fail "rm did not reserve the -r advice for directories"
guest_file_is_exact 'rm: /lib: is a directory (use -r to remove it)\n' \
    || fail "redirected directory error contained ANSI or extra output"
echo "interaction: rm reserves -r advice for directories"
type_line 'cat /lib 2>&1 > /cat-directory.out'
wait_for_file_match cat-directory.out '^cat: /lib: is a directory$' \
    || fail "cat did not reject a directory with an error"
"$PY" -c 'import pathlib, sys; raise SystemExit(0 if pathlib.Path(sys.argv[1]).read_bytes() == b"cat: /lib: is a directory\n" else 1)' "$GOT" \
    || fail "cat directory output contained extra data or diagnostics"
echo "interaction: cat rejects directories without reading them"
type_line 'cat /definitely-not-a-file 2>&1 > /cat-missing.out'
wait_for_file_match cat-missing.out '^cat: /definitely-not-a-file: no such file or directory$' \
    || fail "cat did not report the redirected missing-file reason"
guest_file_is_exact 'cat: /definitely-not-a-file: no such file or directory\n' \
    || fail "redirected program error contained ANSI or extra output"
echo "interaction: redirected program errors stay uncolored"
type_line 'echo pipe | wc -c > /pipe.out'
wait_for_file_match pipe.out '^5$' \
    || fail "pipeline did not deliver an unpadded five-byte count to wc -c"
guest_file_is_exact '5\n' \
    || fail "wc -c added padding or extra output"
type_line 'echo pipe | wc -c'
sleep 0.5
mon "screendump $WORK/wc-stdin.ppm"
[[ -s "$WORK/wc-stdin.ppm" ]] || fail "QEMU did not capture the stdin byte count"
echo "interaction: wc -c counted five pipeline bytes without padding"

type_line 'seq 5 | head -3 > /head-classic.out'
wait_for_file_match head-classic.out '^3$' \
    || fail "classic head -3 did not receive the pipeline's first three lines"
guest_file_is_exact '1\n2\n3\n' \
    || fail "classic head -3 wrote the wrong lines"
type_line 'seq 5 | head -3'
sleep 0.5
mon "screendump $WORK/head-classic.ppm"
[[ -s "$WORK/head-classic.ppm" ]] || fail "QEMU did not capture classic head output"
echo "interaction: classic head -3 received and displayed three pipeline lines"

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
mon "screendump $WORK/ctrl-c.ppm"
[[ -s "$WORK/ctrl-c.ppm" ]] || fail "QEMU did not capture the interrupted foreground screen"
echo "interaction: captured Ctrl+C after interrupting foreground sleep"
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
type_line 'ping -c 3 10.0.2.2 &'
sleep 0.2
type_text 'echo background-output-preserved > /bg-preserved.out'
sleep 1
mon "screendump $WORK/background-output.ppm"
[[ -s "$WORK/background-output.ppm" ]] || fail "QEMU did not capture the background output screen"
echo "interaction: captured background output while editing the prompt"
sleep 7
mon 'sendkey ret'
wait_for_file_match bg-preserved.out '^background-output-preserved$' \
    || fail "background output damaged the editable prompt line"
echo "interaction: prompt line survived background output"

type_line 'exit'
for _ in $(seq 1 100); do
    kill -0 "$QPID" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "$QPID" 2>/dev/null; then
    fail "exit did not power off the fullscreen shell profile"
fi
wait "$QPID" 2>/dev/null || true
QPID=""
"$PY" scripts/fat32.py "$DISK" get /var/history "$GOT" >/dev/null 2>&1 \
    || fail "exit powered off before the history file could be read"
"$PY" - "$GOT" <<'PY' || fail "exit did not save its command to /var/history"
from pathlib import Path
import sys

data = Path(sys.argv[1]).read_bytes()
if data[:4] != b"HIST" or len(data) < 8:
    raise SystemExit(1)
count = int.from_bytes(data[4:8], "little")
pos = 8
for _ in range(count):
    if pos + 4 > len(data):
        raise SystemExit(1)
    size = int.from_bytes(data[pos:pos + 4], "little")
    pos += 4
    end = pos + size
    if end > len(data):
        raise SystemExit(1)
    if data[pos:end] == b"exit":
        raise SystemExit(0)
    pos = end
raise SystemExit(1)
PY
echo "interaction: exit saved history before powering off"
echo "interaction: exit powered off the fullscreen shell profile"
echo "=== shell-interaction: PASS ==="
