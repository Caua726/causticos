# causticos docs

High-level notes on how the system is put together. Start here, then read
the source — the code is the real reference.

- [overview.md](overview.md) — the layers, in order, and what each one does.
- [architecture.md](architecture.md) — the decided userspace model: keys/fds, the channel, surfaces, devices, input, terminal/shell, and *why* each call is shaped that way.
- [executables.md](executables.md) — how a program gets built, loaded, and run.

For building and running, see the [README](../README.md). For the exact
byte layout of the executable format and the syscall contract, see
[CSE_FORMAT.md](CSE_FORMAT.md).
