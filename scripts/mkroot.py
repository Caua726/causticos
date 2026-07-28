#!/usr/bin/env python3
"""mkroot.py — build a CausticOS root volume from a profile, in one process.

Two declarations, no overlap:

  userspace/Causticfile   WHAT CAN BE BUILT — every program, with its source
                          path. Already the only place a program's source is
                          written down; this reads it rather than keeping a
                          second list that can drift.
  profiles/<name>.profile WHAT SHIPS — which of those programs go in the image,
                          plus the config files and directories around them.

This replaces five hand-maintained manifests that had already diverged: the two
in scripts/run.sh and scripts/verify.sh, and one each in run-shell.sh, run-wm.sh
and scripts/seed-disk.sh — with run-wm.sh installing wm.cse as /init, which
contradicts the compositor-launches-the-WM model the other two implement.

Profile directives, one per line:

  include <profile>                    splice another profile in here
  bin <target> [as <guestpath>]        ship userspace/build/<target>.cse
                                       (default guest path /<target>.cse)
  init <target>                        ship it as /init.cse — what the kernel launches
  file <hostpath> <guestpath>          copy a host file
  text <guestpath> <content...>        literal content (\\n and \\t honoured)
  dir <guestpath>                      an empty directory
  mirror <hostdir> <guestdir> [--only <glob>]   recursive copy
  size <bytes|48M|64M>                 volume size for this profile
  opt <directive...>                   skip silently when the source is missing
  # ...                                comment

Later writes win, so a profile can override something it included — which is how
`verify` replaces base's greeting with the exact 27-byte string the kernel's
self-test checks for.
"""

import argparse
import fnmatch
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import csvi
import fat32

# 33 MiB: one megabyte over the floor, and the floor is the only thing setting
# this number. The sparse container on the ISO is the SAME size either way (it
# only stores non-zero sectors), so every byte here is guest RAM at boot and
# nothing else.
#
# It was 45 MiB, which booted and then could not run anything. On a 64 MB
# machine the desktop came up with 684 KB free — measured with `free` on the
# booted system — and every spawn bigger than that died in the CSE loader with
# "cse: seg map fail". `cat` worked, `ls` did not, and the terminal looked
# broken rather than out of memory. At 33 MiB the same machine has about 13 MB
# free and runs everything on the image.
#
# 30 of those 33 MiB are empty, and that is not waste to be trimmed: FAT32 is
# 65525 clusters or it is not FAT32, so with 512-byte sectors and one sector per
# cluster the smallest legal volume is 66581 sectors ≈ 32.5 MiB whatever it
# holds. The desktop profile's payload is about 2.2 MB. The kernel checks the
# cluster count on mount and is right to.
DEFAULT_SIZE = 33 * 1024 * 1024
SECTOR = 512


def repo_root():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def parse_size(s):
    m = re.fullmatch(r"(\d+)([KMG]?)i?B?", s.strip(), re.I)
    if not m:
        raise ValueError("bad size {!r}".format(s))
    n = int(m.group(1))
    return n * {"": 1, "K": 1024, "M": 1024 ** 2, "G": 1024 ** 3}[m.group(2).upper()]


def read_causticfile_targets(path):
    """name -> out path, from a Causticfile. Only `target` blocks matter here."""
    targets = {}
    name = None
    with open(path) as fh:
        for line in fh:
            line = line.split("//")[0].strip()
            m = re.match(r'target\s+"([^"]+)"', line)
            if m:
                name = m.group(1)
                targets.setdefault(name, "build/{}".format(name))
                continue
            m = re.match(r'out\s+"([^"]+)"', line)
            if m and name:
                targets[name] = m.group(1)
    return targets


def take_token(s):
    """Pull one path token off the front of `s`, honouring double quotes, and
    return (token, rest-with-leading-whitespace-stripped).

    Paths in a FAT32 image are allowed spaces — the kernel's own self-test looks
    up "/long-name-with-spaces and mixed case.txt" to prove LFN matching works —
    so splitting a directive on its first space silently truncates exactly the
    paths that matter most. Quote them. Stripping the remainder also means
    columns can be aligned in a profile without the padding ending up inside a
    `text` payload."""
    s = s.lstrip()
    if s.startswith('"'):
        end = s.find('"', 1)
        if end < 0:
            raise ValueError("unterminated quote in {!r}".format(s))
        return s[1:end], s[end + 1:].lstrip()
    tok, _, rest = s.partition(" ")
    return tok, rest.lstrip()


class Item:
    """One thing that ends up in the image."""
    def __init__(self, kind, guest, source=None, content=None):
        self.kind = kind          # "file" | "dir"
        self.guest = guest
        self.source = source      # host path, for provenance in --list
        self.content = content    # bytes


class Resolver:
    def __init__(self, root, targets, env):
        self.root = root
        self.targets = targets
        self.env = env
        self.items = {}           # guest path -> Item (later writes win)
        self.order = []           # insertion order, for stable listing
        self.size = None
        self.init_name = None
        self.skipped = []
        self.seen_profiles = []

    # -- helpers ----------------------------------------------------------

    def _host(self, p):
        p = os.path.expandvars(p) if "$" in p else p
        return p if os.path.isabs(p) else os.path.join(self.root, p)

    def _put(self, item):
        if item.guest not in self.items:
            self.order.append(item.guest)
        self.items[item.guest] = item

    def _target_output(self, name):
        if name not in self.targets:
            raise ValueError(
                "'{}' is not a target in userspace/Causticfile — add it there, "
                "or fix the name".format(name))
        return os.path.join(self.root, "userspace", self.targets[name])

    # -- directives -------------------------------------------------------

    def load(self, profile, chain=()):
        if profile in chain:
            raise ValueError("profile include cycle: {}".format(
                " -> ".join(list(chain) + [profile])))
        path = os.path.join(self.root, "profiles", profile + ".profile")
        if not os.path.exists(path):
            avail = sorted(f[:-8] for f in os.listdir(os.path.join(self.root, "profiles"))
                           if f.endswith(".profile"))
            raise ValueError("no profile {!r} (have: {})".format(profile, ", ".join(avail)))
        self.seen_profiles.append(profile)
        with open(path) as fh:
            for lineno, raw in enumerate(fh, 1):
                line = raw.rstrip("\n")
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                try:
                    self._directive(stripped, chain + (profile,))
                except ValueError as e:
                    raise ValueError("{}.profile:{}: {}".format(profile, lineno, e))

    def _directive(self, line, chain, optional=False):
        word, _, rest = line.partition(" ")
        rest = rest.strip()

        if word == "opt":
            if not rest:
                raise ValueError("opt needs a directive after it")
            return self._directive(rest, chain, optional=True)

        if word == "include":
            return self.load(rest, chain)

        if word == "size":
            self.size = parse_size(rest)
            return

        if word == "init":
            self.init_name = rest
            return self._bin(rest, "/init.cse", optional)

        if word == "bin":
            parts = rest.split()
            if len(parts) == 3 and parts[1] == "as":
                return self._bin(parts[0], parts[2], optional)
            if len(parts) == 1:
                return self._bin(parts[0], "/" + parts[0] + ".cse", optional)
            raise ValueError("bin <target> [as <guestpath>]")

        if word == "file":
            hostrel, rest2 = take_token(rest)
            guest, extra = take_token(rest2)
            if not hostrel or not guest or extra:
                raise ValueError('file <hostpath> <guestpath>  (quote either if it has spaces)')
            host = self._host(hostrel)
            if not os.path.isfile(host):
                if optional:
                    self.skipped.append("file {} (missing)".format(hostrel))
                    return
                raise ValueError("no such file: {}".format(host))
            with open(host, "rb") as fh:
                self._put(Item("file", guest, hostrel, fh.read()))
            return

        if word == "text":
            guest, content = take_token(rest)
            if not guest:
                raise ValueError('text <guestpath> <content>  (quote the path if it has spaces)')
            body = content.replace("\\n", "\n").replace("\\t", "\t")
            self._put(Item("file", guest, "<literal>", body.encode("utf-8")))
            return

        if word == "dir":
            guest, extra = take_token(rest)
            if not guest or extra:
                raise ValueError("dir <guestpath>")
            self._put(Item("dir", guest.rstrip("/") or "/"))
            return

        if word == "mirror":
            return self._mirror(rest, optional)

        raise ValueError("unknown directive {!r}".format(word))

    def _bin(self, name, guest, optional):
        try:
            host = self._target_output(name)
        except ValueError:
            if optional:
                self.skipped.append("bin {} (not a target)".format(name))
                return
            raise
        if not os.path.isfile(host):
            if optional:
                self.skipped.append("bin {} (not built)".format(name))
                return
            raise ValueError(
                "{} is a target but {} does not exist — run `caustic-mk build all` "
                "in userspace/ first".format(name, os.path.relpath(host, self.root)))
        with open(host, "rb") as fh:
            self._put(Item("file", guest, os.path.relpath(host, self.root), fh.read()))

    def _mirror(self, rest, optional):
        parts = rest.split()
        only = None
        if "--only" in parts:
            i = parts.index("--only")
            only = parts[i + 1]
            parts = parts[:i] + parts[i + 2:]
        if len(parts) != 2:
            raise ValueError("mirror <hostdir> <guestdir> [--only <glob>]")
        host, guest = self._host(parts[0]), parts[1].rstrip("/")
        if not os.path.isdir(host):
            if optional:
                self.skipped.append("mirror {} (missing)".format(parts[0]))
                return
            raise ValueError("no such directory: {}".format(host))
        skip_dirs = {"build", ".caustic", ".git", "tests", "examples", "docs", "lsp"}
        for dirpath, dirnames, filenames in os.walk(host):
            dirnames[:] = sorted(d for d in dirnames
                                 if d not in skip_dirs and not d.startswith("."))
            for fn in sorted(filenames):
                if only and not fnmatch.fnmatch(fn, only):
                    continue
                hp = os.path.join(dirpath, fn)
                rel = os.path.relpath(hp, host)
                with open(hp, "rb") as fh:
                    self._put(Item("file", guest + "/" + rel.replace(os.sep, "/"),
                                   os.path.relpath(hp, self.root), fh.read()))

    # -- output -----------------------------------------------------------

    def payload_bytes(self):
        return sum(len(i.content) for i in self.items.values() if i.kind == "file")

    def build(self, size):
        sectors = size // SECTOR
        f, bpb = fat32.new_volume(sectors)
        for guest in self.order:
            item = self.items[guest]
            if item.kind == "dir":
                fat32.make_dir(f, bpb, item.guest)
            else:
                fat32.add_path(f, bpb, item.guest, item.content)
        return f, bpb


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--profile", default="desktop")
    ap.add_argument("--img", help="write the raw FAT32 volume here")
    ap.add_argument("--csvi", help="write the CSVI container here")
    ap.add_argument("--compress", action="store_true",
                    help="xz the container's record region (the kernel inflates it at boot)")
    ap.add_argument("--size", help="volume size (default 64M, or the profile's `size`)")
    ap.add_argument("--label", default="CAUSTICOS")
    ap.add_argument("--init", metavar="TARGET",
                    help="override the profile's /init.cse (for one-off test images)")
    ap.add_argument("--add", action="append", metavar="HOST[:GUEST]",
                    help="add a host file; guest path defaults to /<basename>. Repeatable.")
    ap.add_argument("--list", action="store_true",
                    help="resolve and print what would ship, build nothing")
    ap.add_argument("-q", "--quiet", action="store_true")
    a = ap.parse_args()

    root = repo_root()
    targets = read_causticfile_targets(os.path.join(root, "userspace", "Causticfile"))
    env = dict(os.environ)
    env.setdefault("CAUSTIC_DIR", os.path.join(os.path.dirname(root), "Caustic"))
    os.environ.setdefault("CAUSTIC_DIR", env["CAUSTIC_DIR"])

    r = Resolver(root, targets, env)
    try:
        r.load(a.profile)
        # Command-line overrides, applied after the profile so they win. These
        # exist for the one-off images the test scripts need — "this profile,
        # but /init is the harness and these three files are on it" — which is
        # not worth a profile each and used to be a hand-rolled mkfs.fat plus a
        # loop of one-file-per-process seeding in every script that wanted one.
        for spec in a.add or []:
            host, sep, guest = spec.partition(":")
            if not sep:
                host, guest = spec, "/" + os.path.basename(spec)
            r._directive('file "{}" "{}"'.format(host, guest), ())
        if a.init:
            r._directive("init " + a.init, ())
    except ValueError as e:
        sys.exit("mkroot: {}".format(e))

    if a.list:
        print("profile {} (includes: {})".format(a.profile, " <- ".join(r.seen_profiles)))
        print("init    {}".format(r.init_name or "(none declared)"))
        for guest in sorted(r.order):
            it = r.items[guest]
            if it.kind == "dir":
                print("  {:>9}  {}/".format("dir", it.guest))
            else:
                print("  {:>9}  {}   <- {}".format(len(it.content), it.guest, it.source))
        print("{} entries, {} bytes of payload".format(len(r.order), r.payload_bytes()))
        if r.skipped:
            print("skipped (optional):")
            for s in r.skipped:
                print("  {}".format(s))
        return 0

    if r.init_name is None:
        sys.exit("mkroot: profile {!r} declares no `init` — the kernel would find "
                 "no /init.cse and boot to a bare framebuffer".format(a.profile))

    size = parse_size(a.size) if a.size else (r.size or DEFAULT_SIZE)
    if size < fat32.MIN_SECTORS * SECTOR:
        sys.exit("mkroot: --size {} is below the FAT32 minimum of {:.1f} MiB"
                 .format(a.size or size, fat32.MIN_SECTORS * SECTOR / 1048576))

    payload = r.payload_bytes()
    if payload > size * 0.9:
        sys.exit("mkroot: {:.1f} MiB of payload will not fit a {:.1f} MiB volume — "
                 "raise --size".format(payload / 1048576, size / 1048576))

    f, bpb = r.build(size)

    if a.img:
        os.makedirs(os.path.dirname(os.path.abspath(a.img)), exist_ok=True)
        fat32.save_image(f, a.img, bpb)
    else:
        fat32.finalize(f, bpb)

    blob = None
    if a.csvi:
        blob = csvi.pack(bytes(f.getbuffer()), compress=a.compress)
        os.makedirs(os.path.dirname(os.path.abspath(a.csvi)), exist_ok=True)
        with open(a.csvi, "wb") as fh:
            fh.write(blob)

    if not a.quiet:
        nfiles = sum(1 for i in r.items.values() if i.kind == "file")
        ndirs = len(r.order) - nfiles
        print("root: profile {} -> /init.cse = {}".format(a.profile, r.init_name))
        print("  {} files + {} dirs, {:.1f} KiB payload in a {:.0f} MiB volume"
              .format(nfiles, ndirs, payload / 1024, size / 1048576))
        if a.img:
            print("  {}  {} bytes".format(a.img, os.path.getsize(a.img)))
        if a.csvi:
            print("  {}  {} bytes ({:.2f}% of the volume, {} sectors carry data)"
                  .format(a.csvi, len(blob), 100.0 * len(blob) / size,
                          csvi.parse_header(blob)["record_count"]))
        for s in r.skipped:
            print("  skipped: {}".format(s))
    return 0


if __name__ == "__main__":
    sys.exit(main())
