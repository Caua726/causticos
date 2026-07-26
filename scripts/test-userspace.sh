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
set -e
cd "$(cd "$(dirname "$0")/.." && pwd)"

TOUT="${TOUT:-120}"
START=$SECONDS
IMG=build/selftests.img
LOG=$(mktemp)

[ -f build/causticos.iso ] || { echo "build/causticos.iso missing"; exit 1; }
[ -f userspace/build/runall.cse ] || { echo "runall not built"; exit 1; }

if [ ! -f build/certs/srv.pem ]; then bash scripts/make-test-certs.sh >/dev/null; fi
: > build/certs/empty.pem

qemu-img create -f raw "$IMG" 64M >/dev/null 2>&1
mkfs.fat -F 32 -n CAUSTICOS "$IMG" >/dev/null 2>&1
add() { python3 scripts/fat32_add_file.py "$IMG" addfilebin "$(basename "$2")" "$2" >/dev/null; }

python3 scripts/fat32_add_file.py "$IMG" addfilebin init.cse userspace/build/runall.cse >/dev/null
for t in u64t kabi nett tcpt cryptot x509t appt pingt netdt httpt tlst; do
    [ -f "userspace/build/$t.cse" ] && add x "userspace/build/$t.cse"
done
# What the tests reach for: the daemon they spawn, the programs they drive, and
# the certificate fixtures. Generated rather than committed — a certificate has
# an expiry date in it, and one checked into a repository is a test that starts
# failing on a day nobody picked.
for f in userspace/build/netd.cse userspace/build/ping.cse \
         userspace/build/wget.cse userspace/build/netsnoop.cse \
         build/certs/root.der build/certs/int.der build/certs/leaf.der \
         build/certs/wild.der build/certs/expired.der build/certs/future.der \
         build/certs/rogue.der build/certs/under.der build/certs/notca.der \
         build/certs/ecroot.der build/certs/ecleaf.der \
         build/certs/ca.pem build/certs/empty.pem; do
    [ -f "$f" ] && add x "$f"
done

# One set of peers for the whole boot. Different ports, so they coexist; the
# guest dials them one at a time.
python3 scripts/echo-server.py 17777 "$TOUT" >/dev/null 2>&1 & E1=$!
python3 scripts/http-server.py 17780 "$TOUT" >/dev/null 2>&1 & E2=$!
python3 scripts/http-server.py 17782 "$TOUT" \
    build/certs/srvchain.pem build/certs/srv.key >/dev/null 2>&1 & E3=$!
sleep 0.4

QEMU_DISK="$IMG"
QEMU_KVM=1
QEMU_HTTPD_PORT="${QEMU_HTTPD_PORT:-18081}"
source scripts/qemu-args.sh

qemu-system-x86_64 "${QEMU_ARGS[@]}" -serial stdio -display none > "$LOG" 2>&1 &
QPID=$!
cleanup() {
    kill -9 $QPID 2>/dev/null || true; wait $QPID 2>/dev/null || true
    kill $E1 $E2 $E3 2>/dev/null || true
    wait $E1 $E2 $E3 2>/dev/null || true
}
trap cleanup EXIT

# Stop at the verdict, not at the timeout: the deadline is for a HANG, not for
# the running time of a success.
DEADLINE=$((SECONDS + TOUT))
while kill -0 $QPID 2>/dev/null; do
    OUT=$(tr -d '\000' < "$LOG")
    if echo "$OUT" | grep -qE "runall: DONE|EXCEPTION|panic:|kernel halted"; then break; fi
    [ $SECONDS -ge $DEADLINE ] && break
    sleep 0.1
done
kill -9 $QPID 2>/dev/null || true
wait $QPID 2>/dev/null || true

RAW=$(tr -d '\000' < "$LOG")
cp "$LOG" /tmp/ut-selftests.log

PASS=0; FAIL=0; FAILED=""
# THE EXIT CODE IS THE VERDICT. Matching each test's printed marker meant the
# harness had to know how every one of them spells success — and it guessed
# wrong twice in a row, reporting a green kabi ("kabi: PASS", not "ALL PASS")
# and a green appt as failures. A process that returns 0 succeeded; that is
# uniform, it is what runall already reports, and it cannot drift from what the
# test actually decided. The printed line is kept as detail, not as evidence.
for t in u64t kabi nett tcpt cryptot x509t appt pingt netdt httpt tlst; do
    printf '%-9s ' "$t"
    if echo "$RAW" | grep -q "^runall: <<< $t MISSING"; then
        echo "SKIP  (not built)"
        continue
    fi
    n=$(echo "$RAW" | grep -oE "^$t: [0-9]+ checks" | head -1 | grep -oE '[0-9]+' || true)
    if echo "$RAW" | grep -q "^runall: <<< $t exit=0"; then
        if [ -n "$n" ]; then echo "PASS ($n checks)"; else echo "PASS"; fi
        PASS=$((PASS+1))
    else
        echo "FAIL"
        echo "$RAW" | grep -E "^$t: |  FAIL |^runall: <<< $t" | head -4 || true
        FAIL=$((FAIL+1)); FAILED="$FAILED $t"
    fi
done

if ! echo "$RAW" | grep -q "runall: DONE"; then
    echo "=== selftests: the runner never finished (log: /tmp/ut-selftests.log) ==="
    exit 1
fi

# The tests that CANNOT share a machine, each in its own. They are driven from
# outside — typing at the prompt, pulling the cable, measuring the sound the
# host recorded — so the guest is the subject rather than the host of the test,
# and they need their own boot and their own disk image.
DRIVEN=(
    "linkt|scripts/test-link.sh|host pulled the cable"
    "httpd|scripts/test-httpd.sh|host fetched from the guest"
    "cseforms|scripts/test-cse-forms.sh|pure, compat and bundle"
    "audio|scripts/test-audio.sh|@grep -oE 'ch0: [0-9.]+Hz'"
    "stream|scripts/test-stream.sh|@grep -oE '[0-9]+ KiB/s from the network'"
    "soundd|scripts/test-soundd.sh|mixed two, preempted, resumed"
    "record|scripts/test-record.sh|@grep -oE '[0-9]+ frames'"
    "shellnet|scripts/test-shell-net.sh|wget typed at the prompt"
)

# AT THE SAME TIME. They are separate machines with separate disk images and
# separate port forwards, so nothing about them was ever sequential except that
# they used to be — eight boots in a row was most of the wall clock.
#
# xargs does the pooling. A hand-rolled one built on `wait -n` looked right and
# did not finish: the driven set took longer under it than run one at a time,
# for reasons not worth chasing when the tool that does this correctly has
# been in every unix for thirty years.
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
    QEMU_HTTPD_PORT=$0 bash "$2" >/tmp/ut-$1.log 2>&1 || rc=1
    printf "%s|%s\n" "$rc" "$((SECONDS-t0))" > "$RES/$1"
' < "$PLAN"
rm -f "$PLAN"

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
    else
        echo "FAIL  (see /tmp/ut-$name.log)"
        grep -E "FAIL|panic:" /tmp/ut-$name.log | head -4 || true
        FAIL=$((FAIL+1)); FAILED="$FAILED $name"
    fi
done
rm -rf "$RES"

if [ -n "$FAILED" ]; then
    echo "=== userspace: $PASS passed, $FAIL failed —$FAILED  ($((SECONDS-START))s) ==="
    exit 1
fi
echo "=== userspace: $PASS passed, 0 failed  ($((SECONDS-START))s) ==="
