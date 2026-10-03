# causticos — userspace syscall ABI (v0)

The full contract a ring-3 program (and the `caustic-x86_64` backend's
syscall lib) needs to talk to the kernel. Pairs with
[CSE_FORMAT.md](CSE_FORMAT.md) (the executable container + entry ABI) and
[architecture.md](architecture.md) (*why* each call is shaped this way).

> Status: **v0, provisional** — numbers/layouts may still change until
> self-host (then `ABI_MAJOR` gates incompatible changes). Source of truth:
> `kernel/abi.cst` + the handlers in `kernel/sys/syshandlers.cst`.
> **`SYS_COUNT = 55`** (syscall `N` exists iff `N < SYS_COUNT`; probe it via
> `KERN_INFO`).
>
> All 55 are listed. §2 covers 0–26, §2b covers 27–54.

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
| 14 | `SPAWN` | *SpawnParams | | | | | child pid \| errno |
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
| 25 | `SURFACE_INFO` | fd | out | | | | 0; writes `{w,h,pitch,bpp,fmt}` (5×i64) \| errno |
| 26 | `DEV_COUNT` | class | | | | | count (≥ 0) |

### 2b. Syscalls 27–54

Appended after the first table was written, and each is documented at its number
in `kernel/abi.cst` — that comment is the source of truth for the exact layout of
whatever struct it fills.

| #  | name | args (`rdi, rsi, rdx, r10, r8`) | → |
|----|------|------|---|
| 27 | `COMMIT` | addr, len, prot | 0 \| errno — back a reserved range with frames |
| 28 | `DECOMMIT` | addr, len | 0 \| errno — drop the frames, keep the reservation |
| 29 | `SEG_CREATE` | npages, flags | fd \| errno — shareable RAM behind a key |
| 30 | `SEG_CLONE` | fd | fd \| errno — a second fd over the same frames |
| 31 | `SEG_COPY` | fd, off, ubuf, len, dir | 0 \| errno; dir 0 = seg→buf, 1 = buf→seg |
| 32 | `FD_SEND` | chan_fd, fd | 0 \| `E_AGAIN` (slot busy) — one-slot SCM_RIGHTS |
| 33 | `FD_RECV` | chan_fd | fd \| `E_AGAIN` (nothing pending) |
| 34 | `POLL` | entries, n, timeout_ns | n_ready \| errno (§5 `PollEntry`) |
| 35 | `PROC_KILL` | pid | 0 \| `E_NOENT` (not your child) |
| 36 | `PROC_LIST` | entries, max | total live count (may exceed `max`) |
| 37 | `MEM_INFO` | out | 0; `[total_pages, free_pages, page_size, committed]` |
| 38 | `STATFS` | out | 0; `[total_bytes, free_bytes, block_size]` |
| 39 | `CPU_STAT` | out | ncpu; `[ncpu, busy_ns per cpu…, now_ns]`, cumulative |
| 40 | `TIME_WALL` | out | 0; raw RTC `[year,month,day,hour,min,sec]` |
| 41 | `POWEROFF` | | does not return — ACPI S5 |
| 42 | `REBOOT` | | does not return |
| 43 | `POWER_PENDING` | | what is asked of the power: 0, `POWER_OFF` (1), `POWER_REBOOT` (2); polling it is the desktop listening |
| 44 | `STATX` | path, len, out | 0 \| errno — `stat` plus mtime |
| 45 | `EVENT_SUBSCRIBE` | pid, mask | fd \| errno — the signal replacement |
| 46 | `THREAD_SPAWN` | entry, arg, stack_top | tid \| errno (same aspace) |
| 47 | `THREAD_EXIT` | code | does not return |
| 48 | `QUERY_DEVS` | out, max | total device count |
| 49 | `DEV_INFO` | class, index, out | 0 \| errno |
| 50 | `NET_INFO` | net_fd, out | 0 \| errno — mtu, link state, frame_max |
| 51 | `GET_RANDOM` | buf, len | bytes \| errno |
| 52 | `RANDOM_QUALITY` | | `RANDOM_*` — says when the machine has no real entropy |
| 53 | `AUDIO_INFO` | audio_fd, out | 0 \| errno — the geometry the stream opened with |
| 54 | `CHAN_INFO` | chan_fd, out | 0 \| errno |
| 55 | `POWER_REQUEST` | kind | 0 \| `E_INVAL` — asks for `POWER_OFF`/`POWER_REBOOT` the way the power button does: a listening desktop closes its windows first; with none, or asked twice, the kernel acts at once |
| 56 | `POWER_CANCEL` | | 0 — the pending request is dropped (a window would not close) |

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
- **`SPAWN`** (14): takes ONE pointer, to a `SpawnParams` (§5). Only a Process
  may spawn (`E_PERM` otherwise). The child's fd table starts **empty**; `fdacts`
  (a `[{child_fd, src_fd}]` array, `n_acts ≤ 16`) is the *only* way it gets
  keys — see §6.

  A spawn **names its source**; it does not carry the image. `src_kind` selects
  either a path the kernel opens (`SPAWN_SRC_PATH`) or an fd you already hold
  (`SPAWN_SRC_FD` — a file, or a **segment** for an image that never came from
  the filesystem, which is the `memfd_create` + `execveat` shape). An fd source
  is borrowed: it stays yours and you still close it.

  It used to take the bytes, and every caller paid the same three copies for it —
  an eager-committed one in the parent, a staging one in the kernel, and the
  loader's into the child — with nothing shared between two processes running the
  same program. The kernel now reads the source once into frames that every later
  spawn of that file maps instead of copying. While a process is running from a
  file, writing/unlinking/renaming it is `E_TXTBSY`.
  `argv` (r8) is an array of `argc` (r9, ≤ 32) `{str_ptr, str_len}` i64 pairs —
  the child's argument vector, copied onto its initial System V stack (at
  `_start`, `rsp` → `argc`, then `argv[0..n]`, NULL, **empty envp**, auxv). argv
  is **data, not authority**: the kernel never resolves it (a path in argv is
  just bytes; the child acts on it only through fds it was handed). `argc = 0`
  → the child's argv defaults to `["child"]`. fds = capability, argv = data —
  two separate explicit channels, nothing inherited.
- **`WAIT`** (15): `pid > 0` waits that child; reaps it; returns its exit code
  (also written to `status_ptr` as i64 if non-zero). `E_AGAIN` if none exits
  in the window.
- **`DEV_OPEN`** (22): acquire a device *by class* (§5). No `/dev` path, no
  permission gate — any program may ask. `index` selects the *index-th*
  instance of the class and is **real**: `DEV_OPEN(DEV_KEYBOARD, 1)` with one
  keyboard is `E_NOENT`, never a silent alias of instance 0. `flags` is 0 in
  v0. Pair with `DEV_COUNT` to enumerate. `E_NOMEM` means the instance exists
  but minting its object failed.
- **`PRESENT`** (23): publish a surface's damage rect `[x,y,w,h]` to the
  scanout. Only a surface fd has it; other fds → `E_INVAL`.
- **`SURFACE_INFO`** (25): the read-counterpart of `PRESENT`. Copies the
  surface's `{width, height, pitch, bpp_bytes, format}` (5×i64 = 40 B) to
  `out` so the holder can index its `mmap`'d backbuffer (`pitch` may exceed
  `width × bpp` when rows are padded). `format` is `SURFACE_FMT_XRGB8888 (0)`
  in v0. Non-surface fd → `E_INVAL`.
- **`DEV_COUNT`** (26): how many instances of `class` are registered (≥ 0).
  The enumeration counterpart of `DEV_OPEN`: ask, then `DEV_OPEN` each index
  `0..count-1`. An unserved class is honestly `0`, not an error. Pure query.

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
| -8 | `E_AGAIN` | | -17 | `E_TXTBSY` (change a file a live process was loaded from) |

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

**`SpawnParams`** (72 B, `SPAWN`'s only argument): nine i64 —
`src_kind, src_fd, path_uptr, path_len, fdacts_uptr, n_acts, argv_uptr, argc,
budget`. `src_kind` is `SPAWN_SRC_PATH (0)` or `SPAWN_SRC_FD (1)`; anything else
is `E_INVAL`, because a source is named explicitly rather than inferred from
whichever field happens to be non-zero (fd 0 is a real fd). `budget` 0 = no
ceiling; > 0 caps the child's `committed_bytes`.

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
SURFACE_INFO(fd, &info)                           # {w,h,pitch,bpp,fmt} (5×i64)
va  = MMAP(0, 0, MMAP_PROT_WRITE | MMAP_FD, fd)   # backbuffer, len ignored
... write 32bpp pixels at va + y*info.pitch + x*info.bpp ...
PRESENT(fd, x, y, w, h)                            # blit damage to the scanout
```

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
sp   = { src_kind: SPAWN_SRC_PATH, path: "/cat.cse", path_len: 8,
         fdacts: acts, n_acts: 1 }
pid  = SPAWN(&sp)                       # child gets the endpoint as its fd 0
WRITE(fd_a, buf, n)  /  READ(fd_a, buf, n)   # talk to the child; child uses fd 0
WAIT(pid, &status)
```
A console **is** a channel: the terminal keeps one end (renders the bytes the
shell writes, feeds the keys it typed), the shell holds the other as stdio.
For a pipe `a | b`, mint a pair and hand the write end to `a`, the read end to `b`.

**Run a program (the shell):** name it, do not carry it.
```
argv = [{ "cat",3 }, { "foo.txt",7 }]               # parsed from the command line
sp   = { src_kind: SPAWN_SRC_PATH, path: "/cat.cse", path_len: 8,
         fdacts: console_acts, n_acts: n, argv: argv, argc: 2 }
pid  = SPAWN(&sp)                                   # console = capability, argv = data
WAIT(pid, &status)
```
This used to be six lines — open, lseek to the end, mmap, read, spawn, munmap —
because SPAWN took the bytes. Every one of them cost a full eager-committed copy
of the program in the caller, and no two processes running it shared anything.

**Run an image you built in memory** (a compiler that never wrote its output to
disk). A segment is a key, so this stays inside the model:
```
sfd = SEG_CREATE(npages, 0)                   # shareable RAM behind an fd
SEG_COPY(sfd, 0, img, len, 1)                 # 1 = write into the segment
sp  = { src_kind: SPAWN_SRC_FD, src_fd: sfd, argv: argv, argc: 1 }
pid = SPAWN(&sp)
CLOSE(sfd)                                    # the image was read at spawn
```

---

## 7. Where the detail lives

This file is the shape of the ABI. For the exact byte layout of a struct a call
fills — `PollEntry`, `ProcInfo`, `DevInfo`, `NetInfo`, `AudioInfo`, `Statx` —
read the comment at that number in `kernel/abi.cst`, which is what the handlers
are written against and therefore cannot drift from them.

## 8. The userspace side

All of it exists. The syscall wrappers live in the Caustic stdlib
(`std/os/causticos.cst`) — `spawn_path`, `spawn_fd`, `open_read`, `dev_open`,
`poll`, and the rest — and the keymap, the 8x8 font, the terminal and the shell
are ordinary programs under `userspace/`. This section used to be a to-do list
addressed to whoever was writing them.
