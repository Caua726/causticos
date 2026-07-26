#!/usr/bin/env bash
# verify.sh — boot the system N times per cpu count and check what it printed.
#
# Two gates, both against the SAME kernel binary the ISO ships:
#
#   live     the ISO alone, no disk on the bus. Proves the claim the whole
#            reform exists for: the root travels inside the image.
#   persist  a scratch FAT32 disk as the root, with the `smoke` command line, so
#            the AHCI driver and the FAT32 write path are actually exercised.
#
# What the script this replaces got wrong, and why each is fixed here:
#
#   - It worked on build/disk.img — the same file the development flow uses — so
#     running it destroyed a seeded disk, and it failed outright while the
#     libvirt VM held that file open. Everything here lives under build/verify/
#     and is created per run, so it is safe to run with the VM up.
#   - It hardcoded an absolute `cd` to one machine's checkout.
#   - Its success marker was ALL PHASE-6 TESTS PASS: a FAT32 test standing in for
#     a boot gate. It never checked that /init was actually spawned, so a kernel
#     that mounted the disk and then failed to start userspace passed.
#   - RUN_SMOKE_INIT was a compile-time switch, so the suite ran on a DIFFERENT
#     BINARY from the one being shipped. The command line replaced it.
#   - -enable-kvm was unconditional, so the sweep simply failed on a machine
#     without KVM instead of falling back.
#
# Two things it got RIGHT are preserved deliberately: qemu is launched as a
# direct child (never wrapped in `timeout`, so the kill reaps qemu itself and
# releases the image lock — otherwise the next run inherits a locked file and
# reports a spurious timeout), and the serial log is stripped of NUL bytes before
# grep, because the kernel's output interleaves them and a raw grep misses every
# marker.
set -uo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || dirname "$(dirname "$0")")"

source "$(dirname "$0")/portable.sh"

SMPS="1,2,4"
RUNS=1
TOUT=25
GATES="live persist"
KEEP=0
USE_ACCEL=0

usage() {
    cat <<'EOF'
usage: caustic-mk run verify -- [options]

  --smp 1,2,4      cpu counts to sweep (default 1,2,4)
  --runs N         boots per cpu count (default 1 — raise it to hunt an
                   intermittent; the default answers 'is it broken', which
                   one boot per configuration already does)
  --timeout S      per-boot deadline in seconds (default 25)
  --live-only      only the live gate (no disk)
  --persist-only   only the persist gate (AHCI + FAT32 writes)
  --keep-logs      leave the serial logs in build/verify/ for inspection
  --kvm            use the host accelerator (default: TCG, so the sweep is
                   identical on every machine)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --smp) SMPS="$2"; shift 2 ;;
        --runs) RUNS="$2"; shift 2 ;;
        --timeout) TOUT="$2"; shift 2 ;;
        --live-only) GATES="live"; shift ;;
        --persist-only) GATES="persist"; shift ;;
        --keep-logs) KEEP=1; shift ;;
        --kvm) USE_ACCEL=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "verify: unknown option '$1' (try --help)" >&2; exit 1 ;;
    esac
done

WORK=build/verify
rm -rf "$WORK"; mkdir -p "$WORK"

# TCG by default, like `run`: the sweep then means the same thing on every
# machine that runs it. --kvm opts into the host's accelerator when it has one.
ACCEL=()
ACCEL_NAME=tcg
if [ "$USE_ACCEL" = 1 ]; then
    A="$(qemu_accel)"
    if [ "$A" != tcg ]; then ACCEL=(-accel "$A" -cpu host); ACCEL_NAME="$A"; fi
fi

FAIL_PATTERN='EXCEPTION|panic:|#GP|#PF|FATAL|kernel halted'

# Markers each gate requires. A gate passes only when EVERY one appeared, and the
# report says which was missing — "it timed out" is not a diagnosis.
LIVE_MARKERS=(
    'ramvol: live root ready'
    'root: ram0'
    'vfs: mounted /'
    'boot: /init.cse launched pid='
)
PERSIST_MARKERS=(
    'vfs: mounted /'
    'boot: /init.cse launched pid='
    'ALL PHASE-6 TESTS PASS'
)

echo "verify: building the images under test"
caustic-mk build kernel >/dev/null 2>&1 || { echo "verify: kernel build failed" >&2; exit 1; }
(cd userspace && caustic-mk build all >/dev/null 2>&1) || { echo "verify: userspace build failed" >&2; exit 1; }

case " $GATES " in *" live "*)
    bash scripts/mkiso.sh --profile desktop --out "$WORK/live.iso" >/dev/null ;;
esac
case " $GATES " in *" persist "*)
    # No live root in this ISO: the disk must be the only candidate, so a pass
    # cannot be the live path quietly standing in for the disk path. That also
    # exercises root_pick()'s no-module branch, which is the path every machine
    # with an installed system takes.
    #
    # `selftest`, not `smoke`: smoke replaces /init with the in-kernel gauntlet,
    # so it can never produce the "/init.cse launched" marker this gate requires.
    # selftest runs the FAT32 write suite AND still boots userspace, which is
    # what "the disk path works end to end" actually means. No root= either —
    # letting root_pick choose is the behaviour under test.
    bash scripts/mkiso.sh --no-live --cmdline "selftest" --out "$WORK/persist.iso" >/dev/null
    "$PY" scripts/mkroot.py --profile verify --img "$WORK/pristine.img" -q ;;
esac

TOTAL_PASS=0
TOTAL_FAIL=0

run_one() {   # run_one <gate> <smp> <index>
    local gate="$1" smp="$2" idx="$3"
    local log="$WORK/$gate-smp$smp-$idx.log"
    # The machine comes from qemu-args.sh like everywhere else. Building it here
    # by hand made this the THIRD copy of the device line, and it had already
    # drifted from the other two: memory hardcoded at 512M long after the default
    # became 64M, and no sound card at all — so the audio driver was exercised by
    # `run` and by the test scripts, and silently not by the gate.
    local disk=""
    if [ "$gate" != live ]; then
        disk="$WORK/disk-smp$smp-$idx.img"
        cp "$WORK/pristine.img" "$disk"
    fi
    local iso="$WORK/live.iso"
    [ "$gate" = live ] || iso="$WORK/persist.iso"

    # A port per run. The machine forwards a host port to the guest's httpd, and
    # twenty boots at once all asked for 18080 — nineteen of them died at startup
    # with "Could not set up host forwarding rule" and were reported as a kernel
    # that printed no markers. Concurrency turned a fixed port into a bug.
    local port=$((18100 + smp * 1000 + idx))

    local args
    mapfile -t args < <(
        QEMU_ISO="$iso" QEMU_DISK="$disk" QEMU_SMP="$smp" QEMU_ACCEL="$ACCEL_NAME" \
        QEMU_HTTPD_PORT="$port" \
        bash -c 'source scripts/qemu-args.sh; printf "%s\n" "${QEMU_ARGS[@]}"'
    )
    args+=(-serial stdio -display none)

    qemu-system-x86_64 "${args[@]}" > "$log" 2>&1 &
    local qpid=$!
    local deadline=$((SECONDS + TOUT))
    local -n markers="$([ "$gate" = live ] && echo LIVE_MARKERS || echo PERSIST_MARKERS)"

    # Wait for ALL markers, not for one of them. Waiting on a single "last"
    # marker means depending on the order the kernel happens to print in, and
    # that order is not what the list documents: the FAT32 suite finishes before
    # userspace is spawned, so keying on ALL PHASE-6 TESTS PASS killed qemu while
    # the log still read "boot: open /init.cse" — reported as a missing marker,
    # blamed on the kernel, and intermittent because it was a race with the kill.
    while kill -0 "$qpid" 2>/dev/null; do
        local raw_now; raw_now="$(tr -d '\000' < "$log")"
        local seen=1
        for m in "${markers[@]}"; do
            echo "$raw_now" | grep -qaF "$m" || { seen=0; break; }
        done
        [ "$seen" = 1 ] && break
        echo "$raw_now" | grep -qaE "$FAIL_PATTERN" && break
        [ "$SECONDS" -ge "$deadline" ] && break
        sleep 0.2
    done
    kill -9 "$qpid" 2>/dev/null
    wait "$qpid" 2>/dev/null      # reap, so the image lock is gone before the next run

    local raw; raw="$(tr -d '\000' < "$log")"
    [ "$KEEP" = 1 ] || rm -f "$WORK/disk-smp$smp-$idx.img"

    local hit; hit="$(echo "$raw" | grep -aE "$FAIL_PATTERN" | head -1)"
    if [ -n "$hit" ]; then
        echo "  $gate smp=$smp run=$idx: FAIL  ${hit:0:70}"
        echo "    log: $log"; KEEP=1
        return 1
    fi
    local missing=()
    for m in "${markers[@]}"; do
        echo "$raw" | grep -qaF "$m" || missing+=("$m")
    done
    if [ "${#missing[@]}" -ne 0 ]; then
        echo "  $gate smp=$smp run=$idx: FAIL  missing: ${missing[*]}"
        echo "    log: $log"; KEEP=1
        return 1
    fi
    [ "$KEEP" = 1 ] || rm -f "$log"
    return 0
}

# Boots are independent, so they run concurrently — bounded by cores, minus a
# couple so the host stays usable. Serially, a sweep spent almost all of its
# wall time with the machine idle: a boot reaches its last marker in about 1.3
# seconds, and everything after that is waiting for the next one to start.
JOBS="${JOBS:-$(( $(nproc 2>/dev/null || echo 4) - 2 ))}"
[ "$JOBS" -lt 1 ] && JOBS=1

RESULTS="$WORK/results"
mkdir -p "$RESULTS"

for gate in $GATES; do
    echo
    echo "=== gate: $gate ($ACCEL_NAME, $JOBS at a time) ==="
    for smp in ${SMPS//,/ }; do
        running=0
        for i in $(seq 1 "$RUNS"); do
            {
                if run_one "$gate" "$smp" "$i" > "$RESULTS/$gate-$smp-$i.out" 2>&1
                    then echo pass > "$RESULTS/$gate-$smp-$i.rc"
                    else echo fail > "$RESULTS/$gate-$smp-$i.rc"
                fi
            } &
            running=$((running+1))
            if [ "$running" -ge "$JOBS" ]; then wait -n 2>/dev/null || wait; running=$((running-1)); fi
        done
        wait
        pass=0; fail=0
        for i in $(seq 1 "$RUNS"); do
            if [ "$(cat "$RESULTS/$gate-$smp-$i.rc" 2>/dev/null)" = pass ]
                then pass=$((pass+1))
                else fail=$((fail+1)); cat "$RESULTS/$gate-$smp-$i.out" 2>/dev/null
            fi
        done
        echo "  smp=$smp: $pass/$((pass+fail))"
        TOTAL_PASS=$((TOTAL_PASS+pass)); TOTAL_FAIL=$((TOTAL_FAIL+fail))
    done
done

echo
echo "=== $TOTAL_PASS/$((TOTAL_PASS+TOTAL_FAIL)) boots passed ==="
[ "$KEEP" = 1 ] && echo "logs kept in $WORK/"
[ "$TOTAL_FAIL" -eq 0 ] || exit 1
