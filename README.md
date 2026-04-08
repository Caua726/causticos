# Causticos

An operating system written entirely in the [Caustic](https://github.com/Caua726/Caustic) programming language. Boots via Limine into 64-bit long mode on x86_64.

## Building

Requires the Caustic toolchain (`caustic`, `caustic-as`, `caustic-ld`, `caustic-mk`), Limine bootloader, `xorriso`, and QEMU.

```sh
caustic-mk build kernel
caustic-mk run iso
GDK_BACKEND=x11 qemu-system-x86_64 -cdrom build/causticos.iso -m 128M -serial file:build/serial.log
```

## Architecture

```
kernel/
  main.cst        Entry point (_kernel_start)
  limine.cst       Limine boot protocol (framebuffer, HHDM, memory map)
  gdt.cst          Global Descriptor Table
  idt.cst          IDT, PIC, exception/IRQ handlers
  port.cst         x86 port I/O (in/out via raw opcodes)
  serial.cst       COM1 serial debug output
  pmm.cst          Physical Memory Manager (buddy allocator)
  heap.cst         Slab allocator + kmalloc
  vmm.cst          Virtual Memory Manager (paging, kvalloc, DMA)
  timer.cst        PIT timer (early boot) + monotonic clock
  lapic.cst        Local APIC timer (one-shot, PIT-calibrated)
  sched.cst        Scheduler (EEVDF, deadline EDF+CBS, anti-abuse)
  rbtree.cst       Red-black tree (used by scheduler)
  util.cst         Shared utilities (print_num, print_hex)
  fb.cst           Framebuffer rendering (32bpp)
font/
  font8x8.cst      8x8 bitmap font
```

## Subsystems

### Memory Management

- **PMM**: Buddy allocator (orders 0-10, 4KB-4MB), section-based sparse model (128 MiB sections, 12 bytes/page metadata), DMA32/NORMAL zones with reserves, IRQ-safe
- **Heap**: Slab allocator with 14 kmalloc size classes (16-4096), kcache API for typed objects, poison + redzone debug, shrinker, slab ID recycling
- **VMM**: 4-level x86_64 paging, deep-cloned kernel page tables, address space create/destroy/switch, kvalloc (bitmap range manager with guard pages), DMA allocator

### Scheduler

- **EEVDF** within 6 QoS bands (input, render, active, normal, batch, lazy) with strict inter-band priority
- **Deadline class** (EDF + CBS): admission test, budget enforcement, period replenishment
- **Anti-abuse**: capability-gated bands (CAP_SCHED_INPUT, CAP_SCHED_RENDER, CAP_SCHED_REALTIME), per-thread budget measurement, demotion/promotion
- **LAPIC timer**: one-shot mode, PIT-calibrated, program_next_tick for precise event scheduling
- **Red-black trees** for both deadline list and per-band runqueues (O(log n))
- **Per-CPU runqueue struct** (single CPU in V1, SMP-ready layout)
- **Dynamic threads** via kcache + hash table TID lookup (unbounded thread count)
- **Lazy FPU**: CR0 TS bit + #NM handler, fxsave/fxrstor
- **Preemption**: preempt_count, cond_resched, IRQ-return preemption check

### Hardware

- Limine boot protocol (framebuffer, HHDM, memory map)
- GDT with kernel code/data segments (raw opcode segment register loads)
- IDT with 19 exception + 16 IRQ + LAPIC timer handlers
- PIC 8259 remapping (vectors 32-47)
- Local APIC (MMIO-mapped, timer calibration)
- COM1 serial output (115200 8N1)
- PS/2 keyboard (scancode via IRQ1)
- Framebuffer text rendering (8x8 bitmap font)

## Caustic Language Workarounds

The Caustic assembler (`caustic-as`) silently drops several x86_64 instructions. Workarounds used throughout:

| Instruction | Workaround |
|---|---|
| `mov ss/ds/es/fs/gs, ax` | `.byte 0x8E, 0xD0/D8/C0/E0/E8` |
| `push imm8` | `.byte 0x6A, N` |
| `lgdt/lidt/iretq/retfq` | `.byte` raw opcodes |
| `pushfq/popfq` | `.byte 0x9C/0x9D` |
| `cli/sti/hlt` | `.byte 0xFA/0xFB/0xF4` |
| `in/out` | `.byte 0xEC/0xEE` |
| `mov cr0/cr3` | `.byte 0x0F, 0x20/0x22, ...` |
| `invlpg/clts/fxsave/fxrstor` | `.byte` sequences |
| `imul rax, rax, imm` | Use Caustic code + global (immediate dropped) |
| Function pointers (`&fn`) | `lea rax, [rip+symbol]` via asm |
| `inb` return value | Global shuttle (compiler overwrites rax) |

## License

MIT
