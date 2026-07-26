# causticos

An x86_64 operating system written in [Caustic](https://github.com/Caua726/Caustic), a from-scratch systems language with its own compiler, assembler, and linker. It boots under Limine and runs its own ring-3 programs.

causticos has its own syscall ABI and its own executable format, CSE — the *Caustic Standard Executable*. You build a program for the `caustic` target and get a `.cse` the kernel loads and runs in ring 3:

```
userspace.cse_smoke: PASS
Hello from Caustic!
sys.proc_exit: code=0
```

A `.cse` is polyglot. The toolchain welds a causticos, a Linux, and a Windows image into one file (macOS planned), so the same binary runs natively on each — every image calls its own OS's syscalls, APE/Cosmopolitan-style. On causticos, the kernel pulls out the causticos image and runs it.

For the friendly version of how that works, see [docs/executables.md](docs/executables.md); the exact byte layout and syscall contract live in [docs/CSE_FORMAT.md](docs/CSE_FORMAT.md).

Around 21k lines of Caustic across ~40 modules. x86_64 only.

## What works

- **Boot** — Limine, long mode, higher-half kernel at `0xFFFFFFFF80000000`. The ISO carries its own root volume, so it boots a complete desktop with no disk attached.
- **SMP** — AP bring-up, per-CPU state, ticket locks. Validated at `-smp 1/2/4`.
- **Memory** — buddy physical allocator, binned heap, 4-level paging, a single kernel-VA mapper, strict reserve+commit (no demand paging), per-address-space VMA and file-descriptor tables.
- **Scheduler** — EEVDF across QoS bands plus a deadline class (EDF + CBS), preemptive, backed by red-black trees.
- **Time** — PIT, LAPIC timer (calibrated against the HPET), HPET nanosecond clock, RTC wall clock. ACPI discovery (RSDP/XSDT/MADT/MCFG/HPET) and IOAPIC routing.
- **Drivers** — a declarative framework where devices are described in `.cdvrspec` files, over PCI, with shared-IRQ chaining. PS/2 keyboard and mouse, virtio-tablet, e1000, virtio-net and virtio-sound.
- **Storage** — AHCI (SATA) and a RAM-backed live root, behind one block-device registry; a FAT32 implementation (read, write, create, unlink, rename, mkdir) and a POSIX-shaped VFS on top.
- **Network** — e1000 and virtio-net drivers under a `DEV_NET` class that hands userspace raw ethernet frames, and `netd`: ARP, IPv4, ICMP, UDP, TCP, DHCP, DNS, HTTP/1.1 and TLS 1.3 with certificate verification, all in ring 3. `wget https://…` works.
- **Sound** — a `DEV_AUDIO_OUT` / `DEV_AUDIO_IN` class: a DMA ring of PCM and a control page, mapped into the holder, or fed with `write()`. virtio-sound drives it; Intel HDA (the one real machines have) is still to come.
- **Userspace** — ring 3 via `iretq`, `SYSCALL`/`SYSRET`, process spawn with fd handoff, channels, shared segments, eventfds, surfaces. 99 programs: a shell, ~45 coreutils, monitors (`ps`, `top`, `btop`, `htop`, `df`, `free`), editors (`vic`, `pager`, `hexedit`), and the network and audio tools (`ping`, `wget`, `nslookup`, `nc`, `httpd`, `aplay`, `arecord`).
- **Desktop** — a compositor that owns the framebuffer and input, a window manager with tags, layouts and a config file, a terminal emulator, and a launcher.
- **Self-hosting** — the Caustic compiler compiles itself *on* causticos, four rounds, byte-identical.

## What's not there yet

- Audio has no mixer in the kernel: one program holds the stream at a time (the grab stack makes that a takeover rather than a refusal). `soundd` is what makes two programs audible at once.
- Intel HDA — the audio device real machines actually have — is not written yet; virtio-sound covers the VM.
- No installer: the live system is volatile by design, and `--persist` is how you get a persistent root.
- One FAT32 volume at a time — the driver keeps its scratch buffers and FAT cache in module globals, so a second concurrent mount is not yet safe.
- No ASLR, no KPTI (single-trust for now). x86_64 only.

## Requirements

The Caustic toolchain (`caustic`, `caustic-as`, `caustic-ld`, `caustic-mk`) on your `PATH`, plus:

- [Limine](https://github.com/limine-bootloader/limine), installed under `/usr/share/limine`
- `xorriso` and `qemu-system-x86_64`
- `python3` 3.8+

`caustic-mk run doctor` checks all of it and prints a fix for anything missing.

## Build and run

```sh
caustic-mk run doctor     # check the prerequisites
caustic-mk run build      # kernel + userspace + a live ISO
caustic-mk run run        # boot it
```

That is the whole loop. `caustic-mk run run` boots **with no disk attached** — the root volume travels inside the ISO as a sparse container the kernel expands into RAM. Write to it freely; it is volatile, and the boot says so.

```sh
caustic-mk run run -- --headless          # serial only, no window
caustic-mk run run -- --smp 4 -m 1G       # more cpus, more memory
caustic-mk run build -- --profile shell   # a shell instead of the desktop
caustic-mk run run -- --persist           # attach a disk and boot from it instead
caustic-mk run profiles                   # what a profile actually ships
caustic-mk run verify                     # the regression sweep, both gates
```

Writing the ISO to a USB stick gives you the same system on real hardware, BIOS or UEFI, with no other storage:

```sh
caustic-mk run usb -- /dev/sdX
```

[docs/build-and-run.md](docs/build-and-run.md) covers every command and flag, the profile format, and the on-disk layout of the ISO.

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
  ramvol, cmdline                                        live root, kernel command line
scripts/                                                 build helpers (FAT32, CSVI, ISO, QEMU)
profiles/                                                what each root image ships
docs/                                                    overview, executables, CSE_FORMAT spec
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
