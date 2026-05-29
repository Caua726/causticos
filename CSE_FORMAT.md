# CSE — Caustic Standard Executable (v1 format / causticos ABI contract)

This is the contract between **two sides**:

- **kernel** (`kernel/cse.cst`) — loads CSE images. **Implemented.**
- **toolchain** (`caustic-ld` + `std/os/causticos.cst`, branch `cse-ultraplan`)
  — emits CSE images for the `causticos-x86_64` target and calls the
  causticos syscall numbers. **To do (the OS_CAUSTICOS work).**

CSE is causticos' own executable format: deliberately simpler than ELF —
**static only, fixed load base, no section table, no relocations, no
dynamic linking.** It is *provisional* (format `version = 1`), frozen at
self-host like the syscall ABI.

---

## 1. Containers

A CSE file is one of:

| Container | First bytes | How to find the CST image |
|---|---|---|
| pure `.cse` | `"CST_"` (43 53 54 5F) | the whole file IS the image, offset 0 |
| polyglot `.cse.exe` | `"MZ"` (4D 5A) | read the `"CST*"` mini-header at **0x40** → `cst_body_offset` (@0x48, u64), `cst_body_size` (@0x50, u64) |

**causticos-target binaries are pure `.cse`.** The polyglot exists only so
a binary can *also* run on Windows/Linux (APE-style); causticos binaries
don't need that, so the toolchain should emit **pure CST_** for
`causticos-x86_64`. The kernel handles both; pure is canonical.

(The older self-extract polyglot — `#!/bin/sh` + ELF@512 + CST, no
`CST*`@0x40 — is **not** supported by the loader. Standardize on the
`caustic-ld --cse-combine` layout, which has `CST*`@0x40.)

---

## 2. CST_ image header (32 bytes, little-endian)

| Off | Size | Field | Value |
|---|---|---|---|
| 0x00 | 4 | magic | `"CST_"` |
| 0x04 | 2 | version (u16) | `1` |
| 0x06 | 1 | arch (u8) | `1` = x86_64 |
| 0x07 | 1 | flags (u8) | `0` |
| 0x08 | 8 | entry_point (u64) | absolute vaddr to jump to |
| 0x10 | 4 | text_off (u32) | file offset of `.text` (= `0x1000`) |
| 0x14 | 4 | text_size (u32) | bytes of `.text` |
| 0x18 | 8 | bss_size (u64) | zero-filled tail, NOT present in the file |

## 3. Load model & memory map

- **Fixed base `0x400000`** — implicit, NOT in the header. The image is
  flat: `vaddr == base + file_offset` for every stored byte. It is **not**
  position-independent; relocations are baked against the base, so it
  **must** load at `0x400000`.
- `stored_size` = the CST image size (whole file for pure; `cst_body_size`
  for polyglot). `.bss` begins at `base + stored_size` (no separate vaddr).
- **Permissions (W^X):**
  - `[base, page_align(base + text_off + text_size))` → **R-X** (header + .text)
  - `[that boundary, base + stored_size + bss_size)` → **R-W** (rodata/data + bss)
- **Producer requirement:** page-align `stored_size` so `.bss`
  (`base + stored_size`) lands at/after the R-X boundary — otherwise bss
  falls in the R-X region and the first write faults.

## 4. Loader algorithm (what `kernel/cse.cst` does)

1. detect container → `(cst_off, cst_size)`
2. validate CST_ header: magic, `version==1`, `arch==1`
3. `rx_size = page_align(text_off + text_size)`
4. `mmap_anon(base, rx_size, R-X)`
5. `mmap_anon(base+rx_size, (stored_size+bss_size) - rx_size, R-W)`
6. copy `stored_size` bytes of the image to `base` (bss tail auto-zeroed)
7. build the System V initial stack, jump to `entry_point` — **no relocation**

## 5. Entry ABI (identical to ELF)

At `entry_point`, the stack holds the System V AMD64 frame:
`rsp → argc, argv[]…, NULL, envp[]…, NULL, auxv[]…, AT_NULL`. `rsp` is
16-byte aligned. (Reuses `kernel/elf.cst::build_initial_stack`.)

---

## 6. Syscall ABI contract — what `OS_CAUSTICOS` must emit

The register convention is **identical to Linux x86_64**, so only the
numbers and the operation set change:

- `rax` = syscall number
- args: `rdi, rsi, rdx, r10, r8, r9`
- return in `rax`; negative = causticos errno
- **clobbered:** `rax, rcx, r11`, and the arg registers (`rdi/rsi/rdx/r10/r8/r9`).
  **preserved:** `rbx, rbp, r12–r15, rsp` — exactly like a C call. Hold any
  value that must survive a syscall in a callee-saved register.

### v0 syscall numbers (causticos, see `kernel/abi.cst`)

| # | name | args | notes |
|---|---|---|---|
| 0 | KERN_INFO | `(buf, buf_size)` | fills KernInfo; `size==0` returns required size |
| 1 | TIME_NOW_NS | `()` | returns monotonic ns in `rax` |
| 2 | TIME_SLEEP_NS | `(ns)` | |
| 3 | PROC_EXIT | `(code)` | never returns |
| 4 | PROC_GETPID | `()` | returns tid |
| 5 | PROC_YIELD | `()` | |
| 6 | IO_WRITE_SERIAL | `(buf, len)` | kernel console; **no fd** |

### Mapping the stdlib facade → causticos (for `std/os/causticos.cst`)

These are **semantic adapters**, not renumbered Linux wrappers — the
operations differ in shape:

| stdlib op | causticos call | note |
|---|---|---|
| `write(fd, buf, n)` | `syscall(6, buf, n)` | fd∈{1,2}→serial; **drops fd** in v0 |
| `exit(code)` | `syscall(3, code)` | |
| `getpid()` | `syscall(4)` | |
| sleep / nanosleep | `syscall(2, ns)` | |
| clock / time-now | `syscall(1)` → ns | |

### v0 limit (honest)

Only programs using **write / exit / getpid / sleep / time** run. There is
**no `read`, `open`, `close`, `mmap`, `brk`** yet — causticos has no
fd-based file I/O or user mmap syscall. Those arrive with the **capability
chain** (a `FILE` object type, fd-based read/write/open, a user `mmap`),
which is the next ABI-growth step, gated on the self-host need. A `hello +
exit` program is the realistic first CSE target; reading a file is not yet.

---

## 7. v0 limitations / v2 candidates

- base `0x400000` implicit & non-relocable → no ASLR (v2: PIE + reloc table + a header base/flags field).
- no fine section perms: rodata shares the R-W segment (v2: a third R-only segment).
- bss vaddr derived (`base + stored_size`), not stored (v2: explicit `vm_size`).
- only the `CST*`@0x40 polyglot layout is supported (not the self-extract scan).
- no capability manifest yet (v2: the slot for spawn's required-caps declaration — the substantive reason CSE will outgrow "ELF, but ours").
