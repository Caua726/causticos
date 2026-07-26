#!/bin/bash
# test-link.sh — pull the cable, from outside the machine.
#
# The one thing the guest cannot test about itself: a link going down. Every
# boot so far has had a link that was up before the driver looked and stayed
# up, so nd_link_up returning 0 was code that had never run — and a driver
# returning a plausible constant is indistinguishable from one reading STATUS
# until the day someone is debugging a dead port.
#
# So the host drives it through the QEMU monitor. linkt watches the register
# and reports transitions; this script cuts the link and restores it. Neither
# side can fake the result: the guest does not know when the cable was pulled,
# and the host cannot see the register.
#
# It also checks the other thing a boot alone cannot show — whether two NICs
# ended up sharing an interrupt line. On a q35 machine they usually do, which
# is what makes every handler's "is this mine?" check load-bearing rather than
# decorative.
set -e
cd "$(cd "$(dirname "$0")/.." && pwd)"

source "$(dirname "$0")/portable.sh"

CSE=userspace/build/linkt.cse
[ -f "$CSE" ] || { echo "$CSE missing — run: (cd userspace && caustic-mk build all)"; exit 1; }
[ -f build/causticos.iso ] || { echo "build/causticos.iso missing"; exit 1; }

IMG=build/test-link.img
"$PY" scripts/mkroot.py --profile base --init linkt --img "$IMG" -q

MON=/tmp/causticos-link-mon.$$
LOG=$(mktemp)
QEMU_DISK="$IMG"
QEMU_KVM=1
source scripts/qemu-args.sh

qemu-system-x86_64 "${QEMU_ARGS[@]}" \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio -display none > "$LOG" 2>&1 &
QPID=$!

mon() { printf '%s\n' "$1" | socat - "unix-connect:$MON" >/dev/null 2>&1 || true; }
cleanup() { kill -9 $QPID 2>/dev/null || true; wait $QPID 2>/dev/null || true; rm -f "$MON"; }
trap cleanup EXIT

# Wait for the guest to say it is watching, so the "up" it sampled first is
# the genuine initial state rather than a race with our own set_link.
for _ in $(seq 1 200); do
    tr -d '\000' < "$LOG" | grep -q "linkt: watching" && break
    kill -0 $QPID 2>/dev/null || break
    sleep 0.1
done
if ! tr -d '\000' < "$LOG" | grep -q "linkt: watching"; then
    echo "=== link: FAIL (guest never started watching) ==="
    tr -d '\000' < "$LOG" | tail -15
    exit 1
fi

# net0 is the e1000, the one with a real STATUS register to read.
sleep 0.5
mon "set_link net0 off"
sleep 1.5
mon "set_link net0 on"
sleep 2.0

for _ in $(seq 1 100); do
    tr -d '\000' < "$LOG" | grep -qE "linkt: (ALL PASS|.*FAIL)" && break
    kill -0 $QPID 2>/dev/null || break
    sleep 0.1
done

RAW=$(tr -d '\000' < "$LOG")
rm -f "$LOG"
echo "$RAW" | grep -E "^linkt:" || true

# Did any two devices land on the same interrupt line? Not something to
# require — it depends on the machine's PIRQ routing — but worth reporting,
# because it is what makes the shared-line checks in every handler matter.
SHARED=$(echo "$RAW" | grep -c "sharing vector" || true)
echo "--- interrupt lines shared by two or more devices: $SHARED ---"
echo "$RAW" | grep "sharing vector" | head -4 || true

if echo "$RAW" | grep -q "linkt: ALL PASS"; then
    echo "=== link: PASS ==="
    exit 0
fi
echo "=== link: FAIL ==="
exit 1
