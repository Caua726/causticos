#!/usr/bin/env bash
source "$(dirname "$0")/portable.sh"
# bootstrap.sh — prove the compiler the dev profile ships is the one causticos
# makes of itself.
#
# The dev profile ships build/caustic.cse, cross-built on the host from
# $CAUSTIC_DIR (the `caustic-cse` target). This boots causticos with that
# compiler and the compiler's own source on a disk, has it rebuild itself there
# — /src/main.cst into /out.cse, an ordinary process on the OS it targets —
# lifts /out.cse off the disk, and makes it the next round's compiler. It passes
# only if EVERY round's output is byte-identical to the shipped binary:
#
#   round 1  the shipped compiler, running on causticos, reproduces itself
#   2..N     and keeps doing so from its own output, boot after boot — the
#            compile is deterministic under a different machine's timing
#
# So the host cross-build is not trusted, it is checked: if it ever differed
# from what causticos produces, this fails and says at which byte.
#
# The compile gets the flags the host build used, read from caustic-mk itself
# (`build caustic-cse --dry-run`): --app-version stamps the binary, and a flag
# the two builds disagree on is a difference in the bytes, not in the compiler.
#
# Usage:  caustic-mk run bootstrap [-- --rounds N] [--mem 512M] [--tcg]
#
# Each round is one boot from a fresh disk (scripts/mkroot.py --profile dev
# --init bootstrap). The round powers the machine off itself, which is what
# writes /out.cse to the disk; the image is read only after QEMU has exited.
# Everything lands in build/bootstrap/ — the serial log of each round, its
# disk, and r<k>.cse.
set -euo pipefail

cd "$(dirname "$0")/.."

ROUNDS=4
# Measured: the compile's low point is ~121 MB below what was free when it
# started (the round log says it as "least free memory"), so 256M leaves it
# about a hundred megabytes of room. The desktop's 64M is enough to compile
# small programs, not to rebuild the compiler.
MEM=256M
ACCEL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --rounds) ROUNDS="$2"; shift 2 ;;
        --rounds=*) ROUNDS="${1#*=}"; shift ;;
        --mem) MEM="$2"; shift 2 ;;
        --mem=*) MEM="${1#*=}"; shift ;;
        --tcg) ACCEL=tcg; shift ;;
        *) echo "bootstrap: unknown option '$1'" >&2; exit 1 ;;
    esac
done
case "$ROUNDS" in ''|*[!0-9]*|0) echo "bootstrap: --rounds wants a positive number" >&2; exit 1 ;; esac
if [ -z "$ACCEL" ]; then
    if [ -w /dev/kvm ]; then ACCEL=kvm; else ACCEL=tcg; fi
fi
# A round under TCG is about ten times one under KVM.
if [ "$ACCEL" = kvm ]; then ROUND_SECS=180; else ROUND_SECS=1800; fi

PY="${PY:-python3}"
WORK=build/bootstrap
rm -rf "$WORK"
mkdir -p "$WORK"

echo "bootstrap: building the dev profile (kernel, userspace, toolchain)"
if ! caustic-mk run build -- --profile dev > "$WORK/build.log" 2>&1; then
    tail -20 "$WORK/build.log"
    echo "bootstrap: the build failed — $WORK/build.log" >&2
    exit 1
fi
if ! (cd userspace && caustic-mk build bootstrap -q) > "$WORK/driver.log" 2>&1; then
    cat "$WORK/driver.log"
    echo "bootstrap: the round driver (userspace/tests/bootstrap.cst) did not build" >&2
    exit 1
fi

SEED=build/caustic.cse
[ -f "$SEED" ] || { echo "bootstrap: $SEED was not built" >&2; exit 1; }

# The flags the host gave the compile, minus what only concerns the host build:
# the program, the source, -o and its file, --cache and its directory.
DRY="$(caustic-mk build caustic-cse --dry-run --force 2>&1 | sed -n 's/^ *\[dry\] //p' | head -1)"
[ -n "$DRY" ] || { echo "bootstrap: caustic-mk did not say how it builds caustic-cse" >&2; exit 1; }
read -r -a WORDS <<< "$DRY"
: > "$WORK/bootstrap.args"
i=2
while [ "$i" -lt "${#WORDS[@]}" ]; do
    w="${WORDS[$i]}"
    case "$w" in
        -o|--cache) i=$((i + 2)); continue ;;
        -q) ;;
        *) printf '%s\n' "$w" >> "$WORK/bootstrap.args" ;;
    esac
    i=$((i + 1))
done
echo "bootstrap: the compile's flags: $(tr '\n' ' ' < "$WORK/bootstrap.args")"

# The machine boots the kernel from an ISO with no live root, so the root is the
# disk — the only place /out.cse can be read back from.
source scripts/rebuild.sh
cos_persist_iso "$WORK/boot.iso" ""

SEED_MD5="$(md5sum "$SEED" | cut -d' ' -f1)"
echo "bootstrap: shipped compiler $SEED  $(stat -c %s "$SEED") bytes  md5 $SEED_MD5"
plural=s; [ "$ROUNDS" = 1 ] && plural=""
echo "bootstrap: $ROUNDS round$plural, $MEM, $ACCEL"

prev="$SEED"
for k in $(seq 1 "$ROUNDS"); do
    disk="$WORK/disk$k.img"
    log="$WORK/round$k.log"
    "$PY" scripts/mkroot.py --profile dev --init bootstrap \
        --add "$prev:/caustic.cse" --add "$WORK/bootstrap.args:/etc/bootstrap.args" \
        --img "$disk" -q

    mapfile -t args < <(
        QEMU_ISO="$WORK/boot.iso" QEMU_DISK="$disk" QEMU_SMP=2 QEMU_ACCEL="$ACCEL" \
        QEMU_MEM="$MEM" QEMU_HTTPD_PORT=$((18600 + k)) \
        bash -c 'source scripts/qemu-args.sh; printf "%s\n" "${QEMU_ARGS[@]}"'
    )
    : > "$log"
    start=$SECONDS
    qemu-system-x86_64 "${args[@]}" -serial "file:$log" -display none &
    qpid=$!
    # The round ends with a power-off; the deadline only catches a machine that
    # hung, and a panic needs no waiting for at all.
    while kill -0 "$qpid" 2>/dev/null; do
        if [ $((SECONDS - start)) -ge "$ROUND_SECS" ]; then
            echo "bootstrap: round $k still running after ${ROUND_SECS}s — stopped" >&2
            kill -9 "$qpid" 2>/dev/null
            break
        fi
        if tr -d '\000' < "$log" | grep -qaE 'panic|EXCEPTION'; then
            sleep 1
            kill -9 "$qpid" 2>/dev/null
            break
        fi
        sleep 0.5
    done
    wait "$qpid" 2>/dev/null || true

    raw="$(tr -d '\000' < "$log")"
    if ! grep -qa 'bootstrap: ROUND DONE' <<< "$raw"; then
        echo "bootstrap: round $k FAILED — the end of its serial log ($log):" >&2
        grep -aE 'bootstrap:|panic|EXCEPTION|error|Error' <<< "$raw" | tail -15 >&2
        exit 1
    fi
    out="$WORK/r$k.cse"
    "$PY" scripts/fat32.py "$disk" get /out.cse "$out" > /dev/null
    stats="$(grep -aoE 'exited code=0 after [0-9]+ s; least free memory [0-9]+ KB' <<< "$raw" | tail -1)"
    if cmp -s "$out" "$SEED"; then
        echo "  round $k: identical to the shipped compiler  (${stats#exited code=0 })"
    else
        echo "  round $k: DIFFERS from the shipped compiler — $(cmp "$out" "$SEED" 2>&1 | head -1)" >&2
        echo "bootstrap: FAILED — causticos does not produce the binary the dev profile ships" >&2
        exit 1
    fi
    prev="$out"
done

echo "bootstrap: PASS — $ROUNDS round$plural on causticos, every one byte-identical to $SEED"
