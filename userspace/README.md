# CausticOS userspace

The programs that run *on* CausticOS, written in Caustic. Which of them go on a
root image, and which one is `/init`, is decided by a profile in
`../profiles/`: `desktop` (the default) boots the compositor, `shell` boots the
full-screen shell, `dev` is the desktop plus the toolchain.

| directory | what is in it |
|---|---|
| `wm/` | the desktop: `compositor.cst` (the `/init` of the desktop profile — owns the framebuffer and the input devices), `wm.cst` (the window manager it starts: geometry, focus, decorations, taskbar, launcher), `wterm.cst` (the terminal), `launcher/` (the application launcher) |
| `shell/` | `shell.cst` — the shell. Full screen it is the `/init` of the `shell` profile; on the desktop it runs inside `wterm` |
| `editors/` | `vic` (a text editor), `hexedit`, `pager` |
| `coreutils/` | `ls`, `cat`, `cp`, `mv`, `rm`, `mkdir`, `head`, `tail`, `wc`, `grep`, `find`, `seq`, `sort`, … |
| `sysutils/` | `ps`, `htop`, `btop`, `free`, `date`, `timezone`, `keymap`, `ifconfig`, `ping`, `wget`, `nc`, `httpd`, `aplay`, `arecord`, … |
| `netd/` | the network daemon: TCP/IP, DHCP and DNS for every program, over a channel |
| `soundd/` | the sound daemon: mixes every client onto the sound card |
| `toolchain/` | `cc`, `make`, `run`, `objdump` — what the `dev` profile carries with the compiler |
| `tests/` | the ring-3 test programs `scripts/test-userspace.sh` boots |
| `lib/` | what they share: the shell's parser and job control, the network and sound protocols, HTTP, TLS 1.3 and X.509, keymaps, time zones, … |

`Causticfile` names every target; a profile lists target names, and the root
image builder (`scripts/mkroot.py`) refuses a name that is not a target there.

## Building

These import the Caustic stdlib facades (`std/causticos/*`,
`std/os/causticos.cst`) by their plain names. That stdlib is the compiler's —
entangled with its portable `io`/`os` facades — so it stays there, and the
compiler finds it beside its own binary, at `<dir of caustic>/../lib/caustic`.

They used to be written `../../Caustic/std/…`, climbing out of this repository
into a checkout of the compiler that had to be a sibling directory named
`Caustic`. Nothing said so, and a clone built nowhere else.

```sh
caustic-mk build all       # -> build/<name>.cse, every target in ./Causticfile
caustic-mk build wterm     # just one
```

Then boot it from the repository root: `caustic-mk run run` builds everything
and boots the desktop; `caustic-mk run run -- --profile shell` boots the
full-screen shell instead.
