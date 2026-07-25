#!/bin/bash
set +e
# Relative to THIS script, never an absolute path: verify.sh is run from git
# worktrees, and a hardcoded path silently validated the main checkout instead
# of the tree you were editing.
cd "$(cd "$(dirname "$0")/.." && pwd)"
SMP="${1:-4}"
RUNS="${2:-20}"
TOUT="${3:-8}"

# KVM makes a 20-run sweep take seconds instead of minutes; it has been usable
# since the SYSRET/SS-RPL fix (iretq under KVM #GP'd when SS came back RPL 0).
QEMU_KVM=1
QEMU_SMP="$SMP"
source scripts/qemu-args.sh

if [ ! -f /tmp/disk.pristine.img ] || [ build/causticos.iso -nt /tmp/disk.pristine.img ]; then
  qemu-img create -f raw /tmp/disk.pristine.img 64M >/dev/null 2>&1
  mkfs.fat -F 32 -n CAUSTICOS /tmp/disk.pristine.img >/dev/null 2>&1
  python3 scripts/fat32_add_file.py /tmp/disk.pristine.img addfile hello.txt "Hello from causticos FAT32!" >/dev/null
  python3 scripts/fat32_add_file.py /tmp/disk.pristine.img addfile bigfile.bin "$(python3 -c 'print("A"*600 + "B"*600)')" >/dev/null
  python3 scripts/fat32_add_file.py /tmp/disk.pristine.img addfile "long-name-with-spaces and mixed case.txt" "LFN content here" >/dev/null
  python3 scripts/fat32_add_file.py /tmp/disk.pristine.img mkdir docs >/dev/null
  python3 scripts/fat32_add_file.py /tmp/disk.pristine.img addfile readme.md "# Docs readme\n\nInside docs subdir." 8 >/dev/null
  python3 scripts/make_init_cse.py /tmp/init.cse >/dev/null 2>&1
  python3 scripts/fat32_add_file.py /tmp/disk.pristine.img addfilebin init.cse /tmp/init.cse >/dev/null 2>&1
fi

PASS=0
FAIL=0
for i in $(seq 1 "$RUNS"); do
  cp /tmp/disk.pristine.img build/disk.img
  TMPLOG=$(mktemp)
  # Launch qemu DIRECTLY (no `timeout` wrapper). QPID is then qemu's own
  # pid, so the kill below terminates qemu itself. The old form ran qemu
  # as a child of `timeout` and killed the wrapper — orphaning qemu, which
  # kept build/disk.img locked and made the *next* run fail to boot (a
  # spurious "no-phase6 (timeout?)"). We enforce the hard deadline here.
  qemu-system-x86_64 \
    "${QEMU_ARGS[@]}" \
    -serial stdio -display none \
    > "$TMPLOG" 2>&1 &
  QPID=$!
  # Poll the serial until EVERY smoke has reported, or something fails, with a
  # hard deadline of TOUT seconds. Strip NULs before grep — the kernel's serial
  # output interleaves NUL bytes and a raw grep misses the marker, which used
  # to leave every run spinning to the deadline (and mis-report it).
  #
  # Stopping at the FIRST marker is what this used to do, and it silently
  # became wrong the moment a second smoke existed: the fat32 gauntlet finishes
  # first, qemu was killed, and the network smoke's verdict was cut off
  # mid-boot and read as absent. Every marker added below must also be added
  # to the pass criteria further down.
  DEADLINE=$((SECONDS + TOUT))
  while kill -0 $QPID 2>/dev/null; do
    OUT=$(tr -d '\000' < "$TMPLOG")
    if echo "$OUT" | grep -qE "EXCEPTION|panic:|kernel halted"; then
      break
    fi
    if echo "$OUT" | grep -qE "ALL PHASE-6 TESTS PASS|vfs\.test: ALL PASS" \
       && echo "$OUT" | grep -qE "netdev_smoke: (PASS|FAIL)"; then
      break
    fi
    if [ "$SECONDS" -ge "$DEADLINE" ]; then
      break
    fi
    sleep 0.2
  done
  kill -9 $QPID 2>/dev/null
  wait $QPID 2>/dev/null      # reap qemu so its disk-image lock is gone before the next cp

  RAW=$(tr -d '\000' < "$TMPLOG")
  rm -f "$TMPLOG"

  if echo "$RAW" | grep -qE "EXCEPTION|panic:|#GP|#PF|FATAL|kernel halted"; then
    FAIL=$((FAIL+1))
    REASON=$(echo "$RAW" | grep -E "EXCEPTION|panic:|#GP|#PF|FATAL|kernel halted" | head -1)
    echo "  smp=$SMP run=$i: FAIL $REASON"
  elif echo "$RAW" | grep -q "ALL PHASE-6 TESTS PASS"; then
    # Every marker is required, not any one of them. A smoke that stops
    # printing because it stopped running would otherwise leave the sweep
    # green, which is worse than having no smoke at all.
    if ! echo "$RAW" | grep -q "vfs: mounted /"; then
      FAIL=$((FAIL+1))
      echo "  smp=$SMP run=$i: FAIL no-vfs"
    elif ! echo "$RAW" | grep -q "netdev_smoke: PASS"; then
      FAIL=$((FAIL+1))
      echo "  smp=$SMP run=$i: FAIL no-netdev"
    elif ! echo "$RAW" | grep -q "virtio_chain_smoke: PASS"; then
      FAIL=$((FAIL+1))
      echo "  smp=$SMP run=$i: FAIL no-virtio-chain"
    else
      PASS=$((PASS+1))
      echo "  smp=$SMP run=$i: PASS"
    fi
  else
    FAIL=$((FAIL+1))
    echo "  smp=$SMP run=$i: FAIL no-phase6 (timeout?)"
  fi
done
echo "=== -smp $SMP: $PASS/$((PASS+FAIL)) PASS ==="
