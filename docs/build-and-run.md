# Building and running causticos

Everything goes through `caustic-mk` and the `Causticfile` in the repository
root. There is no separate build script to learn: the manifest declares the
targets and the commands, and `caustic-mk run <name>` runs them.

```sh
caustic-mk run doctor     # is everything this needs installed?
caustic-mk run build      # kernel + userspace + a live ISO
caustic-mk run run        # boot it, no disk required
```

Arguments after `--` reach the command as its own:

```sh
caustic-mk run run -- --headless --smp 4
caustic-mk run build -- --profile shell
```

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

| Flag | Meaning |
|---|---|
| `--headless` | no window; serial on stdout |
| `--kvm` / `--no-kvm` | override the automatic choice |
| `-m SIZE`, `--smp N` | memory (default `512M`) and cpu count (default 2) |
| `--persist[=PATH]` | attach a FAT32 disk and boot from **it** instead of the live root; created from the current profile if absent |
| `--iso PATH` | boot a different ISO |
| `--monitor` | headless, with the QEMU monitor on `/tmp/cos-mon` and QMP on `/tmp/cos-qmp` |

The kernel command line is **not** set here. QEMU's `-append` only reaches a
kernel loaded with `-kernel`, and this one is loaded by Limine off the ISO — so
the command line is baked in at ISO build time with `run iso -- --cmdline "..."`.
Passing `-append` with a bootloader in the picture silently does nothing.

### `verify`

Two gates, both against the same kernel binary the ISO ships.

| Gate | What it boots | What it proves |
|---|---|---|
| `live` | the ISO alone, no disk on the bus | the root travels inside the image |
| `persist` | a scratch disk, `--no-live` ISO, `selftest` command line | the AHCI driver and the FAT32 write path work |

```sh
caustic-mk run verify                              # 1,2,4 cpus x 20 boots x 2 gates
caustic-mk run verify -- --smp 2 --runs 5          # quicker
caustic-mk run verify -- --live-only --keep-logs
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
| `size <bytes\|48M>` | volume size for this profile |
| `opt <directive>` | skip silently when the source is missing |

Later writes win, so a profile can override something it included. Quote a path
that contains spaces — `text "/long name.txt" hello` — because FAT32 allows them
and the kernel's own self-test depends on one.

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

Because FAT32 requires at least 65525 clusters to be FAT32 at all — the kernel
checks, and is right to — the smallest legal root volume is 66581 sectors, about
32.5 MiB. The default is 64 MiB, which is why the free space is not waste: it is
the live session's scratch.

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

A 64 MiB root holding ~1.4 MiB of programs is 97% zeros, and ISO 9660 does not
compress. CSVI stores only the sectors that carry data, each tagged with its LBA.
The desktop profile's container is about 1.4 MiB.

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
| `scripts/qemu.sh` | boot it |
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
