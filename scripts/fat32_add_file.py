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
    """Append a consecutive run of entries (LFNs + SFN) to the
    directory chain, extending clusters if needed."""
    cluster_bytes = bpb["bps"] * bpb["spc"]
    slots_needed = len(entries)
    cluster = dir_cluster
    while True:
        off = cluster_to_offset(bpb, cluster)
        f.seek(off)
        data = bytearray(f.read(cluster_bytes))
        # Find a run of slots_needed consecutive free/end slots.
        n_slots = cluster_bytes // 32
        run_start = -1
        for i in range(n_slots):
            marker = data[i * 32]
            if marker == 0x00 or marker == 0xE5:
                if run_start == -1:
                    run_start = i
                if i - run_start + 1 == slots_needed:
                    for k, e in enumerate(entries):
                        byte_off = (run_start + k) * 32
                        data[byte_off:byte_off + 32] = e
                    f.seek(off)
                    f.write(data)
                    return
            else:
                run_start = -1
        # No fit in this cluster — advance or extend.
        nxt = read_fat_entry(f, bpb, cluster)
        if nxt >= 0x0FFFFFF8:
            new_c = find_free_cluster(f, bpb)
            write_fat_entry(f, bpb, cluster, new_c)
            write_fat_entry(f, bpb, new_c, 0x0FFFFFFF)
            f.seek(cluster_to_offset(bpb, new_c))
            f.write(b"\x00" * cluster_bytes)
            cluster = new_c
        else:
            cluster = nxt


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
            name = sys.argv[3]
            content = sys.argv[4]
            parent = int(sys.argv[5]) if len(sys.argv) > 5 else bpb["root_clus"]
            c = addfile(f, bpb, name, content, parent)
            print(f"file {name} cluster={c}")
        elif op == "mkdir":
            name = sys.argv[3]
            parent = int(sys.argv[4]) if len(sys.argv) > 4 else bpb["root_clus"]
            c = mkdir(f, bpb, name, parent)
            print(f"mkdir {name} cluster={c}")
        else:
            print(f"unknown op: {op}", file=sys.stderr)
            sys.exit(1)


if __name__ == "__main__":
    main()
