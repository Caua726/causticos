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
bootstrap makes it falsifiable. `caustic-mk run bootstrap` (scripts/bootstrap.sh)
runs the compiler *on causticos* and has it rebuild its own source tree:

1. **The shipped compiler.** The `dev` profile ships `build/caustic.cse`, which
   `caustic-mk run build -- --profile dev` cross-builds on the host from
   `$CAUSTIC_DIR` (the `caustic-cse` target) — the same checkout the profile
   mirrors as `/src` and `/std`, so the compiler on the image and the stdlib
   beside it always come from one tree. Packing refuses a compiler older than
   its sources.
2. **Round k.** Boot causticos from a disk holding the round-(k-1) compiler as
   `/caustic.cse` (the shipped one for round 1) and the compiler's source
   (`/src`, `/std`, `/caustic-assembler`, `/caustic-linker`). The round driver
   (`/init`, `userspace/tests/bootstrap.cst`) runs
   `caustic /src/main.cst -o /out.cse` *inside the OS*, with the flags the host
   build used (read from `caustic-mk build caustic-cse --dry-run`, since
   `--app-version` stamps the binary), then powers the machine off — which is
   what writes `/out.cse` to the disk. The host lifts it off the image: that is
   round k's compiler.
3. **Compare.** Every round must be byte-identical to the shipped compiler.
   Round 1 shows causticos reproduces the binary it ships; rounds 2-4 that it
   keeps doing so from its own output, boot after boot.

So the host build is not trusted, it is checked: the day the cross-built
compiler and the one causticos makes of itself differ, the bootstrap fails and
names the first differing byte. A round's serial log (`build/bootstrap/`) has
the compiler's own output, how long the compile took, and the least free memory
it saw.

### Why the knobs are what they are

- **KVM when the host has it.** A round compiles the whole compiler in about
  half a minute under KVM, about ten times that under TCG (`--tcg` forces it).
- **256M.** The compile's low point is about 121 MB below the memory free when
  it started; 256M leaves it room. A 64M desktop compiles small programs but
  cannot rebuild the compiler.
- **`-smp 2`.** The compile is single-threaded; the driver needs a cpu of its
  own to copy the compiler's output to the serial line while it runs.
- **No `.s` beside the source.** A normal build no longer writes the generated
  assembly next to the source; `--emit-asm` asks for it when the code the
  compiler generated is what is being read.
- **A fresh disk each round**, built by `mkroot.py --profile dev --init
  bootstrap`, so no round can read what another left behind.

## Build and seed

Building and booting is [docs/build-and-run.md](build-and-run.md) — one command,
`caustic-mk run build`. What matters here is the compiler-facing half:

- **No `--stack-size`.** The compiler grows recursive programs' stacks on demand
  (dynamic-stack), and non-recursive ones get an exact computed stack.
- **The kernel is a staged target.** Its Caustic source compiles to one object,
  three hand-written `.s` sources assemble to three more, and `caustic-ld` links
  all four with `--strip`. The one-shot compile path links exactly one object and
  rejects linker-only flags, so this shape is what `asm` + `ldflags` in the
  `Causticfile` exist for.

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
resulting `.cse` runs. `caustic-mk run build -- --profile dev` builds the
standalone tools along with the compiler (the `caustic-as-cse` and
`caustic-ld-cse` targets), from the same `$CAUSTIC_DIR`.

Paths are absolute — causticos has no cwd. A program's "own path" is just the
argv[0] its spawner chose; the kernel never resolves it.

## Adding a userspace program

1. Write `userspace/<category>/<name>.cst`. The shape is tiny: `use` the `prog`
   and `sys` facades, `fn main(argc, argv)`, write to fd 1, read argv with
   `prog.arg`. File and text tools share `userspace/lib/futil.cst` (a buffered
   reader, a whole-file `slurp`, and small parse helpers).
2. Add a `target` block to `userspace/Causticfile` naming its `src` and `out`.
   That file is the build — `caustic-mk build all` compiles every target in it.
3. Add a `bin <name>` line to whichever `profiles/*.profile` should ship it.
4. `caustic-mk run run` — it builds first, so that is the whole step.

There is no third list to update. A `bin` naming something that is not a target
fails the build by name, and `caustic-mk run doctor` checks every profile against
the manifest before you get that far.

## Validating

`caustic-mk run verify` boots the shipped kernel on 1, 2 and 4 cpus through
four gates — the live ISO with no disk, a scratch disk with the FAT32 write
suite, the `smoke` command line, where every in-kernel smoke has to report
PASS and none may say FAIL, and the live ISO again under UEFI firmware — and
reports which markers were missing when one fails. `--runs N` repeats each configuration to hunt an intermittent. It works entirely
under `build/verify/`, so it is safe to run while a VM holds `build/disk.img`.

The strongest check for anything touching the toolchain is still the four-round
bootstrap above, `caustic-mk run bootstrap`: if every round is byte-identical to
the shipped compiler, the OS still builds itself.
