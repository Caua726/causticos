# causticos — Architecture

How causticos is put together, and *why*. This is the design record for the
userspace model: processes, IPC, devices, display, input, and the terminal/shell —
plus the principles that decide each call.

> Status note: some of this is **built and verified** (processes, the polymorphic fd
> object, the syscall ABI, storage/VFS). The rest (channel, surface, device
> acquisition, terminal, shell) is **designed here, not yet built** — see
> [Status](#11-status-built-vs-designed). This
> document is the decided design, written down so it isn't re-litigated.

---

## 1. Identity: everything is a key

A causticos program interacts with the world through **file descriptors (fds)**. An
fd is a small per-process integer that names a kernel object the process holds. We
call it a **key**: holding the key lets you *use* the thing.

> **Tudo é uma chave.** Files, IPC channels, the screen, devices, child processes —
> each is an object you hold an fd to.

Three things this is, and is not:

- **fd = monopoly of *mechanism*, not of *interface*.** Everything is *named/held*
  uniformly (an fd: held, passed, closed the same way). But there is **no `ioctl`**
  and no pretend "everything is a byte stream." Each object *kind* has its own
  honest, closed set of operations (a surface has `mmap`+`present`; a channel has
  `read`/`write`; a file has `read`/`write`/`seek`). A file and a channel *do* share
  `read`/`write` — because both genuinely *are* byte sequences; that is honest, not a
  forced interface.
- **Not a capability system.** The fd is a plain integer index, not a CSpace entry.
  No rights masks, no generations, no capability-monopoly bootstrap. It is
  *capability-like in spirit* (you can only act through keys you hold) but **int-fd
  in mechanism** — deliberately simpler than seL4/Fuchsia.
- **The identity is a property inherited from the language.** Caustic the language
  has "no magic, no implicit — every operation is visible." causticos is that applied
  to *authority*: the OS hides no power the way the language hides no behaviour. The
  identity is the *property* (explicitness), not a noun ("everything is a file/object").

---

## 2. Principles

1. **Kernel = mechanism. Userspace = policy.** The kernel provides objects, `spawn`,
   the fd table, and the dispatch of raw events. *Anything with a decision in it* —
   the terminal, the shell, the keymap, compositing, line editing, job control — is a
   userspace program. The kernel has no concept of "shell", "terminal", or "tty".
2. **Explicit acquisition; no ambient global namespace.** You obtain a key by either
   (a) **asking the kernel** — `dev_open` a device by class, `open` a file, create a
   channel — or (b) **being handed one** at spawn or over a channel. There is **no
   global path you implicitly resolve against**: no ambient cwd, no `/dev` tree, no
   ambient root. Names, if they ever exist, resolve through a namespace you were
   *granted*, never a global one.
3. **Open, not sandboxed.** causticos is **not** a capability-lockdown OS. Any program
   may *ask* for any resource. The real constraint on hardware is **physical
   exclusivity, not permission**: a physical device has one owner at a time. **User >
   OS** — the kernel does not forbid a program from acquiring hardware.
4. **No fork** (spawn instead). **No signals-as-magic** (events as readable fds).
   **No `ioctl`.** **No tty in the kernel.**

---

## 3. Object kinds (what a key opens)

| kind | what it is | honest ops |
|---|---|---|
| **file** | bytes on a filesystem (FAT32 via VFS) | open/read/write/seek/close |
| **channel** | bidirectional byte stream between two endpoints — the founding IPC primitive | read/write/close |
| **surface** | a 2D pixel buffer mapped into the holder | mmap + present(damage) |
| **device** | a raw hardware resource acquired by class (exclusive, preemptible) | per-device; raw |
| **process** | a handle to a spawned child | spawn/wait/(kill) |

A **console is not an object kind — it is a channel.** Keyboard/mouse are **devices**
yielding raw event streams. The set stays small on purpose: one new concept, the
*channel*, absorbs console + pipe + tty + IPC.

---

## 4. Processes  *(built)*

- **Process ≠ Thread.** A *Process* is the isolation/identity unit: an address space
  (`*vma.Aspace`, which holds the memory map **and** the fd table = its authority) +
  pid + lineage (parent/children) + state/exit_code + one or more threads. A *Thread*
  is the scheduler/execution unit and points back to its Process (`process_ptr`).
  `pid != tid`.
- **Creation = create-suspended → configure → start. No fork.** `spawn(image)` makes a
  fresh aspace, loads a fresh image, and creates a suspended main thread. The child's
  fd table starts **empty** — authority is never ambient; the parent installs keys
  explicitly. There is no COW address-space duplication.
- **wait + deferred reaper.** A dying thread can't free its own kernel stack (it is
  running on it). It is queued in `schedule()` *before* the context switch and freed
  by a per-cpu reaper in `idle` *after* the switch — race-free. `wait` then frees the
  address space + Process struct. Verified leak-free on smp 1/2/4.
- **fd lifecycle (contract).** Each fd-table slot holds **one reference** to its
  KObject. `close` — and process exit, when the address space is torn down — drops the
  reference; the object's `close` op runs at the last reference. Clearing a slot
  *anywhere* must `ko_unref`.
- Syscalls: `SYS_SPAWN`, `SYS_WAIT`, `SYS_PROC_KILL` (forced, cross-cpu — marks the
  thread and parks it at its next preemption, the 1 ms tick bounding a pure-user spin;
  it kills every thread of a multi-thread process). `SYS_THREAD_SPAWN`/`SYS_THREAD_EXIT`
  add threads over a shared aspace; `SYS_EVENT_SUBSCRIBE` delivers child-exit events.

---

## 5. IPC: the channel  *(built)*

The channel is the **founding IPC primitive** — get it right and console, pipes,
shell↔terminal, and all future IPC fall out of it.

- **Transports a byte *stream*, data only.** Two endpoints, each an fd; `read`/`write`/
  `close`. Message framing (record boundaries) is **userspace** policy (length-prefix
  on the stream) — not baked into the kernel primitive. (Stream-in-the-kernel,
  framing-in-the-app is the Unix/TCP school, the opposite of Fuchsia's
  message+handle primitive.)
- **A console is a channel** whose far end is held by a renderer (the terminal). The
  program writes characters / reads keys; the terminal renders / feeds.
- **Endpoint handoff is the founding transfer.** A channel endpoint is *meant to be
  passed*: a child gets its stdin/stdout by **receiving channel endpoints at spawn**.
  A process can mint a channel (both ends) and hand one end to a child — that is how
  pipes (`a | b`) and shells relaying their children's I/O work, with no runtime
  handle-passing:
  - terminal mints a pair, keeps one end (renders), hands the other to the shell at
    spawn → the shell has a console.
  - shell runs `ls`: mints a pair, hands one end to `ls` at spawn, keeps the other and
    relays to the terminal.
  - `a | b`: shell mints a pair, hands the write end to `a` and the read end to `b`.
  All bytes, zero runtime handle-passing.
- **Handle-passing over a channel** (delegating an arbitrary key through an open
  channel) is a *future, honest extension* of the same object — a "send key" op the
  kernel mediates — added when a broker/service-discovery workload forces it. It is
  **not** part of the founding core, by the no-speculative rule.

---

## 6. Devices & acquisition  *(acquisition + preemptible grab stack built; enumerate via SYS_QUERY_DEVS)*

- **`dev_open(class, index) → fd`** — e.g. `dev_open(DEV_KEYBOARD, 0)`,
  `dev_open(DEV_FB, 0)`. You ask the kernel for a device *by class*; it returns a key.
  The **`index` is real**: it selects the index-th registered instance of the class,
  and `dev_open(DEV_KEYBOARD, 1)` with a single keyboard is `E_NOENT` — never a silent
  alias of instance 0. **`dev_count(class)`** enumerates (how many before you index).
- **The class is a fact the driver declares, not a kernel value judgement.** A driver
  announces its class in its `.cdvrspec` `device { class: <name>; acquire: <fn> }`
  block; the framework registers the instance (with its Hardware node as the
  discriminator) after a successful bind. The kernel doesn't "know what a keyboard is" —
  `dev_open` is a query over the instances drivers declared. A boot-provided pseudo-
  device (the Limine framebuffer) registers the same way at init. New device = one more
  declaration, no syscall-layer edit.
- **Not a `/dev` path** (that is a Unix reflex — an ambient global namespace). **Not
  capability-monopoly** (no "only the root/compositor may acquire"). **Any program may
  `dev_open` any device.**
- **Exclusive ownership, but preemptible.** One holder per physical device at a time
  (you cannot have two owners of the scanout, nor two readers of the raw key stream).
  A `dev_open` may **grab** the device from the current holder, forming a **stack**;
  on `close`/release ownership returns to the previous holder. The displaced holder is
  **notified** — its device-fd goes quiet/inactive until it regains ownership. The
  kernel only maintains the grab stack; *who grabs from whom* and the escape hatch to
  break a stuck grab are **userspace policy**. *Stealing* a device is rudeness
  (convention), not a kernel prohibition — **user > OS**.
- **Handoff coexists.** A windowed app does *not* `dev_open` the keyboard; it
  **receives** a derived input channel + a surface from the compositor at spawn. A
  fullscreen app `dev_open`s the hardware directly. Both are first-class; the kernel
  forces neither.

---

## 7. Display & surfaces  *(designed)*

- **A surface is a backbuffer + present.** Physically: kernel-allocated pages mapped
  into the holder's address space (the surface-fd's `mmap` region) + a
  `present(damage_rect)` op that publishes the dirty rectangle to the scanout.
- **One owner of the scanout.** Backbuffer+present (not direct scanout) is chosen
  because it **generalises to N surfaces composited without a refactor** — the surface
  object is identical whether there is one fullscreen app or a compositor; only the
  *target* of `present` changes (real framebuffer → compositor). Direct scanout would
  work for a single surface and then break when a second owner appears (the classic
  fbcon-vs-DRM ownership war) — i.e. it would force the refactor we refuse.
- **The compositor is just a program.** A userspace process that holds the framebuffer
  surface and composites client surfaces. It is **optional** — a fullscreen app holds
  the framebuffer surface directly. The kernel does not privilege any "compositor".

---

## 8. Input  *(keyboard + mouse devices built; compositor relays focus + pointer; wterm forwards xterm mouse tracking)*

- **Keyboard = a device yielding RAW events.** `dev_open(DEV_KEYBOARD)` → an fd whose
  reads return raw event records (scancode, key down/up, modifier snapshot). Lossless;
  **the kernel applies no keymap.**
- **Keymap + cooking = userspace.** Layout (ABNT2/US/dvorak), what "Ctrl+C" means,
  dead keys, compose, future IME — all *policy*, all changeable, all in the terminal
  (or the app). Collapsing to ASCII in the kernel would be lossy (no key-up, no
  modifiers, no arrows/F-keys) *and* would put policy in the kernel — the
  historically-criticised legacy-VT mistake. Rejected.
- **Why one owner.** The framebuffer scanout is physically one (physical law). For
  input the physical event stream is one, and *someone* must decide who receives each
  event; multiplexing input (routing by focus, deciding who consumes a click) is
  **policy** → the kernel does the minimum: it hands the raw stream to **one** holder;
  whoever wants fan-out writes the multiplexer in userspace (the compositor).
  Single-consumer also avoids "every program sees every keystroke" (ambient keylogger).
- **Focus routing falls out of the channel model.** The holder of the keyboard (the
  compositor) reads raw events and **relays** them to the focused client's channel.
  "Who gets input" = "whom the holder forwards to" = a userspace decision. The kernel
  has no notion of focus. Mouse is the same shape (DEV_MOUSE / DEV_TABLET): the
  compositor reads raw deltas, applies the accel curve (accel.cst, a smoothstep
  gain tunable via /var/wm/pointer.cst), and relays button/wheel to the focused
  client. The wterm turns those into xterm mouse reports (SGR/X10) on the child's
  stdin when a TUI enabled tracking — mouse-in-terminal with no kernel change.
- **A fullscreen app may `dev_open` the keyboard/mouse itself** and read raw — no
  compositor required. A game wanting raw mouse *is* the owner: exclusivity hands it
  the raw stream, it does not exclude it. Either fullscreen (`dev_open(DEV_MOUSE)`) or,
  inside a compositor, by requesting a grab.

---

## 9. Terminal & shell  *(launch built; the programs are userspace, to come)* — not intrinsic

The kernel knows **nothing** about a shell, a terminal, or a tty. Both are ordinary
userspace programs.

- **The terminal** is a userspace process that holds the framebuffer surface + the
  keyboard device, renders text (cursor, scroll, colours — all its own policy),
  applies the keymap, and **serves console channels** to clients.
- **The shell** is a userspace program. It holds a **console channel** (received at
  spawn), reads keys / writes characters, and runs programs the explicit way:
  `open()` the program's `.cse` → `read` it into an `mmap`'d buffer → `spawn(buf)` →
  `wait`. It passes a console channel to each child it runs (that is how the child's
  stdio "inherits"). No special `spawn-by-path` syscall — the shell reads the file and
  passes the image.
- **Launch *(built)*.** The boot path loads `/init.cse` from the FAT32 disk
  (`vfs.open → read → proc_spawn → proc_start`, behind a bounded mount-wait, failing
  loud — never a silent hang) and runs it in ring 3. `init` is an ordinary file on the
  disk, not embedded: drop the terminal in as `/init.cse` and it launches, no kernel
  change. The terminal then `dev_open`s the surface + keyboard and spawns the shell with
  a console channel. A fullscreen app may run with no terminal at all.

  `/init.cse` is the compositor today, loaded from the root volume like any other
  file. The root itself is a block device the kernel builds from a bootloader
  module when one is present (mechanism); *which* programs are on it is a build
  profile (policy). Nothing about "init" is special-cased in the kernel.

Contrast with Unix: the Unix TTY subsystem (line discipline, termios, sessions, job
control, the controlling terminal) is a large *intrinsic kernel* thing. causticos
keeps **one** new concept (the channel) in the kernel and puts every terminal decision
in a swappable userspace program.

---

## 10. Lineage — why these choices

- **Plan 9 / modern-userspace school (causticos sides here):** byte streams, raw input
  with userspace keymap, backbuffer+present, console-is-a-stream, policy outside the
  kernel.
- **Rejected — legacy intrinsic (Unix VT/tty, kernel keymap, direct scanout):** bakes
  policy into the kernel; the criticised parts of Linux's console history.
- **Rejected — full capability (seL4/Fuchsia: CSpace, message+handle IPC primitive,
  no-ambient lockdown, capability-monopoly bootstrap):** too heavy and too closed.
  causticos is int-fd with *open* acquisition, not a sandbox-first capability OS.
- **The causticos twist:** the fd is *simultaneously* a file/channel/surface/device/
  process handle — one held mechanism, honest per-type ops, no `ioctl`. You acquire by
  asking the kernel or by handoff; the only hardware constraint is exclusivity
  (preemptible), not permission.

---

## 11. Status: built vs designed

**Built and verified (smp 1/2/4):**
- Boot (Limine, long mode, higher-half), SMP, memory (PMM buddy / slab heap / 4-level
  paging / per-aspace VMAs + fd table), scheduler with deferred reaper, time
  (PIT/LAPIC/HPET via ACPI), driver framework (`.cdvrspec` over PCI), AHCI + FAT32 +
  VFS, e1000 NIC.
- Ring-3 userspace + syscall ABI, CSE + ELF loaders.
- **Process model**: Process ≠ Thread, `spawn` (create-suspended, no fork), `wait`,
  deferred race-free reaper.
- **Polymorphic fd (`KObject`)**: every fd backs a `{type, refcount, ops, priv}` with a
  struct-of-fn-ptrs vtable; `VfsFile` is the `priv` of a `KOBJ_FILE`; a null op is an
  honest errno, never an `ioctl`. File read/write/close/lseek/readdir dispatch through
  it. Close-on-exit drains the fd table on aspace teardown (coe_smoke green). (Atomic
  refcount deferred to the channel work, when two fd tables first share a KObject.)
- **Surface** (`KOBJ_SURFACE`): the display key. `dev_open(DEV_FB)` mints a surface over
  the framebuffer; `SYS_MMAP|MMAP_FD` maps its kernel-allocated backbuffer into the
  holder (a `VMA_FILE` the surface owns — teardown unmaps without freeing, close frees);
  `SYS_PRESENT` blits the damage rect to the scanout. The scanout is mapped
  write-combining (PAT PA1 → WC, per-cpu); `fb.cst` reads the real bpp from Limine.
  `SYS_SURFACE_INFO` copies the surface's `{width, height, pitch, bpp_bytes, format}` so
  the holder can index the padded backbuffer. Proven ring-3 → screen: the fb smoke
  surface_info's the surface (and gates its draw on it), then does dev_open/mmap/present
  from a ring-3 CSE and the kernel confirms the pixels (smp 1/2/4). v0 backbuffer is one
  contiguous ≤4 MiB block (full-screen / non-contiguous is a refinement).
- **Device model** (the registry behind `dev_open`): one entry per device *instance*, not
  per class. `device_register(class, acquire, ctx)` appends; `dev_open(class, index)`
  resolves the index-th instance (index is **honest** — out-of-range is `E_NOENT`, not an
  alias); `dev_count(class)` enumerates. Drivers declare their class in the `.cdvrspec`
  `device { class; acquire }` block and the framework auto-registers after bind — no glue,
  no kernel-side switch. Proven: `devreg_smoke` (count + honest index, smp 1/2/4).
- **Channel** (`KOBJ_CHANNEL`): the founding IPC primitive — two endpoints over a pair of
  byte ring buffers; read/write are honest ops (dispatch via ko_read/ko_write, so
  SYS_READ/SYS_WRITE drive a channel fd), no framing/handle-passing in the kernel.
  `SYS_CHANNEL_CREATE` mints a pair. Blocking is by polling (a wakeup_thread fast-path is
  a refinement). The KObject **refcount is atomic** (lock xadd) so two aspaces can share
  an endpoint. **Endpoint handoff at spawn is live**: `SYS_SPAWN`'s `fdacts` installs the
  parent's KObjects into the still-suspended child. Proven: a ring-3 child receives a
  channel endpoint as its fd, blocks on read, wakes on the byte (smp 1/2/4).
- **Keyboard device** (`KOBJ_DEVICE`): `dev_open(DEV_KEYBOARD)` → an fd whose read drains
  a ring of **raw 2-byte events** (scancode + down/up + 0xE0-extended). The PS/2 handler
  decodes only the device protocol, **no keymap** — layout/meaning are userspace. Proven
  ring-3: a child dev_opens the keyboard, blocks on read, the kernel injects an event,
  the child exits with the scancode (smp 1/2/4). v0 has no exclusivity (grab stack later).
- Syscall ABI (flat-numbered, `SYS_COUNT = 27`): `kern_info`, `time_now`/`sleep`,
  `proc exit`/`getpid`/`yield`, `io_write_serial`, `mmap`/`munmap`,
  `open`/`read`/`write`/`close`/`lseek`, `spawn`/`wait`,
  `unlink`/`mkdir`/`rmdir`/`rename`/`stat`/`readdir`, `dev_open`/`dev_count`/`present`/
  `surface_info`, `channel_create`.
- **Boot → userspace handoff**: the boot path loads `/init.cse` from the FAT32 disk and
  runs it in ring 3 (bounded mount-wait, loud failure, no silent hang). Proven by a stub
  that writes a ring-3 serial marker. **This is the last kernel mechanism before the
  terminal — the kernel side of the userspace model is now complete.**

**Built since:**
- **Preemptible device ownership** (grab stack) — keyboard, mouse, and the framebuffer
  surface all ride `kernel/sys/grab.cst`; a non-top holder goes quiet, ownership returns
  on close.
- The **terminal** (wterm), the **shell**, and the **compositor** + window manager.
- `SYS_PROC_KILL` (forced, cross-cpu); file-fd handoff at spawn (fdacts); `thread_spawn`
  (multi-thread process, `SYS_THREAD_SPAWN`/`SYS_THREAD_EXIT`); signal-replacement event
  fds (`SYS_EVENT_SUBSCRIBE`); device enumeration (`SYS_QUERY_DEVS`).

**Designed here, not yet built:**
- **Userspace keymap + focus relay** (the kernel side — raw keyboard as a device — is
  built; full layout/cooking/routing policy still lands in the terminal).
- Rich granted namespaces; handle-passing over a channel (SCM_RIGHTS-style, beyond the
  current one-slot `SYS_FD_SEND`/`SYS_FD_RECV`).

---

*This document records decided design. When a piece is built, move it from §11
"designed" to "built" and keep the rest as the contract.*
