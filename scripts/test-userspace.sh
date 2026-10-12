#!/bin/bash
# test-userspace.sh — every ring-3 test there is.
#
# Two kinds, and the difference is which side the test is driven from:
# the SELF-TESTS are programs that decide for themselves and all run in
# ONE boot; the DRIVEN ones are steered from the host — typing at the
# prompt, pulling the cable, measuring the sound QEMU recorded — and each
# needs its own machine and its own disk image.
#
# The suite used to boot a machine per test: nineteen boots to run about twenty
# seconds of testing, and thirty seconds of each was a machine sitting idle
# after its program had already printed the answer. A suite slow enough to skip
# is a suite nobody runs before a commit, which is the only moment it is for.
#
# /init here is runall.cse, which spawns each test in turn and prints a line
# around each one. Failures stay attributable: every test names itself in its
# own verdict, and a test that dies without printing is visible as a name with
# no verdict rather than as silence.
#
# The host peers stay up for the whole boot. They are on different ports and
# the guest dials them one at a time, so one set serves the lot.
#
#   scripts/test-userspace.sh
#   ONLINE=1 scripts/test-userspace.sh    also HTTPS against real sites (needs
#                                         the internet; reported NOT RUN, with
#                                         the reason, when the host is offline)
set -e
cd "$(cd "$(dirname "$0")/.." && pwd)"

source "$(dirname "$0")/portable.sh"

# The in-guest phase ends at a VERDICT, not at a clock: a run that is still
# printing is still working. STALL is how long the log may be silent before the
# guest counts as hung, and CEILING is the backstop for the whole phase. A flat
# 120 s deadline used to cut a suite that had merely grown past it, and the
# tests whose verdict never came were then reported as failures.
STALL="${STALL:-120}"
CEILING="${CEILING:-300}"
START=$SECONDS
ISO=build/selftests.iso
LOG=$(mktemp)

[ -f build/causticos.iso ] || { echo "build/causticos.iso missing"; exit 1; }
[ -f userspace/build/runall.cse ] || { echo "runall not built"; exit 1; }

if [ ! -f build/certs/srv.pem ]; then bash scripts/make-test-certs.sh >/dev/null; fi
: > build/certs/empty.pem

# One image, one process. Everything the harnesses reach for goes on with
# --add; /init is the runner itself.
ADD=(--init runall)
add() { ADD+=(--add "$2"); }
for t in u64t kabi nett tcpt cryptot x509t appt pingt netdt httpt tlst kmapt tzt globt regext pagert cmdt imgt; do
    [ -f "userspace/build/$t.cse" ] && add x "userspace/build/$t.cse"
done
# What the tests reach for: the daemon they spawn, the programs they drive, and
# the certificate fixtures. Generated rather than committed — a certificate has
# an expiry date in it, and one checked into a repository is a test that starts
# failing on a day nobody picked.
for f in userspace/build/netd.cse userspace/build/ping.cse \
         userspace/build/wget.cse userspace/build/netsnoop.cse \
         userspace/build/shell.cse \
         build/certs/root.der build/certs/int.der build/certs/leaf.der \
         build/certs/wild.der build/certs/expired.der build/certs/future.der \
         build/certs/rogue.der build/certs/under.der build/certs/notca.der \
         build/certs/ecroot.der build/certs/ecleaf.der \
         build/certs/ca.pem build/certs/empty.pem; do
    [ -f "$f" ] && add x "$f"
done
# cmdt's cases: command lines with GNU's answers (scripts/gen-cmdt.py).
ADD+=(--add userspace/tests/cmdt.cases:/cmdt/cases)
# tzt's: instants with CPython zoneinfo's answers (scripts/gen-tzt.py).
ADD+=(--add userspace/tests/tzt.cases:/tzt/cases)

# One set of peers for the whole boot. Different ports, so they coexist; the
# guest dials them one at a time.
"$PY" scripts/echo-server.py 17777 "$CEILING" >/dev/null 2>&1 & E1=$!
"$PY" scripts/http-server.py 17780 "$CEILING" >/dev/null 2>&1 & E2=$!
"$PY" scripts/http-server.py 17782 "$CEILING" \
    build/certs/srvchain.pem build/certs/srv.key >/dev/null 2>&1 & E3=$!
sleep 0.4

# An ISO with the runner as /init — NOT a disk. The live root travels inside
# the image and OUTRANKS an attached disk, so building the harness as a disk
# meant the kernel mounted the ISO's ordinary desktop root and booted the
# compositor: every test reported MISSING and the suite blamed the tests. That
# is what this script did from the day the live root landed.
bash scripts/mkiso.sh --profile base "${ADD[@]}" --out "$ISO" >/dev/null

QEMU_ISO="$ISO"
QEMU_KVM=1
QEMU_HTTPD_PORT="${QEMU_HTTPD_PORT:-18081}"
# 18 test programs run in one guest. At the 64M default the image cache is
# squeezed during imgt, whose method is to read free memory around a spawn: the
# reclaim it triggers then looks like the spawn giving memory back ("spawn 0
# cost -3668 KiB"). The cache yielding under pressure is by design; the
# measurement just needs room, so the suite gives the guest 256M.
QEMU_MEM="${QEMU_MEM:-256M}"
source scripts/qemu-args.sh

qemu-system-x86_64 "${QEMU_ARGS[@]}" -serial stdio -display none > "$LOG" 2>&1 &
QPID=$!
cleanup() {
    kill -9 $QPID 2>/dev/null || true; wait $QPID 2>/dev/null || true
    kill $E1 $E2 $E3 2>/dev/null || true
    wait $E1 $E2 $E3 2>/dev/null || true
}
trap cleanup EXIT

# Stop at the verdict, not at the clock: the deadline is for a HANG, not for
# the running time of a success. The clock that matters is how long the log has
# been silent — a run that is still printing is still working.
LAST_SIZE=-1; LAST_CHANGE=$SECONDS
while kill -0 $QPID 2>/dev/null; do
    OUT=$(tr -d '\000' < "$LOG")
    if echo "$OUT" | grep -qE "runall: DONE|EXCEPTION|panic:|kernel halted"; then break; fi
    SIZE=$(wc -c < "$LOG")
    if [ "$SIZE" != "$LAST_SIZE" ]; then LAST_SIZE=$SIZE; LAST_CHANGE=$SECONDS; fi
    if [ $((SECONDS - LAST_CHANGE)) -ge "$STALL" ]; then HUNG=1; break; fi
    if [ $((SECONDS - START)) -ge "$CEILING" ]; then HUNG=1; break; fi
    sleep 0.1
done
kill -9 $QPID 2>/dev/null || true
wait $QPID 2>/dev/null || true

RAW=$(tr -d '\000' < "$LOG")
cp "$LOG" /tmp/ut-selftests.log

PASS=0; FAIL=0; FAILED=""; NOVERDICT=0; NOVERDICTS=""; NOTRUN=0; NOTRAN=""

# The lines the runner printed for ONE test: from its `<<< name` line to the
# next one. The detail under a failure used to be grepped out of the WHOLE log,
# which is how a test with no verdict at all got reported with another test's
# failure line printed under it.
section() {
    awk -v t="$1" '
        $0 ~ "^runall: <<< " t "($| )" { inside = 1; print; next }
        /^runall: <<< / { inside = 0 }
        inside { print }
    ' <<< "$RAW"
}

# THE EXIT CODE IS THE VERDICT. Matching each test's printed marker meant the
# harness had to know how every one of them spells success — and it guessed
# wrong twice in a row, reporting a green kabi ("kabi: PASS", not "ALL PASS")
# and a green appt as failures. A process that returns 0 succeeded; that is
# uniform, it is what runall already reports, and it cannot drift from what the
# test actually decided. The printed line is kept as detail, not as evidence.
#
# Three outcomes, and the third one is the point: a test the runner never
# reached has NO VERDICT, which is not the same as a test that ran and failed,
# and is not reported as one.
for t in u64t kabi nett tcpt cryptot x509t appt pingt netdt httpt tlst kmapt tzt globt regext pagert cmdt imgt; do
    printf '%-9s ' "$t"
    if echo "$RAW" | grep -q "^runall: <<< $t MISSING"; then
        echo "SKIP  (not built)"
        continue
    fi
    SEC=$(section "$t")
    n=$(echo "$SEC" | grep -oE "^$t: [0-9]+ checks" | head -1 | grep -oE '[0-9]+' || true)
    if echo "$RAW" | grep -q "^runall: <<< $t exit=0"; then
        if [ -n "$n" ]; then echo "PASS ($n checks)"; else echo "PASS"; fi
        PASS=$((PASS+1))
    elif echo "$RAW" | grep -q "^runall: <<< $t exit="; then
        echo "FAIL"
        echo "$SEC" | grep -E "^$t: |  FAIL " | head -4 || true
        FAIL=$((FAIL+1)); FAILED="$FAILED $t"
    else
        echo "NO VERDICT  (the runner stopped before it)"
        NOVERDICT=$((NOVERDICT+1)); NOVERDICTS="$NOVERDICTS $t"
    fi
done

if ! echo "$RAW" | grep -q "runall: DONE"; then
    echo "=== selftests: the runner never finished${HUNG:+ — the guest was silent for ${STALL}s}: $PASS passed, $NOVERDICT with no verdict${FAILED:+, $FAIL failed —$FAILED} (log: /tmp/ut-selftests.log) ==="
    exit 1
fi

# The tests that CANNOT share a machine, each in its own. They are driven from
# outside — typing at the prompt, pulling the cable, measuring the sound the
# host recorded — so the guest is the subject rather than the host of the test,
# and they need their own boot and their own disk image.
DRIVEN=(
    "linkt|scripts/test-link.sh|host pulled the cable"
    "httpd|scripts/test-httpd.sh|host fetched from the guest"
    "cseforms|scripts/test-cse-forms.sh|pure, compat and bundle run and print"
    "shellnet|scripts/test-shell-net.sh|wget typed at the prompt"
    "runallwait|scripts/test-runall.sh|delayed nonzero verdict"
)
# The one that needs the internet, only when asked for: a default run has to
# give the same answer on a machine with no route out.
if [ "${ONLINE:-0}" = 1 ]; then
    DRIVEN+=("httpsreal|scripts/test-https-real.sh|real sites, real roots, real refusals")
fi

# The ones that MEASURE TIME, run one at a time. Each of these records real
# audio off the host and checks how long a tone lasted, to a ±25% tolerance —
# so six QEMUs competing for the same cores is enough to make a correct system
# report half a tone. They were in the pool above and failed roughly one run in
# two, on a different test each time, which is the signature of load rather
# than of a bug. Tightening nothing and loosening nothing: just not measuring
# a clock while five other machines fight for it.
TIMED=(
    "audio|scripts/test-audio.sh|@grep -oE 'ch0: [0-9.]+Hz'"
    "stream|scripts/test-stream.sh|@grep -oE '[0-9]+ KiB/s from the network'"
    "soundd|scripts/test-soundd.sh|mixed two, preempted, resumed"
    "record|scripts/test-record.sh|@grep -oE '[0-9]+ frames are the source, byte for byte'"
)

# AT THE SAME TIME. They are separate machines with separate disk images and
# separate port forwards, so nothing about them was ever sequential except that
# they used to be — eight boots in a row was most of the wall clock.
#
# xargs does the pooling. A hand-rolled one built on `wait -n` looked right and
# did not finish: the driven set took longer under it than run one at a time,
# for reasons not worth chasing when the tool that does this correctly has
# been in every unix for thirty years.
# One rooted ISO for the whole fan-out, built HERE because mkiso stages through
# a single build/iso directory and these run at the same time. The disk each of
# them seeds is what the kernel must mount, and root= is what says so — the live
# root inside the ISO outranks a disk otherwise.
ROOTED_ISO=build/rooted.iso
bash scripts/mkiso.sh --cmdline "root=ahci-p0" --out "$ROOTED_ISO" >/dev/null
export ROOTED_ISO

NJOBS="${JOBS:-}"
if [ -z "$NJOBS" ]; then
    NJOBS=$(( $(nproc 2>/dev/null || echo 4) / 2 ))
    [ "$NJOBS" -lt 2 ] && NJOBS=2
    [ "$NJOBS" -gt 6 ] && NJOBS=6
fi
RES=$(mktemp -d)
PLAN=$(mktemp)

PORT=18120
for entry in "${DRIVEN[@]}"; do
    name="${entry%%|*}"; rest="${entry#*|}"
    script="${rest%%|*}"
    PORT=$((PORT+1))
    printf '%s %s %s\n' "$PORT" "$name" "$script" >> "$PLAN"
done

RES="$RES" xargs -P "$NJOBS" -L 1 bash -c '
    t0=$SECONDS
    rc=0
    QEMU_HTTPD_PORT=$0 bash "$2" >/tmp/ut-$1.log 2>&1 || rc=$?
    printf "%s|%s\n" "$rc" "$((SECONDS-t0))" > "$RES/$1"
' < "$PLAN"
rm -f "$PLAN"

# Then the timed ones, alone, with the pool drained.
for entry in "${TIMED[@]}"; do
    name="${entry%%|*}"; rest="${entry#*|}"; script="${rest%%|*}"
    PORT=$((PORT+1))
    t0=$SECONDS
    rc=0
    QEMU_HTTPD_PORT=$PORT bash "$script" >/tmp/ut-$name.log 2>&1 || rc=1
    printf "%s|%s\n" "$rc" "$((SECONDS-t0))" > "$RES/$name"
done
DRIVEN+=("${TIMED[@]}")

# Reported in list order, not completion order: a suite whose output shuffles
# between runs cannot be diffed against the last one.
for entry in "${DRIVEN[@]}"; do
    name="${entry%%|*}"; rest="${entry#*|}"; note="${rest#*|}"
    printf '%-9s ' "$name"
    if [ ! -f "$RES/$name" ]; then
        echo "FAIL  (never reported)"
        FAIL=$((FAIL+1)); FAILED="$FAILED $name"
        continue
    fi
    IFS='|' read -r rc secs < "$RES/$name"
    if [ "$rc" = 0 ]; then
        label="$note"
        # A note beginning with @ pulls the number out of the log, so a test
        # reports what it MEASURED rather than a fixed sentence that stays true
        # after the measuring stops happening.
        case "$note" in
            @*) label=$(eval "${note#@}" < /tmp/ut-$name.log | head -1 || true) ;;
        esac
        echo "PASS ($label, ${secs}s)"
        PASS=$((PASS+1))
    elif [ "$rc" = 2 ]; then
        # Exit 2 is a test saying it could not run here — the host offline,
        # say. Neither a pass nor a failure of the system, and said as such.
        echo "NOT RUN ($(grep -m1 '^not run: ' /tmp/ut-$name.log | sed 's/^not run: //'))"
        NOTRUN=$((NOTRUN+1)); NOTRAN="$NOTRAN $name"
    else
        echo "FAIL  (see /tmp/ut-$name.log)"
        grep -E "FAIL|panic:" /tmp/ut-$name.log | head -4 || true
        FAIL=$((FAIL+1)); FAILED="$FAILED $name"
    fi
done
rm -rf "$RES"

if [ -n "$FAILED" ] || [ -n "$NOVERDICTS" ]; then
    echo "=== userspace: $PASS passed, $FAIL failed —$FAILED${NOVERDICT:+, $NOVERDICT with no verdict —$NOVERDICTS}${NOTRAN:+, $NOTRUN not run —$NOTRAN}  ($((SECONDS-START))s) ==="
    exit 1
fi
echo "=== userspace: $PASS passed, 0 failed${NOTRAN:+, $NOTRUN not run —$NOTRAN}  ($((SECONDS-START))s) ==="
