# causticos — userspace syscall ABI (v0)

The full contract a ring-3 program (and the `caustic-x86_64` backend's
syscall lib) needs to talk to the kernel. Pairs with
[CSE_FORMAT.md](CSE_FORMAT.md) (the executable container + entry ABI) and
[architecture.md](architecture.md) (*why* each call is shaped this way).

> Status: **v0, provisional** — numbers/layouts may still change until
> self-host (then `ABI_MAJOR` gates incompatible changes). Source of truth:
> `kernel/abi.cst` + the handlers in `kernel/syshandlers.cst`. `SYS_COUNT = 25`
> (syscall `N` exists iff `N < SYS_COUNT`; probe it via `KERN_INFO`).

---

## 1. Calling convention

Identical register layout to Linux x86_64 — only the numbers and the
operation set differ.

- `rax` = syscall number; execute `syscall` (`0F 05`).
- args, in order: `rdi, rsi, rdx, r10, r8, r9` (System V order, but **`r10`
  not `rcx`** — `syscall` clobbers `rcx` with the return RIP).
- return in `rax`: **`< 0` is a causticos errno**, `>= 0` is a per-call success value.
- **clobbered** by the instruction: `rax, rcx, r11` + the arg registers used.
  **preserved:** `rbx, rbp, r12–r15, rsp` — like a C call. Keep anything that
  must survive a syscall in a callee-saved register.

---

## 2. Syscalls

Args are listed by register. "→" is the `rax` return.

| #  | name | `rdi` | `rsi` | `rdx` | `r10` | `r8` | → |
|----|------|-------|-------|-------|-------|------|---|
| 0  | `KERN_INFO` | buf | buf_size | | | | bytes written, or size if buf_size=0 |
| 1  | `TIME_NOW_NS` | | | | | | monotonic ns since boot |
| 2  | `TIME_SLEEP_NS` | ns | | | | | 0 \| errno |
| 3  | `PROC_EXIT` | code | | | | | never returns |
| 4  | `PROC_GETPID` | | | | | | pid (tid if no Process) |
| 5  | `PROC_YIELD` | | | | | | 0 |
| 6  | `IO_WRITE_SERIAL` | buf | len | | | | bytes \| errno (kernel console; fd-less, for diagnostics) |
| 7  | `MMAP` | hint | len | prot | fd | | vaddr \| errno |
| 8  | `MUNMAP` | addr | len | | | | 0 \| errno |
| 9  | `OPEN` | path | path_len | flags | | | fd \| errno |
| 10 | `READ` | fd | buf | n | | | bytes (0 = EOF) \| errno |
| 11 | `WRITE` | fd | buf | n | | | bytes \| errno |
| 12 | `CLOSE` | fd | | | | | 0 \| errno |
| 13 | `LSEEK` | fd | off | whence | | | new offset \| errno |
| 14 | `SPAWN` | img | img_len | fdacts | n_acts | | child pid \| errno |
| 15 | `WAIT` | pid | status_ptr | | | | exit code \| `E_AGAIN` |
| 16 | `UNLINK` | path | path_len | | | | 0 \| errno |
| 17 | `MKDIR` | path | path_len | | | | 0 \| errno |
| 18 | `RMDIR` | path | path_len | | | | 0 \| errno |
| 19 | `RENAME` | src | src_len | dst | dst_len | | 0 \| errno |
| 20 | `STAT` | path | path_len | out | | | 0 \| errno (out = `VfsStat`) |
| 21 | `READDIR` | fd | out | | | | 0 (entry) \| `E_NOENT` (end) (out = `VfsDirEntry`) |
| 22 | `DEV_OPEN` | class | index | flags | | | fd \| errno |
| 23 | `PRESENT` | fd | x | y | w | h | 0 \| errno |
| 24 | `CHANNEL_CREATE` | out_ptr | | | | | 0; writes `[fd_a, fd_b]` (2×i64) \| errno |

**Pointers are user virtual addresses**; the kernel copies in/out and
validates them (bad pointer → `E_FAULT`). All sizes/counts are bytes unless
noted.

Per-call notes:

- **`MMAP`** (7): anonymous by default. `prot` = `MMAP_PROT_*` bits. If `prot`
  has the `MMAP_FD` bit set, **`r10` is an fd** whose object backs the
  mapping (a surface's backbuffer) and `len` is ignored — the object decides
  the size. `hint = 0` lets the kernel pick the VA; non-zero is honoured
  exactly (fail on overlap). Pages are mapped eagerly (no demand paging yet).
- **`READ`/`WRITE`** (10/11) work on **any fd kind**: a file, a channel
  endpoint, a keyboard device. They block where the object blocks (a channel
  read waits for bytes; a keyboard read waits for events; `0` from a channel
  = the peer closed = EOF).
- **`SPAWN`** (14): only a Process may spawn (`E_PERM` otherwise). The child's
  fd table starts **empty**; `fdacts` (a `[{child_fd, src_fd}]` array,
  `n_acts ≤ 16`) is the *only* way it gets keys — see §6. `img` is the in-memory
  CSE image (≤ 64 KiB in v0). There is **no spawn-by-path**; read the file
  yourself and pass the bytes.
- **`WAIT`** (15): `pid > 0` waits that child; reaps it; returns its exit code
  (also written to `status_ptr` as i64 if non-zero). `E_AGAIN` if none exits
  in the window.
- **`DEV_OPEN`** (22): acquire a device *by class* (§5). No `/dev` path, no
  permission gate — any program may ask. `index`/`flags` are 0 in v0.
- **`PRESENT`** (23): publish a surface's damage rect `[x,y,w,h]` to the
  scanout. Only a surface fd has it; other fds → `E_INVAL`.

---

## 3. Errnos (`rax < 0`)

| value | name | | value | name |
|---|---|---|---|---|
| 0 | `E_OK` | | -9 | `E_NOENT` |
| -1 | `E_INVAL` | | -10 | `E_EXIST` |
| -2 | `E_NOSYS` | | -11 | `E_ISDIR` |
| -3 | `E_FAULT` | | -12 | `E_NOTDIR` |
| -4 | `E_BADF` | | -13 | `E_MFILE` |
| -5 | `E_NOMEM` | | -14 | `E_NOSPC` |
| -6 | `E_RANGE` | | -15 | `E_IO` |
| -7 | `E_PERM` | | -16 | `E_PIPE` (write to a channel whose far end closed) |
| -8 | `E_AGAIN` | | | |

---

## 4. Constants

```
MMAP_PROT_READ  = 1     MMAP_PROT_WRITE = 2     MMAP_PROT_EXEC = 4
MMAP_FD         = 0x10   # OR into prot → r10 is an fd-backed mapping

O_RDONLY = 0x0000   O_WRONLY = 0x0001   O_RDWR  = 0x0002
O_CREAT  = 0x0040   O_EXCL   = 0x0080   O_TRUNC = 0x0200   O_APPEND = 0x0400

SEEK_SET = 0   SEEK_CUR = 1   SEEK_END = 2

DEV_FB        = 0    # framebuffer → a surface
DEV_KEYBOARD  = 1    # keyboard   → a raw-event device

ABI_MAJOR = 0   ABI_MINOR = 1   KERN_INFO_SIZE = 48
```

---

## 5. Data layouts

All integers little-endian. Field offsets matter — these are the byte
layouts the kernel reads/writes.

**`KernInfo`** (48 B, from `KERN_INFO`): six i64 —
`info_size, abi_major, abi_minor, syscalls_max (=SYS_COUNT), page_size (4096), flags`.

**`VfsStat`** (32 B, from `STAT`): four i64 — `size, first_cluster, attr, is_dir`.

**`VfsDirEntry`** (from `READDIR`): `name[256]` (u8, NUL-padded), then five i64 —
`name_len, first_cluster, size, attr, is_dir`.

**`FdAction`** (16 B; `SPAWN`'s `fdacts` is an array of these): two i64 —
`child_fd, src_fd`. Installs the KObject the parent holds at `src_fd` into the
child's table at `child_fd`.

**Keyboard event** (2 B per event; `READ` on a `DEV_KEYBOARD` fd returns a
multiple of 2): byte 0 = scancode (PS/2 set-1, `0..0x7F`); byte 1 = flags —
**bit0 = pressed** (1) / released (0), **bit1 = extended** (was `0xE0`-prefixed).
The kernel applies **no keymap** — scancode→char/layout is your job.

---

## 6. Usage patterns (what the terminal/shell actually do)

**Draw on screen (fullscreen app or compositor):**
```
fd  = DEV_OPEN(DEV_FB, 0, 0)
va  = MMAP(0, 0, MMAP_PROT_WRITE | MMAP_FD, fd)   # backbuffer, len ignored
... write 32bpp pixels into [va ..] ...
PRESENT(fd, x, y, w, h)                            # blit damage to the scanout
```
> ⚠ **Missing today (see §7):** there is no call to learn the surface's
> width/height/pitch/bpp, so the app can't know the backbuffer geometry. This
> is the one gap to close before a real terminal.

**Read the keyboard (raw):**
```
kfd = DEV_OPEN(DEV_KEYBOARD, 0, 0)
READ(kfd, &ev, 2)        # ev[0]=scancode, ev[1]=flags; blocks for an event
# apply your keymap + modifier tracking here (userspace)
```

**IPC / give a child its console (the founding pattern):**
```
CHANNEL_CREATE(&fds)                 # fds[0]=fd_a (keep), fds[1]=fd_b (hand off)
acts = [ {child_fd: 0, src_fd: fd_b} ]
pid  = SPAWN(child_img, len, acts, 1)   # child gets the endpoint as its fd 0
WRITE(fd_a, buf, n)  /  READ(fd_a, buf, n)   # talk to the child; child uses fd 0
WAIT(pid, &status)
```
A console **is** a channel: the terminal keeps one end (renders the bytes the
shell writes, feeds the keys it typed), the shell holds the other as stdio.
For a pipe `a | b`, mint a pair and hand the write end to `a`, the read end to `b`.

**Run a program (the shell):** there is no exec-by-path. Do it explicitly:
```
fd  = OPEN(path, len, O_RDONLY)
sz  = LSEEK(fd, 0, SEEK_END);  LSEEK(fd, 0, SEEK_SET)
buf = MMAP(0, sz, MMAP_PROT_READ|MMAP_PROT_WRITE)   # anonymous scratch
READ(fd, buf, sz);  CLOSE(fd)
pid = SPAWN(buf, sz, console_acts, n)               # hand it a console channel
WAIT(pid, &status)
```

---

## 7. Gaps to close in the kernel before the terminal (Fatia 4)

These are **my** side (kernel work), not yours — flagged so we both know
what's missing:

1. **Surface geometry query.** A surface fd gives you a backbuffer pointer but
   no dimensions. Needs a small syscall, e.g. `SYS_SURFACE_INFO(fd, out)` →
   `{width, height, pitch, bpp_bytes}` (4×i64), or `SYS_DEV_INFO(fd, out)`
   generalised. **Blocking for any real drawing.**
2. **Terminal bootstrap.** Today only kernel-side smokes spawn ring-3
   programs. To launch a real terminal the kernel needs an "init userspace"
   step: `OPEN("/bin/terminal.cse") → READ → proc_spawn → proc_start` from the
   boot path (the `.cse` lives on the FAT32 disk you seed), or an embedded
   image. The terminal then `DEV_OPEN`s the surface + keyboard itself.
3. *(nice-to-have)* `SYS_PROC_KILL` for the shell to stop a runaway child;
   today only graceful exit + `WAIT`. Not required for a first terminal.

Everything else the terminal/shell need — `dev_open`, `mmap`+`present`,
channels, `fdacts`, `open/read/write/lseek/close`, `spawn/wait` — is **built
and proven from ring 3** (see architecture.md §11).

---

## 8. What the toolchain side needs (your work)

- A **syscall lib** for the `caustic-x86_64` causticos target: thin wrappers
  that load `rax` + args and execute `syscall`, one per §2 entry, returning
  `rax` (negative = errno). The clobber set in §1 is the inline-asm contract.
- A **keymap** (scancode set-1 → char, modifier state) for the terminal.
- An **8×8 font** in userspace for text rendering (the kernel's
  `font/font8x8.cst` is the reference; it moves out of the kernel).
- The **terminal** and **shell** programs themselves, emitted as `.cse`
  (CSE_FORMAT.md) for the `caustic` target.
```

