# causticos

A hobby x86_64 operating system written in [Caustic](https://github.com/Caua726/Caustic), a from-scratch systems language with its own compiler, assembler, and linker. It boots under Limine and runs its own ring-3 programs.

causticos is not a Linux clone. It has its own syscall ABI — not binary-compatible with anything — and its own executable format, CSE, the *Caustic Standard Executable* (see [CSE_FORMAT.md](CSE_FORMAT.md)). The Caustic toolchain has a `causticos-x86_64` target that emits both, so a program written in Caustic, compiled to CSE, calling causticos syscalls, loads and runs:

```
userspace.cse_smoke: PASS
Hello from Caustic!
sys.proc_exit: code=0
```

About 21k lines of Caustic across ~40 modules. One developer, x86_64 only.

## What works

- **Boot** — Limine, long mode, higher-half kernel at `0xFFFFFFFF80000000`.
- **SMP** — AP bring-up, per-CPU state, ticket locks. Validated at `-smp 1/2/4`.
- **Memory** — buddy physical allocator, slab/`kmalloc` heap, 4-level paging, per-address-space VMA and file-descriptor tables.
- **Scheduler** — EEVDF across QoS bands plus a deadline class (EDF + CBS), preemptive, backed by red-black trees.
- **Time** — PIT, LAPIC timer (calibrated against the HPET), HPET nanosecond clock. ACPI table discovery (RSDP/XSDT/MADT/MCFG/HPET) and IOAPIC routing.
- **Drivers** — a declarative framework where devices are described in `.cdvrspec` files, over PCI, with shared-IRQ chaining.
- **Storage** — AHCI (SATA), a FAT32 implementation (read, write, create, unlink, rename, mkdir), and a POSIX-shaped VFS on top.
- **Network** — an e1000 NIC driver: TX/RX rings, interrupts, ARP.
- **Userspace** — ring 3 via `iretq`, `SYSCALL`/`SYSRET`, a small v0 syscall ABI, and loaders for both ELF64 and CSE. It loads a real toolchain-built `.cse` and runs it to completion.

## What's not there yet

- The syscall ABI is 7 calls: kernel info, monotonic time, sleep, exit, getpid, yield, write-to-console. There's no file I/O, `mmap`, or process spawning from userspace — fd-based read/write, user `mmap`, and `spawn` arrive with the capability layer.
- No IPC, no signals.
- The NIC driver exists, but there is no TCP/IP stack.
- No ASLR, no KPTI (single-trust for now). x86_64 only.

## Requirements

The Caustic toolchain (`caustic`, `caustic-as`, `caustic-ld`) on your `PATH`, plus:

- [Limine](https://github.com/limine-bootloader/limine), installed under `/usr/share/limine`
- `xorriso` and `qemu-system-x86_64`
- `mkfs.fat`, `qemu-img`, `python3` — only to seed the test FAT32 disk

## Build and run

```sh
bash scripts/run.sh            # compile, assemble, link, build the ISO, seed a disk, boot QEMU
bash scripts/run.sh -smp 4     # trailing arguments pass straight through to QEMU
```

The serial console is wired to stdout. To run many boots without watching each one — `verify.sh` reuses the ISO, reseeds the disk per run, and kills QEMU on the success marker:

```sh
bash scripts/verify.sh 4 20    # -smp 4, 20 runs
```

> The kernel must be linked with `--strip`, or Limine page-faults it in early boot (it reads embedded section headers when they're present). `scripts/run.sh` does this; the `caustic-mk` / `Causticfile` path does not, so use the script.

## Layout

```
kernel/
  main, limine, gdt, idt, port, serial, util, ksym, fb   boot, traps, I/O, console
  pmm, heap, vmm, vma                                     physical / heap / virtual memory
  sched, rbtree, smp, lock, lapic, timer, hpet           scheduling, SMP, clocks
  acpi, ioapic                                           ACPI tables, interrupt routing
  driver, spec, specparse, pci, io, platform_bus         declarative driver framework
  ahci, storage, fat32, vfs                              SATA, block layer, FAT32, VFS
  pcitest                                                e1000 NIC driver
  syscall, syscall_entry.s, syshandlers, abi             syscall entry, dispatch, ABI
  userspace, elf, cse, process, kbd                      ring-3 entry, ELF/CSE loaders
font/font8x8.cst                                         8x8 bitmap font
scripts/                                                 run.sh, verify.sh, FAT32 fixtures
CSE_FORMAT.md                                            the CSE executable format spec
```

The hand-written assembly (`kernel/smp_asm.s`, `kernel/syscall_entry.s`) holds the raw entry points. Anything that runs before a stack frame exists — the syscall trampoline, the SMP primitives — can't be a Caustic function, because the compiler's prologue would run on the wrong stack.

## Caustic quirks

The assembler ignores instructions it doesn't recognize instead of erroring, so the kernel drops to raw bytes more than usual:

| Instruction | Encoded as |
|---|---|
| `cli` / `sti` / `hlt` | `.byte 0xFA` / `0xFB` / `0xF4` |
| `in` / `out` | `.byte 0xEC` / `0xEE` |
| `iretq` / `sysretq` | `.byte 0x48,0xCF` / `0x48,0x0F,0x07` |
| `mov ds/es/fs/gs, ax` | `.byte 0x8E, ...` |
| `mov cr0/cr3, r` | `.byte 0x0F,0x22, ...` |
| `lgdt` / `lidt` / `invlpg` / `fxsave` | `.byte` sequences |
| `wrmsr` / `rdmsr` / `lock xadd` | `.byte` (see `kernel/smp_asm.s`) |
| `gs:[off]` segment override | `.byte 0x65, ...` |

Two structural ones worth knowing: a function used as a raw CPU entry point (LSTAR, IDT vectors) has to be hand-assembly, not a Caustic `fn`, or its prologue corrupts the incoming stack; and the compiler crashes on cyclic module imports, so module composition is pushed up to `main`.

## License

MIT
