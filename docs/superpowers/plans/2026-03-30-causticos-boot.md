# causticos Boot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Boot a Caustic-compiled freestanding kernel via Limine that displays "causticos" on a framebuffer.

**Architecture:** Modify `caustic-ld` to support `--freestanding` (skip Linux `_start` stub), then build a minimal kernel with Limine protocol structs, framebuffer rendering, and an 8x8 bitmap font. The kernel is compiled with Caustic's own toolchain and booted via Limine in QEMU.

**Tech Stack:** Caustic (compiler, assembler, linker), Limine 11.1.0 bootloader, xorriso, QEMU

---

## File Map

**Caustic toolchain (modify):**
- `caustic-linker/linker.cst` -- Add `freestanding` field to `LinkerState`, conditionally skip `_start` stub emission and patching
- `caustic-linker/main.cst` -- Parse `--freestanding` CLI flag
- `caustic-linker/elf_writer.cst` -- Skip `_start` symbol in symtab when freestanding

**causticos project (create):**
- `kernel/port.cst` -- `outb`/`inb` via inline asm
- `kernel/limine.cst` -- Limine protocol structs and request globals
- `font/font8x8.cst` -- 8x8 bitmap font array (128 ASCII entries)
- `kernel/fb.cst` -- Framebuffer init, put_pixel, draw_char, print
- `kernel/main.cst` -- Kernel entry `_kernel_start`, framebuffer check, print, halt
- `limine.conf` -- Limine bootloader config
- `scripts/run.sh` -- Build + ISO + QEMU pipeline

---

### Task 1: Add `--freestanding` flag to `caustic-ld` CLI

**Files:**
- Modify: `/run/media/caua/Caua/caua/Documentos/Projetos-Pessoais/Caustic/caustic-linker/main.cst`

- [ ] **Step 1: Add `freestanding` variable and CLI parsing**

In `main.cst`, add a `freestanding` variable alongside the other CLI flags (after line 272), and add the CLI parsing case in the arg-parsing loop (after the `--keep-empty` check):

```cst
// Add after line 272 (keep_empty declaration):
let is i32 as freestanding with mut = 0;

// Add in the CLI parsing loop, after the --keep-empty check (after line 306):
else if (streq_lit(arg, "--freestanding") == 1) {
    freestanding = 1;
}
```

- [ ] **Step 2: Pass `freestanding` to LinkerState**

After `ls.keep_empty = keep_empty;` (line 366), add:

```cst
ls.freestanding = freestanding;
```

- [ ] **Step 3: Update `print_usage` to document the new flag**

Add after the `--keep-empty` line in `print_usage()`:

```cst
print_out("  --freestanding     Skip _start stub (for kernels/bare-metal)\n");
```

- [ ] **Step 4: Build the linker and test flag parsing**

```bash
cd /run/media/caua/Caua/caua/Documentos/Projetos-Pessoais/Caustic
./caustic-mk build caustic-ld
./caustic-ld --help
```

Expected: help output includes `--freestanding` line.

```bash
./caustic-ld --freestanding --help
```

Expected: no error about unknown flag.

- [ ] **Step 5: Commit**

```bash
cd /run/media/caua/Caua/caua/Documentos/Projetos-Pessoais/Caustic
git add caustic-linker/main.cst
git commit -m "caustic-ld: add --freestanding CLI flag"
```

---

### Task 2: Add `freestanding` field to `LinkerState` and skip `_start` stub

**Files:**
- Modify: `/run/media/caua/Caua/caua/Documentos/Projetos-Pessoais/Caustic/caustic-linker/linker.cst`

- [ ] **Step 1: Add `freestanding` field to `LinkerState` struct**

Add after `keep_empty as i32;` (line 104):

```cst
freestanding as i32;
```

- [ ] **Step 2: Initialize `freestanding` in `linker_init`**

Add after `ls.keep_empty = 0;` (line 173):

```cst
ls.freestanding = 0;
```

- [ ] **Step 3: Conditionally skip `_start` stub in `merge_sections`**

Replace line 239:

```cst
emit_start_stub(text_buf);
```

With:

```cst
if (ls.freestanding == 0) {
    emit_start_stub(text_buf);
}
```

- [ ] **Step 4: Conditionally skip stub patching in `build_symtab`**

Replace lines 384-396 (the stub patching and entry_vaddr assignment at the end of `build_symtab`):

```cst
let is i64 as main_vaddr = entry_sym.vaddr;

// Patch _start stub
let is *reader.ByteBuffer as text_buf = get_text(ls);
let is i64 as call_site = ls.text_vaddr + cast(i64, START_STUB_REL32_OFF) + 4;
let is i64 as rel32 = main_vaddr - call_site;
let is *u8 as tdata = text_buf.data;
tdata[START_STUB_REL32_OFF]     = cast(u8, rel32 & 255);
tdata[START_STUB_REL32_OFF + 1] = cast(u8, (rel32 >> 8) & 255);
tdata[START_STUB_REL32_OFF + 2] = cast(u8, (rel32 >> 16) & 255);
tdata[START_STUB_REL32_OFF + 3] = cast(u8, (rel32 >> 24) & 255);

ls.entry_vaddr = ls.text_vaddr;
```

With:

```cst
let is i64 as main_vaddr = entry_sym.vaddr;

if (ls.freestanding == 0) {
    // Patch _start stub
    let is *reader.ByteBuffer as text_buf = get_text(ls);
    let is i64 as call_site = ls.text_vaddr + cast(i64, START_STUB_REL32_OFF) + 4;
    let is i64 as rel32 = main_vaddr - call_site;
    let is *u8 as tdata = text_buf.data;
    tdata[START_STUB_REL32_OFF]     = cast(u8, rel32 & 255);
    tdata[START_STUB_REL32_OFF + 1] = cast(u8, (rel32 >> 8) & 255);
    tdata[START_STUB_REL32_OFF + 2] = cast(u8, (rel32 >> 16) & 255);
    tdata[START_STUB_REL32_OFF + 3] = cast(u8, (rel32 >> 24) & 255);
    ls.entry_vaddr = ls.text_vaddr;
} else {
    ls.entry_vaddr = main_vaddr;
}
```

- [ ] **Step 5: Build and verify**

```bash
cd /run/media/caua/Caua/caua/Documentos/Projetos-Pessoais/Caustic
./caustic-mk build caustic-ld
```

Expected: builds without errors.

- [ ] **Step 6: Commit**

```bash
cd /run/media/caua/Caua/caua/Documentos/Projetos-Pessoais/Caustic
git add caustic-linker/linker.cst
git commit -m "caustic-ld: skip _start stub in freestanding mode"
```

---

### Task 3: Skip `_start` symbol in ELF symtab when freestanding

**Files:**
- Modify: `/run/media/caua/Caua/caua/Documentos/Projetos-Pessoais/Caustic/caustic-linker/elf_writer.cst`

- [ ] **Step 1: Conditionally skip `_start` symbol emission**

In `elf_writer.cst`, find the block at lines 163-171 that emits the `_start` symbol into the output symtab. Wrap it in a freestanding check:

```cst
// _start symbol
if (ls.freestanding == 0) {
    let is i32 as start_str_off = cast(i32, meta.out_strtab.len);
    reader.buf_append(&meta.out_strtab, "_start", 7);
    reader.buf_emit32_le(&meta.out_symtab, cast(i64, start_str_off));
    reader.buf_emit8(&meta.out_symtab, 18);
    reader.buf_emit8(&meta.out_symtab, 0);
    reader.buf_emit16_le(&meta.out_symtab, 1);
    reader.buf_emit64_le(&meta.out_symtab, ls.text_vaddr);
    reader.buf_emit64_le(&meta.out_symtab, cast(i64, linker.START_STUB_SIZE));
}
```

- [ ] **Step 2: Build and verify**

```bash
cd /run/media/caua/Caua/caua/Documentos/Projetos-Pessoais/Caustic
./caustic-mk build caustic-ld
```

Expected: builds without errors.

- [ ] **Step 3: Test freestanding linking with a simple Caustic program**

Create a minimal test:

```bash
cd /run/media/caua/Caua/caua/Documentos/Projetos-Pessoais/Caustic
cat > /tmp/test_freestanding.cst << 'CSEOF'
fn _kernel_start() as void {
    asm("cli\nhlt\n");
}
CSEOF
./caustic -c /tmp/test_freestanding.cst
./caustic-as /tmp/test_freestanding.cst.s
./caustic-ld --freestanding --entry=_kernel_start --base=0xFFFFFFFF80000000 /tmp/test_freestanding.cst.s.o -o /tmp/test_kernel.elf
readelf -h /tmp/test_kernel.elf
```

Expected: ELF header shows entry point at an address >= `0xFFFFFFFF80000000`, type EXEC, machine x86-64. No `_start` stub in the binary.

- [ ] **Step 4: Commit**

```bash
cd /run/media/caua/Caua/caua/Documentos/Projetos-Pessoais/Caustic
git add caustic-linker/elf_writer.cst
git commit -m "caustic-ld: omit _start symbol in freestanding ELF output"
```

---

### Task 4: Create `kernel/port.cst` -- Port I/O wrappers

**Files:**
- Create: `/home/caua/Documentos/Projetos-Pessoais/causticos/kernel/port.cst`

- [ ] **Step 1: Create the kernel directory and port.cst**

```bash
mkdir -p /home/caua/Documentos/Projetos-Pessoais/causticos/kernel
```

Write `kernel/port.cst`:

```cst
// port.cst — x86_64 port I/O via inline assembly

fn outb(port as i64, val as i64) as void {
    asm("mov dx, di\n");
    asm("mov ax, si\n");
    asm("out dx, al\n");
}

fn inb(port as i64) as i64 {
    asm("mov dx, di\n");
    asm("xor rax, rax\n");
    asm("in al, dx\n");
}
```

Note: `port` arrives in `rdi`, `val` in `rsi` per System V ABI. The return value is in `rax`. We use `di`/`si` (16-bit) since port I/O uses 16-bit port numbers and 8-bit values.

- [ ] **Step 2: Verify it compiles**

```bash
cd /home/caua/Documentos/Projetos-Pessoais/causticos
CAUSTIC=/run/media/caua/Caua/caua/Documentos/Projetos-Pessoais/Caustic
$CAUSTIC/caustic -c kernel/port.cst
```

Expected: generates `kernel/port.cst.s` without errors.

- [ ] **Step 3: Commit**

```bash
cd /home/caua/Documentos/Projetos-Pessoais/causticos
git init
git add kernel/port.cst
git commit -m "kernel: add port I/O wrappers (outb/inb)"
```

---

### Task 5: Create `kernel/limine.cst` -- Limine protocol structs

**Files:**
- Create: `/home/caua/Documentos/Projetos-Pessoais/causticos/kernel/limine.cst`

- [ ] **Step 1: Write Limine protocol structs and request globals**

Write `kernel/limine.cst`:

```cst
// limine.cst — Limine boot protocol structs and requests

// ============================================================
// Base revision
// ============================================================

// Limine checks these magic numbers to confirm protocol version.
// If supported, Limine sets base_rev_2 to 0.
let is i64 as base_rev_0 with mut = 0xf9562b2d5c95a6c8;
let is i64 as base_rev_1 with mut = 0x6a7b384944536bdc;
let is i64 as base_rev_2 with mut = 3;

// ============================================================
// Framebuffer
// ============================================================

// Only the first 4 fields — all i64-sized so no packed-vs-C alignment issues.
// We don't need bpp/mask fields for 32bpp framebuffer writing.
struct LimineFramebuffer {
    address as *u8;
    width as i64;
    height as i64;
    pitch as i64;
}

struct LimineFbResponse {
    revision as i64;
    fb_count as i64;
    framebuffers as *i64;
}

struct LimineFbRequest {
    id0 as i64;
    id1 as i64;
    id2 as i64;
    id3 as i64;
    revision as i64;
    response as *LimineFbResponse;
}

// Common magic: 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b
// Framebuffer ID: 0x9d5827dcd881dd75, 0xa3148604f6fab11b
let is LimineFbRequest as fb_request with mut = {
    0xc7b1dd30df4c8b88, 0x0a82e883a194f07b,
    0x9d5827dcd881dd75, 0xa3148604f6fab11b,
    0, cast(*LimineFbResponse, 0)
};

// ============================================================
// Helpers
// ============================================================

fn get_framebuffer() as *LimineFramebuffer {
    let is *LimineFbResponse as resp = fb_request.response;
    if resp == cast(*LimineFbResponse, 0) {
        return cast(*LimineFramebuffer, 0);
    }
    if resp.fb_count == 0 {
        return cast(*LimineFramebuffer, 0);
    }
    // framebuffers is a pointer to an array of pointers
    let is *i64 as arr = cast(*i64, resp.framebuffers);
    return cast(*LimineFramebuffer, arr[0]);
}
```

- [ ] **Step 2: Verify it compiles**

```bash
cd /home/caua/Documentos/Projetos-Pessoais/causticos
CAUSTIC=/run/media/caua/Caua/caua/Documentos/Projetos-Pessoais/Caustic
$CAUSTIC/caustic -c kernel/limine.cst
```

Expected: generates `kernel/limine.cst.s` without errors.

- [ ] **Step 3: Commit**

```bash
cd /home/caua/Documentos/Projetos-Pessoais/causticos
git add kernel/limine.cst
git commit -m "kernel: add Limine protocol structs and framebuffer request"
```

---

### Task 6: Create `font/font8x8.cst` -- Bitmap font data

**Files:**
- Create: `/home/caua/Documentos/Projetos-Pessoais/causticos/font/font8x8.cst`

- [ ] **Step 1: Create the font directory and font8x8.cst**

```bash
mkdir -p /home/caua/Documentos/Projetos-Pessoais/causticos/font
```

Write `font/font8x8.cst`. This is an array of 128 * 8 = 1024 bytes. Each character is 8 consecutive bytes (rows top to bottom). Each bit in a byte represents a pixel (MSB = leftmost).

```cst
// font8x8.cst — 8x8 bitmap font for printable ASCII
// 128 characters * 8 bytes each = 1024 bytes
// Each byte is one row (MSB = leftmost pixel)

let is [1024]u8 as font8x8_data with imut = {
    // 0x00-0x0F: control chars (blank)
    0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,
    // 0x20 ' '
    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    // 0x21 '!'
    0x18,0x18,0x18,0x18,0x18,0x00,0x18,0x00,
    // 0x22 '"'
    0x6C,0x6C,0x24,0x00,0x00,0x00,0x00,0x00,
    // 0x23 '#'
    0x6C,0x6C,0xFE,0x6C,0xFE,0x6C,0x6C,0x00,
    // 0x24 '$'
    0x18,0x7E,0xC0,0x7C,0x06,0xFC,0x18,0x00,
    // 0x25 '%'
    0x00,0xC6,0xCC,0x18,0x30,0x66,0xC6,0x00,
    // 0x26 '&'
    0x38,0x6C,0x38,0x76,0xDC,0xCC,0x76,0x00,
    // 0x27 '''
    0x18,0x18,0x30,0x00,0x00,0x00,0x00,0x00,
    // 0x28 '('
    0x0C,0x18,0x30,0x30,0x30,0x18,0x0C,0x00,
    // 0x29 ')'
    0x30,0x18,0x0C,0x0C,0x0C,0x18,0x30,0x00,
    // 0x2A '*'
    0x00,0x66,0x3C,0xFF,0x3C,0x66,0x00,0x00,
    // 0x2B '+'
    0x00,0x18,0x18,0x7E,0x18,0x18,0x00,0x00,
    // 0x2C ','
    0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x30,
    // 0x2D '-'
    0x00,0x00,0x00,0x7E,0x00,0x00,0x00,0x00,
    // 0x2E '.'
    0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x00,
    // 0x2F '/'
    0x06,0x0C,0x18,0x30,0x60,0xC0,0x80,0x00,
    // 0x30 '0'
    0x7C,0xC6,0xCE,0xDE,0xF6,0xE6,0x7C,0x00,
    // 0x31 '1'
    0x18,0x38,0x78,0x18,0x18,0x18,0x7E,0x00,
    // 0x32 '2'
    0x7C,0xC6,0x06,0x1C,0x30,0x60,0xFE,0x00,
    // 0x33 '3'
    0x7C,0xC6,0x06,0x3C,0x06,0xC6,0x7C,0x00,
    // 0x34 '4'
    0x1C,0x3C,0x6C,0xCC,0xFE,0x0C,0x1E,0x00,
    // 0x35 '5'
    0xFE,0xC0,0xFC,0x06,0x06,0xC6,0x7C,0x00,
    // 0x36 '6'
    0x38,0x60,0xC0,0xFC,0xC6,0xC6,0x7C,0x00,
    // 0x37 '7'
    0xFE,0xC6,0x0C,0x18,0x30,0x30,0x30,0x00,
    // 0x38 '8'
    0x7C,0xC6,0xC6,0x7C,0xC6,0xC6,0x7C,0x00,
    // 0x39 '9'
    0x7C,0xC6,0xC6,0x7E,0x06,0x0C,0x78,0x00,
    // 0x3A ':'
    0x00,0x18,0x18,0x00,0x00,0x18,0x18,0x00,
    // 0x3B ';'
    0x00,0x18,0x18,0x00,0x00,0x18,0x18,0x30,
    // 0x3C '<'
    0x0C,0x18,0x30,0x60,0x30,0x18,0x0C,0x00,
    // 0x3D '='
    0x00,0x00,0x7E,0x00,0x7E,0x00,0x00,0x00,
    // 0x3E '>'
    0x60,0x30,0x18,0x0C,0x18,0x30,0x60,0x00,
    // 0x3F '?'
    0x7C,0xC6,0x0C,0x18,0x18,0x00,0x18,0x00,
    // 0x40 '@'
    0x7C,0xC6,0xDE,0xDE,0xDE,0xC0,0x7C,0x00,
    // 0x41 'A'
    0x38,0x6C,0xC6,0xC6,0xFE,0xC6,0xC6,0x00,
    // 0x42 'B'
    0xFC,0xC6,0xC6,0xFC,0xC6,0xC6,0xFC,0x00,
    // 0x43 'C'
    0x7C,0xC6,0xC0,0xC0,0xC0,0xC6,0x7C,0x00,
    // 0x44 'D'
    0xF8,0xCC,0xC6,0xC6,0xC6,0xCC,0xF8,0x00,
    // 0x45 'E'
    0xFE,0xC0,0xC0,0xFC,0xC0,0xC0,0xFE,0x00,
    // 0x46 'F'
    0xFE,0xC0,0xC0,0xFC,0xC0,0xC0,0xC0,0x00,
    // 0x47 'G'
    0x7C,0xC6,0xC0,0xCE,0xC6,0xC6,0x7E,0x00,
    // 0x48 'H'
    0xC6,0xC6,0xC6,0xFE,0xC6,0xC6,0xC6,0x00,
    // 0x49 'I'
    0x3C,0x18,0x18,0x18,0x18,0x18,0x3C,0x00,
    // 0x4A 'J'
    0x1E,0x0C,0x0C,0x0C,0xCC,0xCC,0x78,0x00,
    // 0x4B 'K'
    0xC6,0xCC,0xD8,0xF0,0xD8,0xCC,0xC6,0x00,
    // 0x4C 'L'
    0xC0,0xC0,0xC0,0xC0,0xC0,0xC0,0xFE,0x00,
    // 0x4D 'M'
    0xC6,0xEE,0xFE,0xD6,0xC6,0xC6,0xC6,0x00,
    // 0x4E 'N'
    0xC6,0xE6,0xF6,0xDE,0xCE,0xC6,0xC6,0x00,
    // 0x4F 'O'
    0x7C,0xC6,0xC6,0xC6,0xC6,0xC6,0x7C,0x00,
    // 0x50 'P'
    0xFC,0xC6,0xC6,0xFC,0xC0,0xC0,0xC0,0x00,
    // 0x51 'Q'
    0x7C,0xC6,0xC6,0xC6,0xD6,0xDE,0x7C,0x06,
    // 0x52 'R'
    0xFC,0xC6,0xC6,0xFC,0xD8,0xCC,0xC6,0x00,
    // 0x53 'S'
    0x7C,0xC6,0xC0,0x7C,0x06,0xC6,0x7C,0x00,
    // 0x54 'T'
    0xFE,0x18,0x18,0x18,0x18,0x18,0x18,0x00,
    // 0x55 'U'
    0xC6,0xC6,0xC6,0xC6,0xC6,0xC6,0x7C,0x00,
    // 0x56 'V'
    0xC6,0xC6,0xC6,0xC6,0x6C,0x38,0x10,0x00,
    // 0x57 'W'
    0xC6,0xC6,0xC6,0xD6,0xFE,0xEE,0xC6,0x00,
    // 0x58 'X'
    0xC6,0xC6,0x6C,0x38,0x6C,0xC6,0xC6,0x00,
    // 0x59 'Y'
    0xC6,0xC6,0x6C,0x38,0x18,0x18,0x18,0x00,
    // 0x5A 'Z'
    0xFE,0x06,0x0C,0x18,0x30,0x60,0xFE,0x00,
    // 0x5B '['
    0x3C,0x30,0x30,0x30,0x30,0x30,0x3C,0x00,
    // 0x5C '\'
    0xC0,0x60,0x30,0x18,0x0C,0x06,0x02,0x00,
    // 0x5D ']'
    0x3C,0x0C,0x0C,0x0C,0x0C,0x0C,0x3C,0x00,
    // 0x5E '^'
    0x10,0x38,0x6C,0xC6,0x00,0x00,0x00,0x00,
    // 0x5F '_'
    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xFE,
    // 0x60 '`'
    0x30,0x18,0x0C,0x00,0x00,0x00,0x00,0x00,
    // 0x61 'a'
    0x00,0x00,0x7C,0x06,0x7E,0xC6,0x7E,0x00,
    // 0x62 'b'
    0xC0,0xC0,0xFC,0xC6,0xC6,0xC6,0xFC,0x00,
    // 0x63 'c'
    0x00,0x00,0x7C,0xC6,0xC0,0xC6,0x7C,0x00,
    // 0x64 'd'
    0x06,0x06,0x7E,0xC6,0xC6,0xC6,0x7E,0x00,
    // 0x65 'e'
    0x00,0x00,0x7C,0xC6,0xFE,0xC0,0x7C,0x00,
    // 0x66 'f'
    0x1C,0x36,0x30,0x7C,0x30,0x30,0x30,0x00,
    // 0x67 'g'
    0x00,0x00,0x7E,0xC6,0xC6,0x7E,0x06,0x7C,
    // 0x68 'h'
    0xC0,0xC0,0xFC,0xC6,0xC6,0xC6,0xC6,0x00,
    // 0x69 'i'
    0x18,0x00,0x38,0x18,0x18,0x18,0x3C,0x00,
    // 0x6A 'j'
    0x0C,0x00,0x1C,0x0C,0x0C,0x0C,0xCC,0x78,
    // 0x6B 'k'
    0xC0,0xC0,0xCC,0xD8,0xF0,0xD8,0xCC,0x00,
    // 0x6C 'l'
    0x38,0x18,0x18,0x18,0x18,0x18,0x3C,0x00,
    // 0x6D 'm'
    0x00,0x00,0xCC,0xFE,0xD6,0xC6,0xC6,0x00,
    // 0x6E 'n'
    0x00,0x00,0xFC,0xC6,0xC6,0xC6,0xC6,0x00,
    // 0x6F 'o'
    0x00,0x00,0x7C,0xC6,0xC6,0xC6,0x7C,0x00,
    // 0x70 'p'
    0x00,0x00,0xFC,0xC6,0xC6,0xFC,0xC0,0xC0,
    // 0x71 'q'
    0x00,0x00,0x7E,0xC6,0xC6,0x7E,0x06,0x06,
    // 0x72 'r'
    0x00,0x00,0xDC,0xE6,0xC0,0xC0,0xC0,0x00,
    // 0x73 's'
    0x00,0x00,0x7E,0xC0,0x7C,0x06,0xFC,0x00,
    // 0x74 't'
    0x30,0x30,0x7C,0x30,0x30,0x36,0x1C,0x00,
    // 0x75 'u'
    0x00,0x00,0xC6,0xC6,0xC6,0xC6,0x7E,0x00,
    // 0x76 'v'
    0x00,0x00,0xC6,0xC6,0xC6,0x6C,0x38,0x00,
    // 0x77 'w'
    0x00,0x00,0xC6,0xC6,0xD6,0xFE,0x6C,0x00,
    // 0x78 'x'
    0x00,0x00,0xC6,0x6C,0x38,0x6C,0xC6,0x00,
    // 0x79 'y'
    0x00,0x00,0xC6,0xC6,0xC6,0x7E,0x06,0x7C,
    // 0x7A 'z'
    0x00,0x00,0xFE,0x0C,0x38,0x60,0xFE,0x00,
    // 0x7B '{'
    0x0E,0x18,0x18,0x70,0x18,0x18,0x0E,0x00,
    // 0x7C '|'
    0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x00,
    // 0x7D '}'
    0x70,0x18,0x18,0x0E,0x18,0x18,0x70,0x00,
    // 0x7E '~'
    0x76,0xDC,0x00,0x00,0x00,0x00,0x00,0x00,
    // 0x7F DEL (blank)
    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
};

fn get_glyph(ch as i32) as *u8 {
    let is i64 as idx = cast(i64, ch) * 8;
    return cast(*u8, cast(i64, &font8x8_data) + idx);
}
```

- [ ] **Step 2: Verify it compiles**

```bash
cd /home/caua/Documentos/Projetos-Pessoais/causticos
CAUSTIC=/run/media/caua/Caua/caua/Documentos/Projetos-Pessoais/Caustic
$CAUSTIC/caustic -c font/font8x8.cst
```

Expected: generates `font/font8x8.cst.s` without errors.

- [ ] **Step 3: Commit**

```bash
cd /home/caua/Documentos/Projetos-Pessoais/causticos
git add font/font8x8.cst
git commit -m "font: add 8x8 bitmap font for printable ASCII"
```

---

### Task 7: Create `kernel/fb.cst` -- Framebuffer rendering

**Files:**
- Create: `/home/caua/Documentos/Projetos-Pessoais/causticos/kernel/fb.cst`

- [ ] **Step 1: Write framebuffer module**

Write `kernel/fb.cst`:

```cst
// fb.cst — Framebuffer rendering (32bpp assumed)

use "limine.cst" as limine;
use "../font/font8x8.cst" as font;

// ============================================================
// Module state
// ============================================================

let is *u8 as fb_addr with mut = cast(*u8, 0);
let is i64 as fb_width with mut = 0;
let is i64 as fb_height with mut = 0;
let is i64 as fb_pitch with mut = 0;

// ============================================================
// Functions
// ============================================================

fn init(fb as *limine.LimineFramebuffer) as void {
    fb_addr = fb.address;
    fb_width = fb.width;
    fb_height = fb.height;
    fb_pitch = fb.pitch;
}

fn put_pixel(x as i64, y as i64, color as i32) as void {
    if x < 0 { return; }
    if y < 0 { return; }
    if x >= fb_width { return; }
    if y >= fb_height { return; }
    let is i64 as offset = y * fb_pitch + x * 4;
    let is *i32 as pixel = cast(*i32, cast(i64, fb_addr) + offset);
    pixel[0] = color;
}

fn draw_char(ch as i32, cx as i64, cy as i64, color as i32) as void {
    let is *u8 as glyph = font.get_glyph(ch);
    let is i64 as row with mut = 0;
    while row < 8 {
        let is i64 as bits = cast(i64, glyph[row]);
        let is i64 as col with mut = 0;
        while col < 8 {
            // MSB = leftmost pixel: bit 7 is col 0, bit 6 is col 1, etc.
            let is i64 as mask = 128 >> col;
            if (bits & mask) != 0 {
                put_pixel(cx + col, cy + row, color);
            }
            col = col + 1;
        }
        row = row + 1;
    }
}

fn print(str as *u8, x as i64, y as i64, color as i32) as void {
    let is i64 as i with mut = 0;
    while str[i] != 0 {
        let is i32 as ch = cast(i32, str[i]);
        draw_char(ch, x + i * 8, y, color);
        i = i + 1;
    }
}

fn clear(color as i32) as void {
    let is i64 as y with mut = 0;
    while y < fb_height {
        let is i64 as x with mut = 0;
        while x < fb_width {
            let is i64 as offset = y * fb_pitch + x * 4;
            let is *i32 as pixel = cast(*i32, cast(i64, fb_addr) + offset);
            *pixel = color;
            x = x + 1;
        }
        y = y + 1;
    }
}
```

- [ ] **Step 2: Verify it compiles**

```bash
cd /home/caua/Documentos/Projetos-Pessoais/causticos
CAUSTIC=/run/media/caua/Caua/caua/Documentos/Projetos-Pessoais/Caustic
$CAUSTIC/caustic -c kernel/fb.cst
```

Expected: generates `kernel/fb.cst.s` without errors.

- [ ] **Step 3: Commit**

```bash
cd /home/caua/Documentos/Projetos-Pessoais/causticos
git add kernel/fb.cst
git commit -m "kernel: add framebuffer rendering (put_pixel, draw_char, print, clear)"
```

---

### Task 8: Create `kernel/main.cst` -- Kernel entry point

**Files:**
- Create: `/home/caua/Documentos/Projetos-Pessoais/causticos/kernel/main.cst`

- [ ] **Step 1: Write kernel entry point**

Write `kernel/main.cst`:

```cst
// main.cst — causticos kernel entry point

use "limine.cst" as limine;
use "fb.cst" as fb;

fn halt() as void {
    asm("cli\n");
    while 1 == 1 {
        asm("hlt\n");
    }
}

fn _kernel_start() as void {
    let is *limine.LimineFramebuffer as framebuffer = limine.get_framebuffer();
    if framebuffer == cast(*limine.LimineFramebuffer, 0) {
        halt();
    }

    fb.init(framebuffer);
    fb.clear(cast(i32, 0x001a1a2e));
    fb.print("causticos", 10, 10, cast(i32, 0x00FFFFFF));

    halt();
}
```

- [ ] **Step 2: Verify it compiles**

```bash
cd /home/caua/Documentos/Projetos-Pessoais/causticos
CAUSTIC=/run/media/caua/Caua/caua/Documentos/Projetos-Pessoais/Caustic
$CAUSTIC/caustic kernel/main.cst
```

Expected: generates `kernel/main.cst.s` without errors. Note: we use `caustic` without `-c` here because `main.cst` is the root module.

- [ ] **Step 3: Commit**

```bash
cd /home/caua/Documentos/Projetos-Pessoais/causticos
git add kernel/main.cst
git commit -m "kernel: add entry point with framebuffer text rendering"
```

---

### Task 9: Create build script, limine.conf, and Causticfile

**Files:**
- Create: `/home/caua/Documentos/Projetos-Pessoais/causticos/limine.conf`
- Create: `/home/caua/Documentos/Projetos-Pessoais/causticos/Causticfile`
- Create: `/home/caua/Documentos/Projetos-Pessoais/causticos/scripts/run.sh`

- [ ] **Step 1: Write limine.conf**

Write `limine.conf`:

```
timeout: 0

/causticos
    protocol: limine
    kernel_path: boot():/boot/kernel.elf
```

- [ ] **Step 2: Write Causticfile**

Write `Causticfile`:

```
name "causticos"
version "0.0.1"
author "Caua"

target "kernel" {
    src "kernel/main.cst"
    out "build/kernel.elf"
}
```

- [ ] **Step 3: Write scripts/run.sh**

```bash
mkdir -p /home/caua/Documentos/Projetos-Pessoais/causticos/scripts
```

Write `scripts/run.sh`:

```bash
#!/bin/bash
set -e

CAUSTIC_DIR="/run/media/caua/Caua/caua/Documentos/Projetos-Pessoais/Caustic"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$PROJECT_DIR"

echo "==> Compiling kernel..."
$CAUSTIC_DIR/caustic kernel/main.cst

echo "==> Assembling..."
$CAUSTIC_DIR/caustic-as kernel/main.cst.s

echo "==> Linking (freestanding, higher-half)..."
mkdir -p build
$CAUSTIC_DIR/caustic-ld --freestanding --entry=_kernel_start \
    --base=0xFFFFFFFF80000000 kernel/main.cst.s.o -o build/kernel.elf

echo "==> Creating ISO..."
mkdir -p build/iso/boot/limine build/iso/EFI/BOOT
cp build/kernel.elf build/iso/boot/
cp limine.conf build/iso/boot/limine/
cp /usr/share/limine/limine-bios.sys build/iso/boot/limine/
cp /usr/share/limine/limine-bios-cd.bin build/iso/boot/limine/
cp /usr/share/limine/limine-uefi-cd.bin build/iso/boot/limine/
cp /usr/share/limine/BOOTX64.EFI build/iso/EFI/BOOT/

xorriso -as mkisofs -b boot/limine/limine-bios-cd.bin -no-emul-boot \
    -boot-load-size 4 -boot-info-table --efi-boot boot/limine/limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    build/iso -o build/causticos.iso 2>/dev/null

limine bios-install build/causticos.iso 2>/dev/null

echo "==> Booting in QEMU..."
qemu-system-x86_64 -cdrom build/causticos.iso -m 128M
```

- [ ] **Step 4: Make run.sh executable**

```bash
chmod +x /home/caua/Documentos/Projetos-Pessoais/causticos/scripts/run.sh
```

- [ ] **Step 5: Commit**

```bash
cd /home/caua/Documentos/Projetos-Pessoais/causticos
git add limine.conf Causticfile scripts/run.sh
git commit -m "add build script, limine config, and Causticfile"
```

---

### Task 10: Build, boot, and verify

**Files:** None (integration test)

- [ ] **Step 1: Run the full build + boot pipeline**

```bash
cd /home/caua/Documentos/Projetos-Pessoais/causticos
./scripts/run.sh
```

Expected: QEMU window opens showing "causticos" in white text on a dark background near the top-left corner.

- [ ] **Step 2: If compilation fails, debug**

Check which phase failed:
- Compile error: fix Caustic syntax in the failing `.cst` file
- Assemble error: inspect the generated `.s` file for invalid instructions
- Link error: check `caustic-ld` output (try with `-v` for verbose)
- Boot error: check QEMU output, try adding `-serial stdio` to QEMU to see serial output

- [ ] **Step 3: If kernel boots but shows nothing**

Add QEMU serial debug flag to `scripts/run.sh`:

```bash
qemu-system-x86_64 -cdrom build/causticos.iso -m 128M -serial stdio
```

Common issues:
- Limine can't find the kernel: check `limine.conf` path matches ISO layout
- Framebuffer request not found: check magic numbers in `limine.cst` match protocol spec
- Entry point wrong: run `readelf -h build/kernel.elf` and verify `e_entry`

- [ ] **Step 4: Add .gitignore and final commit**

Write `.gitignore`:

```
build/
*.s
*.o
```

```bash
cd /home/caua/Documentos/Projetos-Pessoais/causticos
git add .gitignore
git commit -m "add .gitignore for build artifacts"
```
