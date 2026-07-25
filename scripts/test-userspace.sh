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
    "tcpt:60:"
    "kabi:30:"
    "cryptot:60:"
    "x509t:90:build/certs/root.der build/certs/int.der build/certs/leaf.der build/certs/wild.der build/certs/expired.der build/certs/future.der build/certs/rogue.der build/certs/under.der build/certs/notca.der build/certs/ecroot.der build/certs/ecleaf.der build/certs/ca.pem"
    "pingt:60:userspace/build/ping.cse"
    "netdt:70:userspace/build/netd.cse"
    "httpt:150:userspace/build/netd.cse userspace/build/wget.cse"
    "tlst:180:userspace/build/netd.cse build/certs/ca.pem build/certs/empty.pem"
)

# The certificate fixtures are generated rather than committed. A certificate
# has an expiry date in it, and one checked into a repository is a test that
# starts failing on a day nobody picked.
if [ ! -f build/certs/srv.pem ]; then
    bash scripts/make-test-certs.sh >/dev/null
fi
# An empty trust store, so a test can prove that a perfect chain with
# nothing to anchor it in is refused.
: > build/certs/empty.pem

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
    # netdt and httpt both need a peer that is NOT our code — a loopback of
    # two of our own connections proves they agree with each other, not that
    # they agree with anyone else. SLIRP presents the host as 10.0.2.2, so a
    # listener here is what the guest dials.
    HELPER_PID=""
    if [ "$name" = "netdt" ]; then
        python3 scripts/echo-server.py 17777 "$tout" >/dev/null 2>&1 &
        HELPER_PID=$!
        sleep 0.3
    fi
    if [ "$name" = "httpt" ]; then
        python3 scripts/http-server.py 17780 "$tout" >/dev/null 2>&1 &
        HELPER_PID=$!
        sleep 0.3
    fi
    if [ "$name" = "tlst" ]; then
        # OpenSSL's server side, pinned to TLS 1.3. Two implementations by one
        # author agree with each other; this one refuses anything that is not
        # what the RFC says, and refuses without explaining, which is exactly
        # the check that is worth having.
        python3 scripts/http-server.py 17782 "$tout" \
            build/certs/srvchain.pem build/certs/srv.key >/dev/null 2>&1 &
        HELPER_PID=$!
        sleep 0.5
    fi
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
    # `[ -n ... ] && ...` would abort the whole script under set -e whenever
    # the variable is empty, which silently dropped every test after this one.
    if [ -n "$HELPER_PID" ]; then
        kill $HELPER_PID 2>/dev/null || true
        wait $HELPER_PID 2>/dev/null || true
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

# shellnet types at the real prompt, so it needs the monitor too — and it is
# the only test that proves the machine you BOOT is wired up rather than the
# one a test assembled for itself.
if [ -z "$WANT" ] || [ "$WANT" = "shellnet" ]; then
    printf '%-8s ' "shellnet"
    if bash scripts/test-shell-net.sh >/tmp/ut-shellnet.log 2>&1; then
        echo "PASS (wget typed at the prompt)"
        PASS=$((PASS+1))
    else
        echo "FAIL  (see /tmp/ut-shellnet.log)"
        grep -E "FAIL|panic:" /tmp/ut-shellnet.log | head -5 || true
        FAIL=$((FAIL+1))
        FAILED="$FAILED shellnet"
    fi
fi

echo "=== userspace: $PASS passed, $FAIL failed${FAILED:+ ($FAILED)} ==="
[ "$FAIL" -eq 0 ]
