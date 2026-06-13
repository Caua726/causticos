#!/bin/bash
# run-bootstrap.sh — the self-host bootstrap, on CausticOS, N rounds.
#
# Round k: the compiler image `caustic.cse` (the seed for round 1, the
# previous round's output thereafter) runs as a userspace process on
# CausticOS and compiles the WHOLE compiler source tree (mirrored on the
# FAT32 disk at /src,/std,/caustic-assembler,/caustic-linker) to /out.cse.
# The host lifts /out.cse off the image and feeds it back as next round's
# compiler. Byte-identical output across rounds == the OS self-hosts.
#
#   ./run-bootstrap.sh [rounds]     (default 4)
set -e
cd "$(dirname "$0")"
ROUNDS="${1:-4}"
CAUSTIC_DIR="${CAUSTIC_DIR:-$(cd ../Caustic && pwd)}"
SNAP=/tmp/srcsnap
WORK=/tmp/cwm-bootstrap
mkdir -p "$WORK"

[ -f build/causticos.iso ] || { echo "build/causticos.iso missing — build the kernel first"; exit 1; }

if [ ! -d "$SNAP/src" ] || [ "${RESNAP:-0}" = "1" ]; then
    echo "==> snapshotting the compiler source (stable vs live edits)"
    rm -rf "$SNAP"; mkdir -p "$SNAP"
    cp -r "$CAUSTIC_DIR/src" "$CAUSTIC_DIR/std" \
          "$CAUSTIC_DIR/caustic-assembler" "$CAUSTIC_DIR/caustic-linker" "$SNAP/"
fi

if [ ! -f "$WORK/r0.cse" ] || [ "${RESEED:-0}" = "1" ]; then
    echo "==> building the seed compiler (cross-compiled on the host, slow)"
    "$CAUSTIC_DIR/caustic" --target=caustic-x86_64 --mode=pure --stack-size=8388608 \
        "$SNAP/src/main.cst" -o "$WORK/r0.cse" >/dev/null 2>&1 \
        || { echo "seed build FAILED"; "$CAUSTIC_DIR/caustic" --target=caustic-x86_64 --mode=pure --stack-size=8388608 "$SNAP/src/main.cst" -o "$WORK/r0.cse"; exit 1; }
else
    echo "==> reusing existing seed $WORK/r0.cse"
fi
"$CAUSTIC_DIR/caustic" --target=caustic-x86_64 --stack-size=65536 \
    "$(pwd)/userspace/bootstrap.cst" -o "$WORK/bootstrap.cse" >/dev/null 2>&1 \
    || { echo "bootstrap driver build FAILED"; exit 1; }
echo "    seed r0.cse md5 = $(md5sum "$WORK/r0.cse" | cut -d' ' -f1)  ($(stat -c%s "$WORK/r0.cse") bytes)"

cp="$WORK/r0.cse"          # the compiler image for the current round
for k in $(seq 1 "$ROUNDS"); do
    echo "==> ROUND $k — building disk (seed=$cp)"
    DISK="$WORK/disk_r$k.img"
    qemu-img create -f raw "$DISK" 64M >/dev/null
    mkfs.fat -F 32 -n CAUSTICOS "$DISK" >/dev/null
    python3 scripts/fat32_mirror.py "$DISK" \
        "$SNAP/src" "$SNAP/std" "$SNAP/caustic-assembler" "$SNAP/caustic-linker" >/dev/null
    python3 scripts/fat32_add_file.py "$DISK" addfilebin caustic.cse "$cp" >/dev/null
    python3 scripts/fat32_add_file.py "$DISK" addfilebin init.cse "$WORK/bootstrap.cse" >/dev/null

    echo "    booting CausticOS (the on-device compile is slow under TCG)..."
    LOG="$WORK/serial_r$k.log"
    : > "$LOG"                          # create up-front: no read-before-exists race
    # TCG by default: CausticOS's timer/scheduler is reliable under TCG (the
    # smokes + the historic 4-round convergence ran there). KVM is opt-in
    # (BOOT_KVM=1) — it boots but its real-hardware timing can stall the
    # scheduler under sustained load. TCG is ~10x slower, hence the long bound.
    KVM=""; [ "${BOOT_KVM:-0}" = "1" ] && [ -w /dev/kvm ] && KVM="-enable-kvm"
    # -smp 2: the compile is single-threaded, but the bootstrap DRIVER needs a
    # cpu to reap the child + print heartbeats — on -smp 1 a flat-out compute
    # thread can starve it for minutes. The second cpu costs nothing here.
    qemu-system-x86_64 $KVM -cdrom build/causticos.iso -m 256M -machine q35 \
        -drive id=disk,file="$DISK",if=none,format=raw \
        -device ahci,id=ahci -device ide-hd,drive=disk,bus=ahci.0 \
        -boot d -serial file:"$LOG" -display none -no-reboot -smp 2 &
    QPID=$!
    # wait for ROUND DONE (or a failure); generous bound for slow TCG compiles
    for _ in $(seq 1 1800); do
        if tr -d '\000' < "$LOG" | grep -qE "ROUND DONE|NOT written|spawn FAIL|panic:|EXCEPTION"; then break; fi
        if ! kill -0 $QPID 2>/dev/null; then break; fi
        sleep 1
    done
    kill -9 $QPID 2>/dev/null; wait $QPID 2>/dev/null || true

    if ! tr -d '\000' < "$LOG" | grep -q "ROUND DONE"; then
        echo "    ROUND $k FAILED — serial tail:"; tr -d '\000' < "$LOG" | grep -iE "bootstrap|panic|exception|out.cse" | tail -8
        exit 1
    fi
    python3 scripts/fat32_get.py "$DISK" out.cse "$WORK/r$k.cse" >/dev/null
    M=$(md5sum "$WORK/r$k.cse" | cut -d' ' -f1)
    echo "    r$k.cse md5 = $M  ($(stat -c%s "$WORK/r$k.cse") bytes)  [$(tr -d '\000' < "$LOG" | grep -oE 'still compiling[^s]*' | tail -1)]"
    cp="$WORK/r$k.cse"
done

echo "==> CONVERGENCE CHECK"
prev=""
allok=1
for k in $(seq 1 "$ROUNDS"); do
    M=$(md5sum "$WORK/r$k.cse" | cut -d' ' -f1)
    echo "    r$k = $M"
    if [ -n "$prev" ] && [ "$prev" != "$M" ]; then allok=0; fi
    prev="$M"
done
SEED=$(md5sum "$WORK/r0.cse" | cut -d' ' -f1)
echo "    seed(r0) = $SEED"
if [ "$allok" = "1" ] && [ "$prev" = "$SEED" ]; then
    echo "==> SELF-HOST CONVERGED: all $ROUNDS rounds byte-identical to the seed."
    cp "$WORK/r$ROUNDS.cse" build/caustic.cse
    echo "    converged compiler saved to build/caustic.cse"
else
    echo "==> NOT converged (rounds differ) — inspect $WORK/r*.cse"
    exit 1
fi
