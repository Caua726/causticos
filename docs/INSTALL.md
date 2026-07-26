# Installing what causticos needs

Two commands once the tools are here:

```sh
caustic-mk run doctor     # is everything installed?
caustic-mk run run        # build kernel + userspace + a bootable ISO, then boot it
```

`doctor` is the source of truth. It checks every tool, prints the resolved path
for each, and gives a fix for anything missing — so if this page ever disagrees
with it, believe `doctor`.

---

## What is actually needed

| Tool | Why |
|---|---|
| `caustic`, `caustic-as`, `caustic-ld`, `caustic-mk` | the toolchain: compiler, assembler, linker, build system |
| Limine | the bootloader that goes on the ISO |
| `xorriso` | assembles the ISO |
| `qemu-system-x86_64` | runs it |
| a QEMU display backend (GTK or SDL) | shows the window. **A separate package on Arch** — without it QEMU still boots, `--headless`, and refuses to open a window with an error that does not name the missing package |
| Python 3.8+ | the image tooling (`scripts/*.py`) |

Notably **not** needed: `mkfs.fat`, `qemu-img`, `mtools`, or root. The FAT32
volume is formatted by `scripts/fat32.py`, and nothing here mounts anything.

**Hardware virtualisation is optional.** Everything defaults to TCG emulation,
which reaches a ready desktop in about 3.4 seconds against 2.8 accelerated —
measured, not estimated. So no KVM, no Hyper-V, no nested virtualisation in a
VM, no `/dev/kvm` group membership: it just runs. Pass `--kvm` to use the host's
accelerator when it has one.

---

## Linux

```sh
# Arch
sudo pacman -S limine libisoburn qemu-system-x86 qemu-ui-gtk python

# Debian / Ubuntu
sudo apt install limine xorriso qemu-system-x86 qemu-system-gui python3

# Fedora
sudo dnf install limine xorriso qemu-system-x86 python3   # GTK is bundled here
```

Then the toolchain, from [the Caustic releases](https://github.com/Caua726/Caustic/releases):

```sh
curl -L -O https://github.com/Caua726/Caustic/releases/latest/download/caustic-x86_64-linux.tar.gz
tar xzf caustic-x86_64-linux.tar.gz
cd caustic-x86_64-linux && ./install.sh
```

The installer asks where to put things; `~/.local/bin` needs to be on your
`PATH`. Check with `caustic --version`.

If your distribution has no Limine package, the ISO only needs four files from
[its release tarball](https://github.com/limine-bootloader/limine/releases) —
point `LIMINE_DIR` at wherever you unpacked them:

```sh
export LIMINE_DIR=$HOME/limine
```

Then:

```sh
git clone https://github.com/Caua726/causticos && cd causticos
caustic-mk run doctor
caustic-mk run run
```

`run` builds the kernel, the userspace and the ISO before booting — about two
seconds — so that second command is the whole loop from here on. A window opens
with the desktop in it. Move the mouse, click, `Super+Enter`
opens a terminal.

---

## WSL (Windows Subsystem for Linux)

WSL2 runs the Linux instructions unchanged, and WSLg gives you the QEMU window
on your Windows desktop without any X server setup.

```powershell
wsl --install -d Ubuntu      # in PowerShell, once; reboot if it asks
```

Then, inside the WSL shell, follow **Linux** above. That is the whole
difference.

Two things worth knowing:

- **Keep the repository inside the WSL filesystem** (`~/causticos`), not under
  `/mnt/c/...`. Builds on the Windows drive go through a translation layer and
  are several times slower.
- **`/dev/kvm` may or may not exist** in WSL2 depending on whether nested
  virtualisation is on. It does not matter — TCG is the default. `doctor` will
  tell you which you have.

---

## Windows, natively

The build is driven by shell scripts, so Windows needs a POSIX shell. **Git Bash**
(bundled with [Git for Windows](https://git-scm.com/download/win)) is the smallest
way to get one; MSYS2 works the same way.

> Verified on Linux and expected to work here. The scripts detect Windows and
> adapt — Python is found as `python` or `python3`, the QEMU accelerator becomes
> WHPX instead of KVM when Hyper-V exposes it, and paths handed to QEMU are
> converted with `cygpath`. If something here does not work, it is a bug worth
> reporting rather than a limitation to work around.

1. **Git for Windows** — gives you Git Bash. Run everything below inside it.
2. **QEMU** from [qemu.weilnetz.de](https://qemu.weilnetz.de/w64/), and add its
   install directory to `PATH`.
3. **Python 3** from [python.org](https://www.python.org/downloads/windows/),
   with "Add python.exe to PATH" ticked. If it lands as `python` rather than
   `python3`, nothing needs changing — the scripts look for both. To force one:
   `export PY=python`.
4. **xorriso** — MSYS2: `pacman -S mingw-w64-x86_64-xorriso`. Git Bash alone has
   no package manager, so this is the one place MSYS2 is the easier route.
5. **Limine** — download the release tarball, unpack it, and point at it:
   `export LIMINE_DIR=/c/Users/you/limine`.
6. **The Caustic toolchain** — `caustic-x86_64-windows.zip` from the releases,
   unpacked, with `install.ps1` or the `bin` directory added to `PATH`.

Then the same two commands:

```sh
caustic-mk run doctor
caustic-mk run run
```

If `doctor` reports everything ok and `run` still fails, the likely culprit is a
path: QEMU on Windows is a native binary and wants `C:\...`, while the shell
hands it `/c/...`. `scripts/portable.sh` converts with `cygpath`; a path
containing spaces is the case most likely to still bite.

---

## Seeing the window

`caustic-mk run run` opens a QEMU window. What has to be true for that to work
depends on where you are:

| Where | What shows the window | If there is none |
|---|---|---|
| Linux desktop | your X11 or Wayland session, through QEMU's GTK backend | — |
| Linux over SSH | nothing | `--headless`: serial on your terminal |
| WSL2, recent Windows | **WSLg**, already there — the window appears on the Windows desktop | `--headless` |
| WSL2, older Windows | an X server on Windows (VcXsrv, X410) and `export DISPLAY=...` | `--headless` |
| Windows, Git Bash | QEMU is a native Windows binary and opens its own window | — |

`caustic-mk run doctor` checks both halves and says which you have:

```
ok    qemu display           gtk sdl
ok    display server         wayland (wayland-1), X11 (:0)
```

A `warn` on either line means the boot will work and the window will not — use
`--headless` until it is fixed.

**Or skip QEMU's window entirely.** On a Wayland desktop the GTK backend is the
part most likely to disappoint, and libvirt's SPICE console is not:

```sh
sudo pacman -S libvirt virt-viewer          # Arch; apt/dnf spell it the same
systemctl --user start virtqemud.socket
caustic-mk run libvirt
```

Same machine, same devices, defined as a domain on `qemu:///session` — as your
own user, no root. The window it opens is virt-viewer's, the mouse needs no grab,
and the VM keeps running when you close the terminal. Details and flags in
[build-and-run.md](build-and-run.md#libvirt).

**Headless is not a lesser mode.** The serial console carries the whole boot
log, and everything the regression suite checks it reads from there:

```sh
caustic-mk run run -- --headless
```

**Mouse and keyboard.** The guest has an absolute pointer (virtio-tablet), so
the host cursor tracks without QEMU grabbing it. There is also a relative PS/2
mouse; that one does need a grab, and native Wayland refuses QEMU's classic
grab — so `run` routes GTK through XWayland when it sees `WAYLAND_DISPLAY`.
Click inside the window to capture, `Ctrl+Alt+G` to release.

Once the desktop is up: `Super+Enter` opens a terminal, `Alt+Tab` cycles
windows, `Super+Q` closes one.

## Real hardware

The ISO is a hybrid image: the same file boots from a USB stick under BIOS and
under UEFI, and it carries its own root, so nothing else needs to be installed.

```sh
caustic-mk run usb -- /dev/sdX
```

It refuses a device that is not removable, refuses one with mounted partitions,
and asks before writing. On Windows, use [Rufus](https://rufus.ie) in DD mode
with `build/causticos.iso`.

---

## When something is wrong

Run `caustic-mk run doctor` first — it names the missing thing and how to get
it. Beyond that, [build-and-run.md](build-and-run.md) has a troubleshooting
section for the failures the boot itself can print.
