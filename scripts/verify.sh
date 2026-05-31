#!/bin/bash
set +e
cd /home/caua/Documentos/Projetos-Pessoais/causticos
SMP="${1:-4}"
RUNS="${2:-20}"
TOUT="${3:-8}"

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
  # Run qemu in background, watch its serial output. On success-marker
  # or exception, kill qemu and stop. Hard timeout via `timeout`.
  timeout "$TOUT" qemu-system-x86_64 \
    -cdrom build/causticos.iso -m 128M -machine q35 \
    -drive id=disk,file=build/disk.img,if=none,format=raw \
    -device ahci,id=ahci -device ide-hd,drive=disk,bus=ahci.0 \
    -netdev user,id=net0 -device e1000,netdev=net0,mac=52:54:00:12:34:56 \
    -boot d -serial stdio -display none -no-reboot -smp "$SMP" \
    > "$TMPLOG" 2>&1 &
  QPID=$!
  # Poll for success marker or exception, then kill.
  while kill -0 $QPID 2>/dev/null; do
    if grep -qE "vfs\.test: ALL PASS|EXCEPTION|panic:|kernel halted" "$TMPLOG" 2>/dev/null; then
      kill -9 $QPID 2>/dev/null
      break
    fi
    sleep 0.2
  done
  wait $QPID 2>/dev/null

  RAW=$(tr -d '\000' < "$TMPLOG")
  rm -f "$TMPLOG"

  if echo "$RAW" | grep -qE "EXCEPTION|panic:|#GP|#PF|FATAL|kernel halted"; then
    FAIL=$((FAIL+1))
    REASON=$(echo "$RAW" | grep -E "EXCEPTION|panic:|#GP|#PF|FATAL|kernel halted" | head -1)
    echo "  smp=$SMP run=$i: FAIL $REASON"
  elif echo "$RAW" | grep -q "ALL PHASE-6 TESTS PASS"; then
    if echo "$RAW" | grep -q "vfs: mounted /"; then
      PASS=$((PASS+1))
      echo "  smp=$SMP run=$i: PASS"
    else
      FAIL=$((FAIL+1))
      echo "  smp=$SMP run=$i: FAIL no-vfs"
    fi
  else
    FAIL=$((FAIL+1))
    echo "  smp=$SMP run=$i: FAIL no-phase6 (timeout?)"
  fi
done
echo "=== -smp $SMP: $PASS/$((PASS+FAIL)) PASS ==="
