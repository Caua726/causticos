# The toolchain, and how the OS builds itself

causticos ships *with* its compiler. The Caustic toolchain — compiler,
assembler, linker — is itself written in Caustic, compiles to a CSE, and runs
as an ordinary ring-3 program on causticos. So the OS the toolchain targets is
also an OS the toolchain runs on: open a terminal, type
`caustic /src/main.cst -o /out.cse`, and you are compiling on the machine you
booted.

This doc is the *process*: what the pieces are, how the self-host bootstrap
proves them, and how you build, seed, run, and extend the userspace.

## The three binaries

- **`caustic`** — the compiler. It is the whole pipeline in one image:
  source → AST → IR → x86-64 assembly → object → linked CSE. The assembler and
  linker are *modules* it imports (`caustic-assembler/main.cst`,
  `caustic-linker/main.cst`), so a single process turns a `.cst` into a runnable
  `.cse` with no intermediate files and no subprocesses.
- **`caustic-as`** — the assembler, as a standalone binary. The same code the
  compiler links in, exposed as its own tool: assembly → object.
- **`caustic-ld`** — the linker, as a standalone binary: object(s) → CSE (or
  ELF/PE for other targets).

The split mirrors the Unix `cc` / `as` / `ld` shape: `caustic` does the whole
job by default, or you drive the stages yourself. The compiler is the source of
truth — `caustic-as` and `caustic-ld` are the same modules with a thin `main` —
so the one-shot path and the staged path agree by construction.

## Self-host: the bootstrap, four rounds

"It compiles itself" is easy to claim and easy to get subtly wrong. The
bootstrap makes it falsifiable. `run-bootstrap.sh` runs the compiler *on
causticos* and has it rebuild its own source tree:

1. **Seed.** The host cross-compiles `src/main.cst` to a `caustic.cse`
   (round 0). This is the only time the host compiler is trusted.
2. **Round k.** Boot causticos with the round-(k-1) compiler as `/caustic.cse`
   and the full compiler source mirrored on the FAT32 disk (`/src`, `/std`,
   `/caustic-assembler`, `/caustic-linker`). A tiny driver (`init.cse`,
   `userspace/bootstrap.cst`) runs `caustic /src/main.cst -o /out.cse` *inside
   the OS*. The host lifts `/out.cse` back off the disk image — that is round
   k's compiler.
3. **Converge.** Repeat for four rounds. If every round is byte-identical to the
   seed (same md5), the compiler running on causticos reproduces itself exactly.
   That is self-host.

The binary we keep — `build/caustic.cse` — is the one that came *out of the VM*,
not the host seed. The host only bootstraps trust; the shipped compiler is the
OS's own work. The same rule holds for the standalone tools: the honest way to
obtain `caustic-as.cse` / `caustic-ld.cse` is to compile them on causticos with
the converged compiler, not to trust a host cross-build.

### Why the knobs are what they are

- **TCG, not KVM.** causticos' timer/scheduler is reliable under TCG; under KVM
  the real-hardware timing can stall the scheduler under a sustained compute
  load. KVM boots (`BOOT_KVM=1`) but is not the validated path. TCG is ~10×
  slower — hence the long per-round bound.
- **`-smp 2`.** The compile is single-threaded, but the driver needs a CPU to
  reap the child and print heartbeats. On `-smp 1` a flat-out compute thread can
  starve it for minutes.
- **`--no-asm-cache`.** One fewer FAT32 write path to exercise per build; the
  on-disk asm cache buys nothing for a single compile.
- **Fresh disk + fresh snapshot each run.** A toolchain edit must never be
  measured against a stale snapshot — that trap silently builds the seed from
  old source. `REUSE=1` opts out when you know the source is unchanged.

## Build and seed

- **Kernel.** `scripts/run.sh` builds `build/causticos.iso` (Limine + kernel).
- **Userspace.** `userspace/build.sh` compiles every program in `PROGS` to
  `userspace/build/<name>.cse`. No `--stack-size`: the compiler grows recursive
  programs' stacks on demand (dynamic-stack), and non-recursive ones get an
  exact computed stack.
- **Disk.** `run-wm.sh` makes a FAT32 image, installs the window manager as
  `/init.cse`, adds the clients and tools, and — if a converged
  `build/caustic.cse` exists — the compiler plus its whole source tree, so the
  booted system comes with a working compiler. `HEADLESS=1` swaps the display
  for a QEMU monitor socket (screendump/sendkey automation).

## Running the toolchain on causticos

Boot into the window manager, open a terminal (Super+Enter), and:

```
caustic /src/hello.cst -o /hello.cse
/hello.cse
```

…or drive the stages by hand:

```
caustic -c /src/hello.cst                                   # → hello.cst.s
caustic-as /src/hello.cst.s                                 # → hello.cst.s.o
caustic-ld --target=caustic-x86_64 hello.cst.s.o -o /hello.cse
```

This staged path is proven on-device: `caustic-as` and `caustic-ld` run as
ring-3 programs, the object and the executable land on the FAT32 disk, and the
resulting `.cse` runs. Build the standalone tools with `scripts/build-tools.sh`
(the canonical build is on the VM, with the converged compiler — see above).

Paths are absolute — causticos has no cwd. A program's "own path" is just the
argv[0] its spawner chose; the kernel never resolves it.

## Adding a userspace program

1. Write `userspace/<name>.cst`. The shape is tiny: `use` the `prog` and `sys`
   facades, `fn main(argc, argv)`, write to fd 1, read argv with `prog.arg`.
   File and text tools share `userspace/futil.cst` (a buffered reader, a
   whole-file `slurp`, and small parse helpers).
2. Add `<name>` to `PROGS` in `userspace/build.sh`.
3. Seed it onto the disk (the loop in `run-wm.sh`).
4. Build and boot: `./run-wm.sh` (or `HEADLESS=1 ./run-wm.sh` for automation).

## Validating

`scripts/verify.sh` reuses the ISO, copies the disk, and boots `-smp 1/2/4 × 20`,
killing QEMU on a success marker — the whole sweep in ~a minute, the standing
gate for kernel changes. The strongest check for anything touching the toolchain
is the four-round bootstrap above: if it still converges byte-identically, the
OS still builds itself.
