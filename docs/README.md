# causticos docs

High-level notes on how the system is put together. Start here, then read
the source — the code is the real reference.

- [INSTALL.md](INSTALL.md) — what to install and how, on Linux, WSL and Windows.
- [WRITING-APPS.md](WRITING-APPS.md) — writing a program: a terminal tool, a window, a network client, audio.
- [build-and-run.md](build-and-run.md) — every command and flag, the profile format, how the ISO boots with no disk, and the CSVI container spec.
- [overview.md](overview.md) — the layers, in order, and what each one does.
- [architecture.md](architecture.md) — the decided userspace model: keys/fds, the channel, surfaces, devices, input, terminal/shell, and *why* each call is shaped that way.
- [syscall-abi.md](syscall-abi.md) — the full userspace syscall contract: every call, args, errnos, struct layouts, usage patterns. What the toolchain's syscall lib and ring-3 programs build against.
- [executables.md](executables.md) — how a program gets built, loaded, and run.

For a quickstart, see the [README](../README.md); for the full build and boot
reference, [build-and-run.md](build-and-run.md). For the exact byte layout of the
executable format, see [CSE_FORMAT.md](CSE_FORMAT.md); for the syscall contract,
[syscall-abi.md](syscall-abi.md).
