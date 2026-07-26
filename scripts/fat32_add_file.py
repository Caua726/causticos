#!/usr/bin/env python3
# fat32_add_file.py — populate a FAT32 image without mounting.
# Creates files (with LFN when name doesn't fit 8.3) and
# subdirectories (via mkdir). Intended to seed fixtures consumed by
# the Caustic kernel FAT32 self-tests.
#
# Usage:
#   fat32_add_file.py <image> addfile <name> <content> [<parent-cluster>]
#   fat32_add_file.py <image> mkdir <name> [<parent-cluster>]
#
# parent-cluster defaults to root. Prints the new entry's first cluster
# on success.

import struct
import sys
import time


def read_bpb(f):
    f.seek(0)
    sector0 = f.read(512)
    bps, spc = struct.unpack_from("<HB", sector0, 0x0B)
    rsvd, nfats = struct.unpack_from("<HB", sector0, 0x0E)
    fat_sz = struct.unpack_from("<I", sector0, 0x24)[0]
    root_clus = struct.unpack_from("<I", sector0, 0x2C)[0]
    tot_sec = struct.unpack_from("<I", sector0, 0x20)[0]
    return dict(bps=bps, spc=spc, rsvd=rsvd, nfats=nfats,
                fat_sz=fat_sz, root_clus=root_clus, tot_sec=tot_sec)


def cluster_to_offset(bpb, cluster):
    data_lba = bpb["rsvd"] + bpb["nfats"] * bpb["fat_sz"]
    return (data_lba + (cluster - 2) * bpb["spc"]) * bpb["bps"]


def read_fat_entry(f, bpb, cluster):
    fat_off = bpb["rsvd"] * bpb["bps"] + cluster * 4
    f.seek(fat_off)
    return struct.unpack("<I", f.read(4))[0] & 0x0FFFFFFF


def write_fat_entry(f, bpb, cluster, value):
    value &= 0x0FFFFFFF
    for fat_idx in range(bpb["nfats"]):
        fat_off = (bpb["rsvd"] + fat_idx * bpb["fat_sz"]) * bpb["bps"] + cluster * 4
        f.seek(fat_off)
        existing = struct.unpack("<I", f.read(4))[0]
        new_val = (existing & 0xF0000000) | value
        f.seek(fat_off)
        f.write(struct.pack("<I", new_val))


def find_free_cluster(f, bpb, start=3):
    fat_entries = (bpb["fat_sz"] * bpb["bps"]) // 4
    for c in range(start, fat_entries):
        if read_fat_entry(f, bpb, c) == 0:
            return c
    raise RuntimeError("no free cluster")


def fits_8_3(name):
    """True when name can fit the short 8.3 form (uppercase, simple chars)."""
    if name != name.upper():
        return False
    if any(ch in name for ch in " +,;=[]"):
        return False
    if "." in name:
        base, ext = name.rsplit(".", 1)
    else:
        base, ext = name, ""
    return len(base) <= 8 and len(ext) <= 3 and len(base) >= 1


def build_short_name(name, existing_shorts=()):
    """Return 11-byte uppercase 8.3 representation, using ~N suffix when
    collision/long."""
    def sanitize(s):
        out = []
        for ch in s.upper():
            if ch.isalnum() or ch in "_-":
                out.append(ch)
            elif ch == ".":
                out.append(".")
            else:
                out.append("_")
        return "".join(out)

    s = sanitize(name)
    if fits_8_3(s):
        if "." in s:
            base, ext = s.rsplit(".", 1)
        else:
            base, ext = s, ""
    else:
        if "." in s:
            base, ext = s.rsplit(".", 1)
            base = base.replace(".", "")
        else:
            base, ext = s, ""
        base = base.replace(".", "")[:6]
        # Disambiguate with numeric tail.
        n = 1
        while True:
            trial = f"{base}~{n}"
            if trial + "." + ext not in existing_shorts:
                break
            n += 1
        base = trial
    base = base.ljust(8)[:8]
    ext = ext.ljust(3)[:3]
    return (base + ext).encode("ascii")


def lfn_checksum(short11):
    s = 0
    for b in short11:
        s = ((s & 1) << 7) + (s >> 1) + b
        s &= 0xFF
    return s


def build_lfn_entries(name, short11):
    """Return a list of 32-byte LFN entries (physical order: highest
    sequence first so directory reads the LFN correctly)."""
    checksum = lfn_checksum(short11)
    chars = list(name.encode("utf-16-le"))
    # Pad with \0\0 terminator then 0xFF until multiple of 26.
    chars.extend([0x00, 0x00])
    while len(chars) % 26 != 0:
        chars.extend([0xFF, 0xFF])

    n_entries = len(chars) // 26
    entries = []
    for seq in range(1, n_entries + 1):
        e = bytearray(32)
        order = seq
        if seq == n_entries:
            order |= 0x40  # last-physical marker
        e[0] = order
        slice_ = chars[(seq - 1) * 26:(seq - 1) * 26 + 26]
        e[1:1 + 10]   = bytes(slice_[0:10])    # chars 1..5
        e[11]         = 0x0F                   # LFN attr
        e[12]         = 0x00                   # type
        e[13]         = checksum
        e[14:14 + 12] = bytes(slice_[10:22])   # chars 6..11
        e[26:26 + 2]  = b"\x00\x00"            # first cluster = 0
        e[28:28 + 4]  = bytes(slice_[22:26])   # chars 12..13
        entries.append(bytes(e))
    entries.reverse()  # physical order: last-seq first
    return entries


def fat_date_time():
    t = time.localtime()
    date = ((t.tm_year - 1980) << 9) | (t.tm_mon << 5) | t.tm_mday
    time16 = (t.tm_hour << 11) | (t.tm_min << 5) | (t.tm_sec // 2)
    return date, time16


def build_sfn_entry(short11, attr, first_clus, size):
    date, time16 = fat_date_time()
    entry = bytearray(32)
    entry[0:11] = short11
    entry[11] = attr
    entry[12] = 0
    entry[13] = 0
    struct.pack_into("<HH", entry, 14, time16, date)
    struct.pack_into("<H", entry, 18, date)
    struct.pack_into("<H", entry, 20, (first_clus >> 16) & 0xFFFF)
    struct.pack_into("<HH", entry, 22, time16, date)
    struct.pack_into("<H", entry, 26, first_clus & 0xFFFF)
    struct.pack_into("<I", entry, 28, size)
    return bytes(entry)


def collect_existing_shorts(f, bpb, dir_cluster):
    """Walk the dir cluster chain, return set of 11-byte short-name
    bytes already present."""
    out = set()
    cluster = dir_cluster
    cluster_bytes = bpb["bps"] * bpb["spc"]
    while True:
        off = cluster_to_offset(bpb, cluster)
        f.seek(off)
        data = f.read(cluster_bytes)
        for i in range(0, cluster_bytes, 32):
            marker = data[i]
            if marker == 0x00:
                return out
            if marker == 0xE5:
                continue
            if data[i + 11] == 0x0F:
                continue
            out.add(data[i:i + 11])
        nxt = read_fat_entry(f, bpb, cluster)
        if nxt >= 0x0FFFFFF8:
            return out
        cluster = nxt


def write_entries_to_dir(f, bpb, dir_cluster, entries):
    """Append an LFN+SFN run at the directory's true end, writing entries
    SEQUENTIALLY and spanning into a freshly-extended cluster when the current
    one fills. Critically, it never leaves a 0x00 slot BEFORE the new entries:
    a 0x00 marks end-of-directory, so a gap in an earlier cluster would make
    readers (dir_find / walk_dir) stop and never see entries written into a
    later cluster — the bug that silently dropped every file added after a
    directory grew past one cluster."""
    cluster_bytes = bpb["bps"] * bpb["spc"]
    n_slots = cluster_bytes // 32

    # 1. Walk the chain to the append point = first 0x00 (true end of dir).
    cluster = dir_cluster
    data = None
    slot = -1
    while True:
        off = cluster_to_offset(bpb, cluster)
        f.seek(off)
        data = bytearray(f.read(cluster_bytes))
        found = -1
        for i in range(n_slots):
            if data[i * 32] == 0x00:
                found = i
                break
        if found != -1:
            slot = found
            break
        nxt = read_fat_entry(f, bpb, cluster)
        if nxt >= 0x0FFFFFF8:
            # Full cluster with no terminator — extend; end is slot 0 of the new.
            new_c = find_free_cluster(f, bpb)
            write_fat_entry(f, bpb, cluster, new_c)
            write_fat_entry(f, bpb, new_c, 0x0FFFFFFF)
            cluster = new_c
            data = bytearray(b"\x00" * cluster_bytes)
            slot = 0
            break
        cluster = nxt

    # 2. Write entries one slot at a time from (cluster, slot), extending the
    #    chain when a cluster fills. The trailing slots stay 0x00 = terminator.
    for e in entries:
        if slot >= n_slots:
            f.seek(cluster_to_offset(bpb, cluster))
            f.write(data)
            nxt = read_fat_entry(f, bpb, cluster)
            if nxt >= 0x0FFFFFF8:
                new_c = find_free_cluster(f, bpb)
                write_fat_entry(f, bpb, cluster, new_c)
                write_fat_entry(f, bpb, new_c, 0x0FFFFFFF)
                cluster = new_c
                data = bytearray(b"\x00" * cluster_bytes)
            else:
                cluster = nxt
                f.seek(cluster_to_offset(bpb, cluster))
                data = bytearray(f.read(cluster_bytes))
            slot = 0
        data[slot * 32:slot * 32 + 32] = e
        slot += 1
    f.seek(cluster_to_offset(bpb, cluster))
    f.write(data)


def add_entry(f, bpb, parent_cluster, name, attr, first_clus, size):
    shorts = collect_existing_shorts(f, bpb, parent_cluster)
    short11 = build_short_name(name, existing_shorts=shorts)
    sfn = build_sfn_entry(short11, attr, first_clus, size)
    entries = []
    if not fits_8_3(name) or name != name.upper():
        entries.extend(build_lfn_entries(name, short11))
    entries.append(sfn)
    write_entries_to_dir(f, bpb, parent_cluster, entries)


def allocate_chain(f, bpb, n_clusters):
    clusters = []
    start = 3
    for _ in range(n_clusters):
        c = find_free_cluster(f, bpb, start)
        clusters.append(c)
        start = c + 1
        write_fat_entry(f, bpb, c, 0x0FFFFFFF)  # temp mark as allocated
    for i, c in enumerate(clusters):
        nxt = clusters[i + 1] if i + 1 < len(clusters) else 0x0FFFFFFF
        write_fat_entry(f, bpb, c, nxt)
    return clusters


def addfile(f, bpb, name, content, parent_cluster):
    data = content.encode("utf-8") if isinstance(content, str) else content
    cluster_bytes = bpb["bps"] * bpb["spc"]
    n_clusters = max(1, (len(data) + cluster_bytes - 1) // cluster_bytes)
    clusters = allocate_chain(f, bpb, n_clusters)
    for i, c in enumerate(clusters):
        off = cluster_to_offset(bpb, c)
        chunk = data[i * cluster_bytes:(i + 1) * cluster_bytes]
        if len(chunk) < cluster_bytes:
            chunk = chunk + b"\x00" * (cluster_bytes - len(chunk))
        f.seek(off)
        f.write(chunk)
    add_entry(f, bpb, parent_cluster, name, 0x20, clusters[0], len(data))
    return clusters[0]


def mkdir(f, bpb, name, parent_cluster):
    cluster_bytes = bpb["bps"] * bpb["spc"]
    clusters = allocate_chain(f, bpb, 1)
    new_c = clusters[0]
    # Zero the cluster.
    f.seek(cluster_to_offset(bpb, new_c))
    f.write(b"\x00" * cluster_bytes)
    # Write '.' and '..' entries inside.
    dot = build_sfn_entry(b".          ", 0x10, new_c, 0)
    # '..' points to parent; root ('.' root_clus == 2) encodes as 0.
    parent_for_dotdot = parent_cluster
    if parent_for_dotdot == bpb["root_clus"]:
        parent_for_dotdot = 0
    dotdot = build_sfn_entry(b"..         ", 0x10, parent_for_dotdot, 0)
    f.seek(cluster_to_offset(bpb, new_c))
    f.write(dot + dotdot)
    # Register in parent.
    add_entry(f, bpb, parent_cluster, name, 0x10, new_c, 0)
    return new_c


def dir_find(f, bpb, dir_cluster, name):
    """Find `name` (case-insensitive) among dir_cluster's entries. Returns
    (first_cluster, attr, size) or None. Reads the LFN run when present, so a
    name that does not fit 8.3 is matched by its real spelling."""
    cluster_bytes = bpb["bps"] * bpb["spc"]
    want = name.upper()
    cluster = dir_cluster
    lfn_parts = {}
    while True:
        f.seek(cluster_to_offset(bpb, cluster))
        data = f.read(cluster_bytes)
        for i in range(0, cluster_bytes, 32):
            e = data[i:i + 32]
            if e[0] == 0x00:
                return None
            if e[0] == 0xE5:
                lfn_parts = {}
                continue
            if e[11] == 0x0F:
                seq = e[0] & 0x1F
                raw = e[1:11] + e[14:26] + e[28:32]
                lfn_parts[seq] = raw.decode("utf-16-le", "ignore").split("\x00")[0]
                continue
            long_name = "".join(lfn_parts[k] for k in sorted(lfn_parts)) if lfn_parts else ""
            lfn_parts = {}
            base = e[:8].decode("ascii", "ignore").rstrip()
            ext = e[8:11].decode("ascii", "ignore").rstrip()
            short = base + ("." + ext if ext else "")
            if long_name.upper() == want or short.upper() == want:
                clus = struct.unpack_from("<H", e, 26)[0] | (struct.unpack_from("<H", e, 20)[0] << 16)
                size = struct.unpack_from("<I", e, 28)[0]
                return (clus, e[11], size)
        nxt = read_fat_entry(f, bpb, cluster)
        if nxt >= 0x0FFFFFF8:
            return None
        cluster = nxt


def readfile(f, bpb, path):
    """Pull a file back out of the image. The counterpart of addfilebin, and
    the only way a host-side test can check what the guest WROTE — a recorder
    or a downloader is not proved by the fact that it printed a number.

    Follows the cluster chain and truncates to the directory entry's size: the
    last cluster is almost never full, and returning its padding would make
    every byte-for-byte comparison fail on a correct file."""
    parts = [p for p in path.strip("/").split("/") if p]
    cluster = bpb["root_clus"]
    for comp in parts[:-1]:
        found = dir_find(f, bpb, cluster, comp)
        if not found or not (found[1] & 0x10):
            raise SystemExit(f"readfile: no directory {comp} in {path}")
        cluster = found[0]
    found = dir_find(f, bpb, cluster, parts[-1])
    if not found:
        raise SystemExit(f"readfile: {path} not found")
    first, attr, size = found
    if attr & 0x10:
        raise SystemExit(f"readfile: {path} is a directory")

    cluster_bytes = bpb["bps"] * bpb["spc"]
    out = bytearray()
    c = first
    # A chain that loops would otherwise read for ever; the image is finite and
    # so is the bound.
    guard = 0
    max_clusters = (size + cluster_bytes - 1) // cluster_bytes + 2
    while c < 0x0FFFFFF8 and c >= 2 and len(out) < size and guard <= max_clusters:
        f.seek(cluster_to_offset(bpb, c))
        out += f.read(cluster_bytes)
        c = read_fat_entry(f, bpb, c)
        guard += 1
    if len(out) < size:
        raise SystemExit(f"readfile: {path} claims {size} bytes, chain holds {len(out)}")
    return bytes(out[:size])


def resolve_path(f, bpb, path, make_dirs):
    """Split `path` on '/' and walk it for real, so "var/wm/pointer.cst"
    becomes a file named "pointer.cst" inside a directory "wm" inside a
    directory "var" — not one root entry whose name contains slashes. The
    kernel's path_lookup walks components; a flat entry is invisible to it,
    which is why seeded nested fixtures used to read back as E_NOENT.

    Returns (parent_cluster, leaf_name). With make_dirs, missing intermediate
    directories are created; without it, a missing one is an error."""
    parts = [p for p in path.split("/") if p]
    if not parts:
        raise SystemExit("empty path")
    cluster = bpb["root_clus"]
    for comp in parts[:-1]:
        found = dir_find(f, bpb, cluster, comp)
        if found is None:
            if not make_dirs:
                raise SystemExit(f"no such directory: {comp} (in {path})")
            cluster = mkdir(f, bpb, comp, cluster)
        else:
            if not (found[1] & 0x10):
                raise SystemExit(f"not a directory: {comp} (in {path})")
            cluster = found[0]
    return cluster, parts[-1]


def main():
    if len(sys.argv) < 4:
        print(__doc__, file=sys.stderr)
        sys.exit(1)
    img, op = sys.argv[1], sys.argv[2]
    with open(img, "r+b") as f:
        bpb = read_bpb(f)
        if op == "addfile":
            if len(sys.argv) < 5:
                print("addfile <name> <content> [<parent>]", file=sys.stderr)
                sys.exit(1)
            path = sys.argv[3]
            content = sys.argv[4]
            if len(sys.argv) > 5:
                parent, name = int(sys.argv[5]), path
            else:
                parent, name = resolve_path(f, bpb, path, make_dirs=True)
            c = addfile(f, bpb, name, content, parent)
            print(f"file {path} cluster={c}")
        elif op == "addfilebin":
            # addfilebin <name> <hostpath> [<parent>] — content is raw bytes
            # from a host file (binaries with NUL bytes, e.g. an .cse image,
            # which can't survive a shell string arg).
            if len(sys.argv) < 5:
                print("addfilebin <name> <hostpath> [<parent>]", file=sys.stderr)
                sys.exit(1)
            path = sys.argv[3]
            with open(sys.argv[4], "rb") as src:
                content = src.read()
            if len(sys.argv) > 5:
                parent, name = int(sys.argv[5]), path
            else:
                parent, name = resolve_path(f, bpb, path, make_dirs=True)
            c = addfile(f, bpb, name, content, parent)
            print(f"file {path} cluster={c} ({len(content)} bytes, binary)")
        elif op == "readfile":
            if len(sys.argv) < 5:
                print("readfile <name> <hostpath>", file=sys.stderr)
                sys.exit(1)
            data = readfile(f, bpb, sys.argv[3])
            with open(sys.argv[4], "wb") as dst:
                dst.write(data)
            print(f"readfile {sys.argv[3]} -> {sys.argv[4]} ({len(data)} bytes)")
        elif op == "mkdir":
            path = sys.argv[3]
            if len(sys.argv) > 4:
                parent, name = int(sys.argv[4]), path
            else:
                parent, name = resolve_path(f, bpb, path, make_dirs=True)
            existing = dir_find(f, bpb, parent, name)
            if existing is not None:
                if not (existing[1] & 0x10):
                    raise SystemExit(f"not a directory: {path}")
                print(f"mkdir {path} cluster={existing[0]} (exists)")
            else:
                c = mkdir(f, bpb, name, parent)
                print(f"mkdir {path} cluster={c}")
        else:
            print(f"unknown op: {op}", file=sys.stderr)
            sys.exit(1)


if __name__ == "__main__":
    main()
