# How programs run

The friendly version of what happens between "I wrote some Caustic" and
"it printed on screen." For the byte-exact format and the full syscall
contract, jump to [CSE_FORMAT.md](../CSE_FORMAT.md).

## The short story

You write a program in Caustic, build it for causticos, and you get a
`.cse` file. The kernel reads that file, drops the program into ring 3
(unprivileged mode), and lets it run. When the program needs the kernel —
to print something, to know the time, to exit — it makes a *syscall*.

```
hello.cst  ──caustic (target causticos-x86_64)──▶  .s
           ──caustic-as──▶  .o
           ──caustic-ld──▶  hello.cse
hello.cse  ──kernel (cse.cst)──▶  loaded at 0x400000, jumped to in ring 3
```

That last `.cse` is the *Caustic Standard Executable* — causticos' own
format. It's much simpler than ELF: a small header, a list of segments
(code, data), and that's it. No dynamic linking, no relocations; the
kernel maps the segments and jumps to the entry point.

## What a program can do today

A program reaches the kernel through a small set of syscalls. In plain
terms:

- ask for kernel info (version, page size, how many syscalls exist)
- read a monotonic clock, or sleep for a while
- get its own id, or yield the CPU
- write bytes to the console
- exit

That's the v0 ABI — seven calls. It's enough for a program that computes,
prints, and exits. What's *not* there yet: opening files, allocating more
memory (`mmap`), or starting other programs. Those arrive later, with the
capability layer.

## How a syscall actually travels

It's the standard x86_64 mechanism, nothing exotic:

- the program puts a number in `rax` (which call it wants) and arguments
  in `rdi`, `rsi`, `rdx`, ...
- it runs the `syscall` instruction; the CPU jumps into the kernel
- the kernel does the work and returns a value in `rax`; a negative value
  means an error

A program can trust that its registers and stack survive the call (the
kernel preserves the callee-saved registers, exactly like an ordinary
function call would). Getting that detail right is what lets a normal
compiled program — one that uses the stack across calls — run unmodified.

## ELF too

The kernel also loads plain ELF64 (`elf.cst`), the format everything else
uses. So causticos isn't locked to CSE — CSE is just the native, minimal
option, and ELF is there for compatibility with the wider toolchain world.
Both end up in the same place: mapped into a fresh address space and
entered in ring 3 with a System V stack (argc, argv, envp, auxv).

## Where to go deeper

- [CSE_FORMAT.md](../CSE_FORMAT.md) — the header, the segment table, the
  permission rules, and the syscall numbers, byte for byte. This is the
  contract the toolchain and the kernel both follow.
- `kernel/cse.cst` / `kernel/elf.cst` — the loaders.
- `kernel/syscall.cst` + `kernel/syscall_entry.s` — the syscall path,
  from the `syscall` instruction to the dispatch table.
