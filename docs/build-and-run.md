# Building and running causticos

Everything goes through `caustic-mk` and the `Causticfile` in the repository
root. There is no separate build script to learn: the manifest declares the
targets and the commands, and `caustic-mk run <name>` runs them.

```sh
caustic-mk run doctor     # is everything this needs installed?
caustic-mk run run        # build kernel + userspace + live ISO, then boot it
caustic-mk run build      # just the build, no boot
```

Arguments after `--` reach the command as its own:

```sh
caustic-mk run run -- --headless --smp 4
caustic-mk run run -- --profile shell
```

**`run` and `libvirt` build before they boot.** Everything downstream of an
edited source file is stale by definition, and a boot that silently shows the
previous build is the most expensive kind of wrong answer — you end up debugging
the symptom of a fix you did not actually run. The build is incremental and costs
about two seconds when nothing changed. `--no-build` boots what is already there,
and `--iso PATH` implies it. `scripts/rebuild.sh` is the one definition both
share.

## Requirements

| Tool | Why | If it is missing |
|---|---|---|
| `caustic`, `caustic-as`, `caustic-ld` | compiler, assembler, linker | install the Caustic toolchain, or add `~/.local/bin` to `PATH` |
| `caustic-mk` | reads the `Causticfile` | `cd ../Caustic && ./caustic-mk build caustic-mk`, then put it on `PATH` |
| `$CAUSTIC_DIR` | the userspace links against its `std/` | defaults to `../Caustic`; set it if yours is elsewhere |
| Limine under `$LIMINE_DIR` | the bootloader | `pacman -S limine`, or set `LIMINE_DIR` |
| `xorriso` | builds the ISO | `pacman -S libisoburn` |
| `qemu-system-x86_64` | runs it | `pacman -S qemu-system-x86` |
| `python3` ≥ 3.8 | the image tooling | — |

`/dev/kvm` is optional. Without it everything still runs under TCG, roughly ten
times slower, and the tools say which one they used rather than leaving you to
infer it from the boot time.

`libvirt` and `virt-viewer` are optional too, and only `caustic-mk run libvirt`
wants them — worth having on a Wayland desktop, where QEMU's own window does not
open and the SPICE console does.

Notably **not** required: `mkfs.fat` and `qemu-img`. `scripts/fat32.py` formats
its own volumes, which is the only way to guarantee the geometry satisfies every
check the kernel makes on mount.

## Commands

### `build`

Kernel, then userspace, then the ISO.

| Flag | Meaning |
|---|---|
| `--profile <name>` | which programs go in the root image (default `desktop`) |
| `--no-live` | build the ISO **without** the root module; it will need a disk to boot |
| `--cmdline "..."` | bake a kernel command line into the ISO |
| `--out PATH` | write the ISO somewhere other than `build/causticos.iso` |

### `run`

Builds kernel, userspace and ISO, then boots it.

| Flag | Meaning |
|---|---|
| `--no-build` | skip the build; boot the ISO that is already there |
| `--profile NAME` | which programs the root image ships (default `desktop`) |
| `--cmdline "..."` | bake a kernel command line into the ISO |
| `--headless` | no window; serial on stdout |
| `--kvm` / `--no-kvm` | override the automatic choice |
| `-m SIZE`, `--smp N` | memory (default `64M`, `128M` with `--uefi`) and cpu count (default 2) |
| `--uefi` | boot through UEFI firmware (OVMF, found by `scripts/ovmf.py`) instead of the BIOS |
| `--persist[=PATH]` | attach a FAT32 disk and boot from **it** instead of the live root; created from the current profile if absent |
| `--iso PATH` | boot a different ISO; implies `--no-build` |
| `--monitor` | headless, with the QEMU monitor on `/tmp/cos-mon` and QMP on `/tmp/cos-qmp` |

The kernel command line does **not** go on a QEMU argument. `-append` only
reaches a kernel loaded with `-kernel`, and this one is loaded by Limine off the
ISO — so it is baked into the ISO at build time, which is what `--cmdline` does.
Passing `-append` with a bootloader in the picture silently does nothing.

UEFI needs 128 MB where the BIOS needs 64, and the difference is the loader's:
Limine sets 64 MiB aside for the firmware before it loads anything, and OVMF is
holding some 45 MB of its own at that point, so below about 120 MB the boot
stops in Limine with `High memory allocator: Out of memory`. None of it is lost
once the kernel runs — it takes the firmware's boot-time memory back — so the
128 MB UEFI machine ends up with more free memory than the 64 MB BIOS one.

### `libvirt`

The same build and the same machine, hosted by libvirtd instead of a bare QEMU
process — a domain you drive from virt-manager, `virsh`, or the viewer this opens
for you.

```sh
caustic-mk run libvirt                    # build, define, start, open the viewer
caustic-mk run libvirt -- --console       # serial on this terminal instead
caustic-mk run libvirt -- --persist       # with a disk on SATA port 0
caustic-mk run libvirt -- --stop          # destroy the running domain
```

Two things it buys over `run`, and they are the whole reason it exists:

- **SPICE.** QEMU's own GTK window does not open under native Wayland; the
  virt-viewer console does, and the guest's absolute pointer (virtio-tablet)
  needs no grab there — so the window manager is usable with a mouse.
- **A VM that outlives the shell.** Close the terminal and the guest keeps
  running. Reattach with virt-manager whenever.

| Flag | Meaning |
|---|---|
| `--no-build` | skip the build; boot the ISO that is already there |
| `--profile NAME` | which programs the root image ships (default `desktop`) |
| `--cmdline "..."` | bake a kernel command line into the ISO |
| `--persist[=PATH]` | attach a FAT32 disk on SATA port 0 (default `build/disk.img`, created from the current profile if absent) |
| `--reseed` | rebuild that disk from the current profile even if it exists |
| `-m SIZE`, `--smp N` | memory (default `64M`) and cpu count (default 2) |
| `--kvm` / `--no-kvm` | domain type `kvm` instead of `qemu`/TCG |
| `--iso PATH` | boot a different ISO; implies `--no-build` |
| `--name NAME` | domain name (default `causticos`) |
| `--console` | serial on this terminal (`virsh console`) instead of a window |
| `--no-viewer` | start it and return; attach later |
| `--define-only` | build and define the domain, do not start it |
| `--stop` | destroy the running domain and exit (builds nothing) |

The order is load-bearing: **build, stop, define, start.** Build first because a
failed build must leave the VM you are looking at alone rather than killing it
for nothing. Stop before touching `build/disk.img`, because a running domain
holds a write lock on it and `--reseed` underneath one would either fail or hand
the guest a volume that changed while it was mounted.

The connection is `qemu:///session`, not `qemu:///system`: the session daemon
runs as you and reads `build/` with no permission or AppArmor argument, and needs
no root. Override with `LIBVIRT_DEFAULT_URI`. If it cannot connect, the fix is
almost always `systemctl --user start virtqemud.socket`.

**The domain is redefined on every invocation, and a running one is stopped
first.** A running domain pins the ISO *file* it was started with, so a fresh
build alone would not reach it — the boot would cheerfully show you the previous
one. It also means anything you change by hand in virt-manager is overwritten the
next time you run it: change `causticos.libvirt.xml` instead.

`causticos.libvirt.xml` in the repository root is a **template**, not a domain
you can define by hand: the script substitutes the paths, memory, cpu count and
accelerator into it and writes `build/causticos.libvirt.xml`, which is what
libvirt actually gets. Absolute paths are the reason — libvirt resolves nothing
relative to a working directory, so a checked-in XML with a `$HOME` baked into it
boots on exactly one machine.

Its device set mirrors `scripts/qemu-args.sh` down to the MAC addresses: the same
e1000 and virtio-net, virtio-tablet, virtio-sound, PS/2 keyboard, stdvga, q35.

The two independent SLIRP backends use non-overlapping IPv4 subnets in both
launch paths:

| NIC | Driver | Subnet | DHCP lease | Gateway |
|---|---|---|---|---|
| 0 | e1000 | 10.0.2.0/24 | 10.0.2.15 | 10.0.2.2 |
| 1 | virtio-net | 10.0.3.0/24 | 10.0.3.15 | 10.0.3.2 |

The guest learns these addresses and routes through DHCP; they are not driver
defaults. The boot smoke's ARP probes target the gateway on each fixture's link.

When you add a device to one, add it to the other — a driver that enumerates
under `run` and is missing under virt-manager is a bug found at the worst
possible moment. The one deliberate difference: `qemu-args.sh`'s `hostfwd` for
`httpd` has no libvirt equivalent on the SLIRP backend, so a test that dials
*into* the guest belongs under `run`.

### `verify`

Four gates, all against the same kernel binary the ISO ships.

| Gate | What it boots | What it proves |
|---|---|---|
| `live` | the ISO alone, no disk on the bus | the root travels inside the image |
| `persist` | a scratch disk, `--no-live` ISO, `selftest` command line | the AHCI driver and the FAT32 write path work |
| `smoke` | the ISO with the `smoke` command line | the in-kernel gauntlet: memory, devices, the VFS, ring 3 |
| `uefi` | the live ISO through OVMF, at 128M | the UEFI loader path, and the firmware's memory taken back |

Every gate also requires the kernel to have taken the bootloader's memory back,
which it does only once every cpu has left the stack it booted on. The `uefi`
gate needs UEFI firmware on the host; without it the gate is skipped, and the
sweep says so.

```sh
caustic-mk run verify                              # 1,2,4 cpus x 1 boot x 4 gates
caustic-mk run verify -- --smp 2 --runs 5          # hunting an intermittent
caustic-mk run verify -- --live-only --keep-logs
caustic-mk run verify -- --uefi-only
```

Everything it touches lives under `build/verify/` and is created per run, so it
is safe to run while a VM holds `build/disk.img` open. A failure names the
markers that were missing and keeps the serial log.

### `profiles`, `root`, `clean`, `distclean`, `usb`

```sh
caustic-mk run profiles                 # resolve a profile and print what ships
caustic-mk run profiles -- --profile dev
caustic-mk run root                     # just the volume: build/rootfs.{img,csvi}
caustic-mk run clean                    # build artifacts
caustic-mk run distclean                # also generated .cst.s / .s.o
caustic-mk run usb -- /dev/sdX          # write the ISO to a stick (asks first)
```

## Profiles: what ships

Two declarations, no overlap:

- **`userspace/Causticfile`** — what *can* be built. Every program with its
  source path, 75 of them. This is the only place a program's source is written
  down.
- **`profiles/<name>.profile`** — what *ships*. Which of those programs go in an
  image, plus the config files and directories around them.

| Profile | Contents |
|---|---|
| `base` | the ~55 tools, and nothing that decides what `/init` is |
| `desktop` *(default)* | `base` + compositor as `/init`, window manager, terminal, launcher, `/etc/wm.cst` |
| `shell` | `base` + the shell as `/init` |
| `dev` | `desktop` + the self-hosted compiler and its source tree (all optional) |
| `verify` | `desktop` + the fixtures the kernel's FAT32 self-test reads |

Directives:

| Directive | Meaning |
|---|---|
| `include <profile>` | splice another profile in here |
| `bin <target> [as <guestpath>]` | ship `userspace/build/<target>.cse` |
| `init <target>` | ship it as `/init.cse` — what the kernel launches |
| `file <hostpath> <guestpath>` | copy a host file |
| `text <guestpath> <content>` | literal content (`\n`, `\t` honoured) |
| `dir <guestpath>` | an empty directory |
| `mirror <hostdir> <guestdir> [--only <glob>]` | recursive copy |
| `icons <catalog>` | generate original RGBA/QOI CSIF icons into `/icons` |
| `size <bytes\|48M>` | volume size for this profile |
| `opt <directive>` | skip silently when the source is missing |

Later writes win, so a profile can override something it included. Quote a path
that contains spaces — `text "/long name.txt" hello` — because FAT32 allows them
and the kernel's own self-test depends on one.

`base` includes `icons assets/apps.tsv`, so shell, desktop, dev and verify
images all carry the icons. Each TSV row contains the executable basename,
pictogram family, readable badge and description. `scripts/make_icons.py`
renders the original 56×56 pixel artwork using only Python's standard library
and the existing CSIF encoder; no downloaded icon pack or generated binary
needs to be checked in.

The base profile also installs the same catalogue at `/etc/apps.tsv`. The
launcher looks up the description by executable basename and shows it in the
panel below the grid when the pointer is over an application. Descriptions
wrap to the available panel width; an ellipsis marks text that cannot fit.
Unregistered applications are identified as such, and a catalogue read error
is shown in words instead of leaving the panel silently empty.

### Desktop keyboard shortcuts

| Shortcut | Action |
|---|---|
| `Super+Enter` | Open a terminal. |
| `Super+Space` | Open the application launcher. |
| `Super+Q` | Close the focused window. |
| `Alt+Tab` / `Alt+Shift+Tab` | Show the window list while cycling to the next / previous window; release Alt to commit. |
| `Super+T` | Cycle the current tag's layout: Float → Tile → Monocle → Float. |
| `Super+F` | Toggle the focused window between floating and arranged. |
| `Super+Z` | Promote the focused window to master. |
| `Super+grave` | Toggle the scratchpad terminal; start it if absent. |
| `Super+Shift+grave` | Send the focused window to the scratchpad, replacing its previous window. |
| `Super+I` / `Super+D` | Increase / decrease the master-window count (1–8). |
| `Super+H` / `Super+L` | Decrease / increase the master area by 5 percentage points (20–85%). |
| `Super+J` / `Super+K` | Focus the next / previous window. |
| `Super+-` / `Super+=` | Minimize / maximize or restore the focused window. |
| `Super+0` | Show all nine tags. |
| `Super+1`…`9` | View tag 1–9. |
| `Super+Shift+1`…`9` | Move the focused window to tag 1–9. |
| `Super+Ctrl+1`…`9` | Toggle tag 1–9 in the current view. |
| `Super+Shift+Q` | Power off after pressing the chord twice within four seconds. |

The taskbar's layout badge spells out `FLOAT`, `TILE`, or `MONOCLE`; click it
to cycle.
At the prompt, terminal windows are labelled `term#<pid>`; while a foreground
command runs, its name replaces that label.

The text caret appears only in the focused terminal window.

The taskbar marks an occupied tag with `*`, even when its windows are hidden by
the current view.

The focused taskbar button starts with `>` in the configured focus-border color.

When the focused window closes, the WM chooses the most recently used visible
application; the launcher is not an automatic fallback. If none remains,
keyboard focus clears until you choose a window. `Apps` and Super+Space can
still focus or open the launcher.

The shipped bindings are in `/etc/wm.cst`. Create or edit `/var/wm/config.cst`
for personal bindings: it is loaded afterward, and a binding for the same
modifier/key chord replaces the shipped one. `unbind <mods> <key>` removes a
binding. For example, `bind alt+shift p spawn_term` adds a terminal shortcut;
`unbind super space` removes the launcher shortcut. Both files are reloaded
automatically when their modification time changes. Modifier names are
`super`, `alt`, `shift`, and `ctrl`; join combinations with `+`. Key names use
physical key positions, independent of the active keymap.
Invalid bind lines and invalid colour values also appear as a taskbar notice;
the serial log keeps the diagnostic.

Super+Space opens the application launcher. If one already exists, the WM
moves it to the current view, restores it if minimized, and focuses it instead
of starting a duplicate.
The taskbar's `Apps` button also opens it when the launcher is closed.

Right-clicking the desktop or a non-window taskbar area opens `Open Apps` and
`New terminal`. A window titlebar/frame or its taskbar button offers focus or
restore, minimize or restore, maximize or restore, and close. Escape dismisses
the menu; Up/Down and Enter operate it. Right-clicks in application content
continue to go to that application.

The launcher retains complete directory filenames in growable storage, with no
application-count or label-width cutoff. Labels that do not fit have an ellipsis;
the description panel identifies the selected name. Opening a program transfers
the filename through a segment, not the 16-byte title field or a shell command.
Console programs run in a terminal using that literal image path, so spaces,
apostrophes and dollar signs do not select a different program. Directory and
allocation errors are shown rather than silently presenting a complete list.

Typing filters application names and registered descriptions without regard to
case. Backspace removes the last character. Escape clears a nonempty query; with
an empty query, Escape closes the launcher.

The highlighted tile is the keyboard selection. Arrow keys move through the
grid; PageUp/PageDown move one page, Home/End choose the first/last app, and
Enter opens the selection. The launcher closes after it successfully sends the
spawn request; a send error leaves it open. Clicking a tile follows the same
rule. The same navigation works in filtered results, and the description panel
follows the selection.

The scrollbar thumb can be dragged; clicking its track moves one page. The
scrollbar is inset from the window's resize edge.

Moving the pointer over a tile lightens its background; this is separate from
the keyboard-selection outline.

Pixel-based windows keep the arrow cursor; text-grid terminal windows use the
I-beam cursor.

`netd`, `soundd` and `httpd` are services, not one-click applications, and are
omitted from the launcher. Their executables remain installed for explicit
startup with the required channels and configuration. In particular, opening
the application grid cannot start a second `netd` or repeat DHCP.

The development-only `wmpat` checkerboard fixture is also omitted from the
application grid; its image remains available to development profiles.

For a standalone export:

```sh
python3 scripts/make_icons.py /tmp/causticos-icons
```


## How the ISO boots without a disk

```
build/causticos.iso
  /boot/kernel.elf              the kernel
  /boot/rootfs.csvi             the root volume, sparse
  /boot/limine/limine.conf      generated by scripts/mkiso.sh
  /boot/limine/*.sys,*.bin      the bootloader
  /EFI/BOOT/BOOTX64.EFI         the UEFI half
```

At boot:

1. Limine loads the kernel and the `rootfs.csvi` **module**, and reports where it
   put the module (a higher-half address in the direct map).
2. `ramvol.init()` finds the module by its `CSVI` magic, validates it, takes a
   zeroed window from `kvmap`, and blits the sparse records into it.
3. It registers the result as a `StorageDevice` named `ram0`, with
   `boot_prio = PRIO_LIVE_ROOT`.
4. `fat32.mount_thread` asks `storage.root_pick()` which device should back `/`.
   The live root outranks any disk, so a machine with an installed system does
   not accidentally boot from it.
5. The existing FAT32 driver mounts `ram0`. Nothing below this point knows the
   volume is RAM.

The volume is fully writable and **volatile**. The boot says so:

```
ramvol: module /boot/rootfs.csvi 1452424B
storage: registered ram0 (131072 sectors x 512B, prio 100)
ramvol: live root ready (ram0, 131072 sectors x 512B, volatile)
root: ram0 (live, volatile)
vfs: mounted /
boot: /init.cse launched pid=2
```

### Why the root volume is 33 MiB and 93% empty

Because FAT32 requires at least 65525 clusters to be FAT32 at all — the kernel
checks on mount, and is right to — the smallest legal root volume is 66581
sectors, about **32.5 MiB**, whatever it holds. Bigger clusters make a bigger
volume, not a smaller one, so there is no such thing as a small FAT32. The
default is 33 MiB: one megabyte over the floor.

The desktop profile's payload is about 2.2 MB, so 30 of those 33 MiB are empty.
That empty space costs nothing on the ISO — the CSVI container stores only
non-zero sectors — but it is **guest RAM at boot**, because the kernel expands
the volume into memory. It is the single largest allocation of the boot.

This is measured, not guessed. The default used to be 45 MiB, and on the
documented 64 MB machine the desktop came up with **684 KB free**: it booted,
looked right, and could not spawn anything bigger than that. `cat` worked and
`ls` did not, failing in the CSE loader with `cse: seg map fail i=3` — which
reads like a loader bug and is a machine out of memory. At 33 MiB the same
machine reports **12992 KB free** and runs everything on the image.

If you want a genuinely small RAM footprint, the volume size is not the lever —
the filesystem is. The live root is FAT32 only because FAT32 is the filesystem
this kernel speaks, and it speaks it for real disks and USB sticks. A RAM root
in a format of its own would not owe FAT32's 32 MiB entry fee.

## The kernel command line

Baked into `limine.conf` at ISO build time. It replaced a compile-time switch,
which mattered because with a switch the kernel that ran the regression suite was
a *different binary* from the one that shipped.

| Word | Effect |
|---|---|
| *(nothing)* | mount the root, launch `/init.cse` |
| `smoke` | run the in-kernel smoke gauntlet + VFS self-test **instead of** `/init` |
| `selftest` | also run the FAT32 read/write gauntlet against the root. It writes, so it is opt-in |
| `root=<name>` | mount that named device (`ram0`, `ahci-p0`) rather than letting priority decide |

## CSVI — the sparse container, v1

A 33 MiB root holding ~2.2 MiB of programs is 93% zeros, and ISO 9660 does not
compress. CSVI stores only the sectors that carry data, each tagged with its LBA.
The desktop profile's container is about 2.3 MiB.

All fields little-endian.

**Header — 64 bytes at offset 0**

| Off | Size | Field | Notes |
|---:|---:|---|---|
| 0 | 4 | `magic` | `"CSVI"`, u32 `0x49565343` |
| 4 | 4 | `version` | 1 |
| 8 | 8 | `volume_bytes` | of the **expanded** volume; `== volume_sectors * sector_size` |
| 16 | 8 | `volume_sectors` | |
| 24 | 4 | `sector_size` | 512; v1 accepts nothing else |
| 28 | 4 | `flags` | bit 0 = payload is FAT32. Bits 1–31 reserved, must be 0 |
| 32 | 8 | `record_count` | |
| 40 | 8 | `records_offset` | must be 64 in v1 |
| 48 | 4 | `checksum` | FNV-1a 32 over the record region only |
| 52 | 4 | `reserved0` | 0 |
| 56 | 8 | `reserved1` | 0 |

**Records — `record_count` of them, contiguous, 8 + 512 = 520 bytes each**

| Off | Size | Field |
|---:|---:|---|
| 0 | 8 | `lba`, 0-based sector index in the expanded volume |
| 8 | 512 | `data` |

**Invariants**, checked by both the packer and the kernel:

- `file_size == records_offset + record_count * 520`, exactly — no slack
- `lba` strictly ascending: no duplicates, no reordering
- `lba < volume_sectors` for every record
- any sector no record names is zero in the expanded volume — guaranteed by
  `kvmap(KV_DATA)` zeroing what it hands back, so the expander never clears

One record per sector rather than run-length extents: extents would save about
64 KB on a 1.4 MB container and buy a variable-length bounds check inside the
kernel. Per-sector records make the expander a ten-line loop with one comparison,
and make the total file size derivable from the header — an integrity check for
free.

FNV-1a 32 rather than a cryptographic hash: four lines of Caustic, and it catches
the two things that actually happen to a file read off boot media — truncation
and garbling. Limine's `#blake2b` suffix on `module_path` is the answer if Secure
Boot ever matters.

```sh
python3 scripts/csvi.py info build/rootfs.csvi --runs   # verify every invariant
python3 scripts/csvi.py expand build/rootfs.csvi out.img
python3 scripts/fat32.py out.img ls
```

## Host tooling

| Script | Role |
|---|---|
| `scripts/fat32.py` | read, write and **format** FAT32; also a CLI (`ls`, `get`, `extract`, `info`) |
| `scripts/csvi.py` | pack, expand and validate CSVI containers |
| `scripts/mkroot.py` | resolve a profile into a volume image and a container |
| `scripts/mkiso.sh` | assemble the ISO, generate `limine.conf` |
| `scripts/qemu.sh` | build it and boot it |
| `scripts/libvirt.sh` | build it and boot it as a libvirt domain, from `causticos.libvirt.xml` |
| `scripts/rebuild.sh` | the build-before-boot policy both of those share |
| `scripts/verify.sh` | the regression sweep |
| `scripts/doctor.sh` | prerequisites |
| `scripts/usb.sh` | write to a removable device |

## Troubleshooting

**`fat32: no root volume after 5s (N storage devices, live root=0)`** — the
kernel found no candidate. `live root=0` means the CSVI module was not accepted;
the `ramvol:` or `csvi:` line just above says why.

**`csvi: checksum mismatch`** — the container is damaged. Rebuild the ISO; verify
the file on its own with `python3 scripts/csvi.py info`.

**`ramvol: kvmap failed for N bytes; free RAM is M bytes`** — the guest is too
small for the root volume. Boot with more memory or build a smaller profile.

**Boot stops after `boot: open /init.cse`** — the root mounted but `/init.cse` is
not on it. `caustic-mk run profiles` shows what the profile actually resolved to;
a profile with no `init` is rejected at build time.

**Serial output looks shredded under `--smp 2`** — a message composed from several
`serial.print` calls can interleave with another cpu's. The lock makes each
*call* atomic, not each *message*. Messages that matter use `serial.begin()` /
`serial.endln()` to hold the lock across the whole line; anything still built
from separate calls can still interleave.
