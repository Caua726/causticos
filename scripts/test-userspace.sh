#!/bin/bash
# test-userspace.sh — run every ring-3 self-test, each in its own boot.
#
# verify.sh is the KERNEL gate: it boots the smoke flavour and checks the
# kernel's own markers, many times, looking for races. This is the other half —
# the tests that run as programs, against the syscall ABI, the way a user's
# code will.
#
# One boot per test, because a self-test that shares a machine with another
# one is a self-test whose failures have two possible causes.
#
#   scripts/test-userspace.sh          # all of them
#   scripts/test-userspace.sh nett     # just one
set -e
cd "$(cd "$(dirname "$0")/.." && pwd)"

# name:timeout:extra-files-to-seed
TESTS=(
    "u64t:30:"
    "nett:40:"
    "kabi:30:"
    "pingt:60:userspace/build/ping.cse"
    "netdt:70:userspace/build/netd.cse"
)

WANT="${1:-}"
PASS=0
FAIL=0
FAILED=""

for entry in "${TESTS[@]}"; do
    name="${entry%%:*}"
    rest="${entry#*:}"
    tout="${rest%%:*}"
    extra="${rest#*:}"
    [ -n "$WANT" ] && [ "$WANT" != "$name" ] && continue

    printf '%-8s ' "$name"
    if bash scripts/run-test.sh "$name" "$tout" $extra >/tmp/ut-$name.log 2>&1; then
        # Echo the count so a test that silently stopped checking things is
        # visible as a number that dropped, not just as a green line.
        n=$(grep -oE "^$name: [0-9]+ checks" /tmp/ut-$name.log | head -1 | grep -oE '[0-9]+' || true)
        if [ -n "$n" ]; then echo "PASS ($n checks)"; else echo "PASS"; fi
        PASS=$((PASS+1))
    else
        echo "FAIL  (see /tmp/ut-$name.log)"
        grep -E "  FAIL |panic:|EXCEPTION" /tmp/ut-$name.log | head -5 || true
        FAIL=$((FAIL+1))
        FAILED="$FAILED $name"
    fi
done

# linkt needs the host to drive a QEMU monitor, so it has its own runner
# rather than a line in the table above.
if [ -z "$WANT" ] || [ "$WANT" = "linkt" ]; then
    printf '%-8s ' "linkt"
    if bash scripts/test-link.sh >/tmp/ut-linkt.log 2>&1; then
        echo "PASS (host pulled the cable)"
        PASS=$((PASS+1))
    else
        echo "FAIL  (see /tmp/ut-linkt.log)"
        grep -E "FAIL|panic:" /tmp/ut-linkt.log | head -5 || true
        FAIL=$((FAIL+1))
        FAILED="$FAILED linkt"
    fi
fi

echo "=== userspace: $PASS passed, $FAIL failed${FAILED:+ ($FAILED)} ==="
[ "$FAIL" -eq 0 ]
