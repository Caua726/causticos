# Overview

causticos is an x86_64 kernel and a small userspace, written in Caustic.
This is the bird's-eye view: what the layers are and roughly how they
stack up. It's deliberately shallow — for anything precise, read the
module it points at.

## From power-on to a running program

1. **Limine** loads the kernel high (`0xFFFFFFFF80000000`) in 64-bit long
   mode and hands over a framebuffer, a memory map, and the HHDM offset
   (`kernel/limine.cst`).
2. `kernel/main.cst` brings the machine up in order: serial console, GDT,
   IDT, physical memory, the heap, paging, ACPI, the clocks, SMP, the
   driver framework, then the scheduler.
3. Once the scheduler is live, the kernel spawns its smoke threads — and
   among them, a userspace thread: a program loaded into ring 3 that talks
   back through syscalls.

## The layers

**Memory.** A buddy allocator hands out physical pages (`pmm.cst`); a slab
allocator sits on top for `kmalloc`-style objects (`heap.cst`). Virtual
memory is 4-level paging with per-process address spaces (`vmm.cst`), and
each address space tracks its mapped regions and open files
(`vma.cst`).

**Scheduling and SMP.** The scheduler is EEVDF across a set of QoS bands,
plus a deadline class for real-time-ish work, all on red-black trees
(`sched.cst`, `rbtree.cst`). It's preemptive and runs on multiple cores —
AP bring-up, per-CPU state, and ticket locks live in `smp.cst` and
`lock.cst`.

**Time.** Three clocks: the PIT for early boot, the LAPIC timer for
scheduling ticks (calibrated against the HPET), and the HPET for a
nanosecond monotonic clock (`timer.cst`, `lapic.cst`, `hpet.cst`). The
hardware to wire all this up is discovered from ACPI tables
(`acpi.cst`, `ioapic.cst`).

**Drivers.** Devices are described declaratively in `.cdvrspec` files; the
framework matches them against what it finds on PCI and binds a driver,
with shared interrupt lines chained when devices collide (`driver.cst`,
`spec.cst`, `specparse.cst`, `pci.cst`).

**Storage.** An AHCI driver talks to SATA disks (`ahci.cst`), a block
layer sits above it (`storage.cst`), a full FAT32 implementation reads and
writes (`fat32.cst`), and a POSIX-shaped VFS gives the rest of the kernel
`open`/`read`/`write`/`readdir` (`vfs.cst`).

**Network.** An e1000 NIC driver with real TX/RX rings and interrupts
(`pcitest.cst`). There's no protocol stack yet — it can move frames, not
connections.

**Userspace.** Programs run in ring 3. The kernel enters ring 3 with
`iretq`, fields syscalls through `SYSCALL`/`SYSRET`, and loads programs
from two formats: ELF64 and CSE (causticos' own). See
[executables.md](executables.md).

## The stance

A few choices that explain why things look the way they do:

- **Own ABI, own format.** causticos has its own syscall numbers and its
  own executable format (CSE), so software is built *for* it, not ported.
  A CSE is polyglot — one file can hold a causticos, a Linux, and a Windows
  image (macOS planned) — so the same binary runs natively on each, but on
  causticos it uses causticos' own syscalls.
- **Small kernel, declarative drivers.** Device knowledge lives in spec
  files, not scattered through C-style probe code.
- **Honest about ring 0.** No KPTI, no ASLR, single-trust for now — the
  hardening layers come later, once there's untrusted code to defend
  against.
