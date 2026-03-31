# causticos -- Bootable Kernel Design

## Overview

causticos is an operating system kernel written entirely in the Caustic programming language. The first milestone is a freestanding kernel that boots via the Limine bootloader and displays "causticos" on screen using framebuffer pixel rendering.

The entire build pipeline uses Caustic's own toolchain: `caustic` (compiler), `caustic-as` (assembler), `caustic-ld` (linker). The only non-Caustic tools are `xorriso` (ISO creation), Limine (bootloader), and QEMU (emulation).

## Architecture

### Boot Flow

```
BIOS/UEFI -> Limine -> 64-bit long mode -> _kernel_start (Caustic)
                                                |
                                          Check framebuffer response
                                                |
                                          fb.init() -> fb.print("causticos")
                                                |
                                            cli + hlt loop
```

Limine handles all the low-level boot setup: real mode to protected mode to long mode transition, paging (higher-half direct map), GDT, stack allocation (64 KiB minimum). The kernel receives control in 64-bit mode with paging enabled and all GPRs (except RSP) zeroed.

### Limine Protocol

The kernel communicates with Limine via request/response structs placed in the binary. Limine scans the loaded ELF for 8-byte aligned magic numbers and fills in response pointers before jumping to the entry point.

Common magic prefix for all requests: `0xc7b1dd30df4c8b88, 0x0a82e883a194f07b`

**Base revision tag:**
- `{0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 3}` -- protocol revision 3
- Limine sets the third element to 0 if it supports revision 3

**Framebuffer request ID:** `{common_magic, 0x9d5827dcd881dd75, 0xa3148604f6fab11b}`

The response provides a pointer to an array of framebuffer descriptors, each containing: address (HHDM-mapped), width, height, pitch (bytes per scanline), bpp (bits per pixel), and RGB mask info.

### Kernel Entry State (x86_64, per Limine spec)

- RIP: entry point from ELF header
- RSP: 64 KiB+ stack in bootloader-reclaimable memory
- CR0: PG, PE, WP enabled
- CR4: PAE enabled
- EFER: LME and NX enabled
- GDT: bootloader-provided with 64-bit code/data descriptors
- All GPRs except RSP: 0
- IF, VM, DF: cleared

## Project Structure

```
causticos/
├── Causticfile              # Build config
├── limine.conf              # Limine bootloader config
├── kernel/
│   ├── main.cst             # Kernel entry point (_kernel_start)
│   ├── limine.cst           # Limine protocol request structs
│   ├── fb.cst               # Framebuffer pixel writing + text rendering
│   └── port.cst             # x86_64 port I/O (outb/inb via asm)
├── font/
│   └── font8x8.cst          # 8x8 bitmap font data (printable ASCII)
├── scripts/
│   └── run.sh               # Build + ISO creation + QEMU launch
└── docs/
```

## Toolchain Modifications

### caustic-ld: `--freestanding` flag

The linker currently emits a 28-byte `_start` stub that:
1. Clears rbp, pops argc, loads argv
2. Aligns stack to 16 bytes
3. Calls `main` via rel32
4. Exits via `syscall(60)`

This stub is Linux-specific and must be skipped for kernel builds.

**Change:** Add `--freestanding` CLI flag. When set:
- Skip emitting the `_start` stub
- Resolve entry point directly from the `--entry=<symbol>` flag
- Set ELF `e_entry` to the resolved symbol's virtual address

No other linker changes needed. `--base=0xFFFFFFFF80000000` already works for higher-half loading.

**Build command:**
```bash
caustic-ld --freestanding --entry=_kernel_start --base=0xFFFFFFFF80000000 kernel.o -o kernel.elf
```

## Kernel Components

### kernel/limine.cst -- Protocol Structs

Defines Caustic structs matching Limine's protocol:

- `LimineFbRequest` -- 4x i64 magic ID + revision + response pointer
- `LimineFbResponse` -- revision + framebuffer count + pointer to framebuffer array
- `LimineFramebuffer` -- address, width, height, pitch, bpp, RGB mask info
- Global `fb_request` initialized with framebuffer request magic numbers
- Global base revision tag (3 x i64)

### kernel/main.cst -- Entry Point

`_kernel_start()`:
1. Read `fb_request.response` -- if null, halt (Limine didn't provide a framebuffer)
2. Dereference response to get first framebuffer descriptor
3. Call `fb.init()` with the framebuffer pointer
4. Call `fb.print("causticos", 10, 10, 0xFFFFFF)` to render white text at (10, 10)
5. Enter infinite halt loop: `cli` then `hlt` in a loop

### kernel/fb.cst -- Framebuffer Rendering

Module-level state: framebuffer pointer, width, height, pitch stored after `init()`.

Functions:
- `init(fb as *LimineFramebuffer)` -- store framebuffer metadata
- `put_pixel(x as i64, y as i64, color as i32)` -- write 32-bit ARGB at `address + y * pitch + x * 4` (assumes 32bpp, which Limine provides by default)
- `draw_char(ch as i32, cx as i64, cy as i64, color as i32)` -- render 8x8 bitmap from font table, calling `put_pixel` for each set bit
- `print(str as *u8, x as i64, y as i64, color as i32)` -- iterate string bytes, call `draw_char` with 8px horizontal spacing

### font/font8x8.cst -- Bitmap Font

An array of 128 entries (one per ASCII code), each 8 bytes representing 8 rows of an 8x8 character bitmap. Each bit = one pixel. Standard 8x8 bitmap font covering printable ASCII.

### kernel/port.cst -- Port I/O

Thin wrappers around x86_64 `in`/`out` instructions using `asm()`:
- `outb(port as u16, val as u8)` -- write byte to I/O port
- `inb(port as u16) as u8` -- read byte from I/O port

Not used in the first boot milestone but included for immediate use when adding serial output or PIC/interrupt setup.

## Build Pipeline

```bash
# 1. Compile .cst -> .s
caustic kernel/main.cst

# 2. Assemble .s -> .o
caustic-as kernel/main.cst.s

# 3. Link .o -> freestanding ELF
caustic-ld --freestanding --entry=_kernel_start \
    --base=0xFFFFFFFF80000000 kernel/main.cst.s.o -o build/kernel.elf

# 4. Create bootable ISO
#    - Copy kernel.elf, limine.conf, and Limine binaries into ISO structure
#    - Use xorriso to create ISO with BIOS + UEFI boot support
#    - Run limine bios-install on the ISO

# 5. Boot in QEMU
qemu-system-x86_64 -cdrom build/causticos.iso -m 128M
```

### limine.conf

```
timeout: 0

/causticos
    protocol: limine
    kernel_path: boot():/boot/kernel.elf
```

## Dependencies

- **Caustic toolchain** -- compiler, assembler, linker (at `/run/media/caua/Caua/caua/Documentos/Projetos-Pessoais/Caustic/`)
- **Limine** -- bootloader (system package or built from source)
- **xorriso** -- ISO image creation
- **QEMU** -- x86_64 emulation for testing

## Scope Boundaries

**In scope:**
- `caustic-ld` `--freestanding` flag
- Kernel entry, framebuffer text rendering, halt loop
- Limine protocol integration (framebuffer request only)
- Build script and ISO creation
- 8x8 bitmap font for ASCII text

**Not in scope (future milestones):**
- Compiler annotations (`@section`, `@interrupt`, `@naked`)
- Serial output (COM1)
- GDT/IDT setup
- Interrupt handling
- Physical/virtual memory management
- `caustic-mk` linker flag passthrough
- Keyboard input
