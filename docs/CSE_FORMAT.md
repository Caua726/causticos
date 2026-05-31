# CSE — Caustic Standard Executable (v2 format / causticos ABI contract)

This is the contract between **two sides**:

- **kernel** (`kernel/cse.cst`) — loads CSE images. **Implemented (v2).**
- **toolchain** (`caustic-ld` + the `caustic-x86_64` target backend, branch
  `cse-ultraplan`) — emits CSE images that call the causticos syscall
  numbers. **Working** — a real `hello.cse` loads, prints, and exits
  cleanly through this loader.

CSE is causticos' own executable format: deliberately simpler than ELF —
**static only, fixed load base, no relocations, no dynamic linking.** It
is *provisional* (format `version = 2`; v1 was a flat single image and is
gone), frozen at self-host like the syscall ABI.

---

## 1. Containers

A CSE file is one of:

| Container | First bytes | How to find the CST image |
|---|---|---|
| pure `.cse` | `"CST_"` (43 53 54 5F) | the whole file IS the image, offset 0 |
| polyglot `.cse.exe` | `"MZ"` (4D 5A) | read the `"CST*"` mini-header at **0x40** → `cst_body_offset` (@0x48, u64), `cst_body_size` (@0x50, u64) |

The `.cse` is **polyglot**: the `caustic-x86_64` target welds a causticos
(CST), a Linux (ELF), and a Windows (PE) image into one file, APE /
Cosmopolitan-style — macOS planned — so the same binary runs natively on
each, every image calling its own OS's syscalls. On causticos the kernel
pulls out the CST image: the whole file for a pure `.cse`, or the embedded
body behind the `"CST*"` mini-header for a polyglot `.cse.exe`. It handles
both.

(The older self-extract polyglot — `#!/bin/sh` + ELF@512 + CST, no
`CST*`@0x40 — is **not** supported by the loader. Standardize on the
`caustic-ld --cse-combine` layout, which has `CST*`@0x40.)

---

## 2. File layout

```
[ header 32B ] [ segment table: seg_count × 24B ] [ segment bytes ]
[ optional NUL-terminated version string ]
```

### Header (32 bytes @0, little-endian)

| Off | Size | Field | Value |
|---|---|---|---|
| 0x00 | 4 | magic | `"CST_"` |
| 0x04 | 2 | version (u16) | `2` |
| 0x06 | 1 | arch (u8) | `1` = x86_64 |
| 0x07 | 1 | flags (u8) | `0` |
| 0x08 | 8 | entry_point (u64) | absolute vaddr to jump to |
| 0x10 | 8 | base_addr (u64) | `0x400000` (informative; segments carry abs vaddrs) |
| 0x18 | 4 | seg_count (u32) | number of segments |
| 0x1C | 4 | app_version_off (u32) | offset of NUL-term version string; `0` = none |

### Segment (24 bytes, from @0x20)

| Off | Size | Field |
|---|---|---|
| +0x00 | 8 | vaddr (page-aligned) |
| +0x08 | 4 | file_off (offset in the file; `0` if pure bss) |
| +0x0C | 4 | file_size (bytes to copy) |
| +0x10 | 4 | mem_size (bytes in memory; `> file_size` ⇒ zero-fill = bss) |
| +0x14 | 4 | perms (`bit0=R, bit1=W, bit2=X`) |

Typical perms: `.text=5` (R+X), `.rodata=1` (R), `.data/.bss=3` (R+W).

## 3. Load model

- **Fixed base `0x400000`** — the image is **not** position-independent;
  relocations are baked against the base, so it must load at `0x400000`.
- **Copy, not mmap-of-file:** `file_off` is packed (not congruent to
  `vaddr mod 4096`), so each segment is mapped anonymously and its
  `file_size` bytes copied in; the `[file_size, mem_size)` tail is left
  zeroed (the anonymous mapping zero-fills). This is why the file is tiny
  (~615 B for hello) — no page padding.
- **Per-segment W^X:** each segment's pages get its own `perms`. The
  linker page-aligns every segment's `vaddr` and keeps `.text` alone on
  its pages, so per-segment mapping never double-maps a page. (If a future
  binary packs two segments into one page, the second map overlaps and the
  loader fails loudly — to be handled with perm-OR if it ever happens.)

## 4. Loader algorithm (what `kernel/cse.cst` does)

```
detect container → (cst_off, cst_size)
validate header: magic "CST_", version==2, arch==1
entry = u64(0x08);  nseg = u32(0x18)
for each segment e in 0..nseg:
    vaddr, file_off, file_size, mem_size, perms = fields
    reject if mem_size < file_size, or file_off+file_size > cst_size
    p0  = vaddr & ~0xFFF
    end = page_align(vaddr + mem_size)
    mmap_anon(p0, end-p0, perms_to_prot(perms))     # R / R+W / R+X
    if file_size > 0: copy file_size bytes (img+cst_off+file_off → vaddr)
    # bss (mem_size > file_size) left zeroed by mmap_anon
build the System V initial stack; jump to entry_point   # no relocation
```

## 5. Entry ABI (identical to ELF)

At `entry_point`, the stack holds the System V AMD64 frame:
`rsp → argc, argv[]…, NULL, envp[]…, NULL, auxv[]…, AT_NULL`. `rsp` is
16-byte aligned. (Reuses `kernel/elf.cst::build_initial_stack`.)

---

## 6. Syscall ABI contract — what the `caustic-x86_64` target must emit

The register convention is **identical to Linux x86_64**, so only the
numbers and the operation set change:

- `rax` = syscall number
- args: `rdi, rsi, rdx, r10, r8, r9`
- return in `rax`; negative = causticos errno
- **clobbered:** `rax, rcx, r11`, and the arg registers (`rdi/rsi/rdx/r10/r8/r9`).
  **preserved:** `rbx, rbp, r12–r15, rsp` — exactly like a C call. Hold any
  value that must survive a syscall in a callee-saved register.

### Syscall numbers + the full operation set

The register convention above is the stable part. The **syscall numbers,
arguments, errnos, struct layouts, and usage patterns** now live in their own
reference — **[syscall-abi.md](syscall-abi.md)** — because the set has grown
well past the original five. As of `SYS_COUNT = 25` it includes fd-based file
I/O (`open/read/write/close/lseek` + metadata), user `mmap`/`munmap`,
processes (`spawn`/`wait` with fd handoff), the display (`dev_open`/`present`),
IPC (`channel_create`), and the keyboard device. The `caustic-x86_64` syscall
lib emits one thin wrapper per entry there.

> Historical note: this section once listed only 7 calls (write/exit/getpid/
> sleep/time) and said "no read/open/mmap yet" — true at CSE bring-up
> (2026-05-17), long obsolete now. See syscall-abi.md for the live contract.

---

## 7. Limitations / future (v3) candidates

- base `0x400000` is fixed & non-relocable → no ASLR (v3: PIE + a reloc table + a flags bit).
- only the `CST*`@0x40 polyglot layout is supported (not the older `#!/bin/sh` self-extract scan).
- no capability manifest yet — the slot for spawn's required-caps declaration, the substantive reason CSE will outgrow "ELF, but ours". Arrives with the capability chain.

(v2 already fixed v1's coarse perms — each segment now carries its own
R/W/X — and made bss explicit per-segment via `mem_size > file_size`.)
