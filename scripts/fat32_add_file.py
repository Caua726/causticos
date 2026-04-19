#!/usr/bin/env python3
# fat32_add_file.py — add a single file to a FAT32 image without
# needing mount privileges. Writes the data clusters, updates the FAT
# chain, and creates a short-name (8.3) root directory entry.
#
# Usage: fat32_add_file.py <image> <8.3-name> <content-str>
#
# Intentionally minimal: does not handle LFN, subdirectories, or
# rewriting existing entries. Intended for seeding test fixtures used
# by the Caustic kernel FAT32 self-tests.

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
    # Write to all FAT copies to keep them in sync.
    value &= 0x0FFFFFFF
    for fat_idx in range(bpb["nfats"]):
        fat_off = (bpb["rsvd"] + fat_idx * bpb["fat_sz"]) * bpb["bps"] + cluster * 4
        f.seek(fat_off)
        # Preserve upper 4 reserved bits.
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


def build_short_name(name):
    # Expect "NAME.EXT" or "NAME"; upper-case; pad 8+3.
    if "." in name:
        base, ext = name.rsplit(".", 1)
    else:
        base, ext = name, ""
    base = base.upper().ljust(8)[:8]
    ext = ext.upper().ljust(3)[:3]
    return (base + ext).encode("ascii")


def fat_date_time():
    t = time.localtime()
    date = ((t.tm_year - 1980) << 9) | (t.tm_mon << 5) | t.tm_mday
    time16 = (t.tm_hour << 11) | (t.tm_min << 5) | (t.tm_sec // 2)
    return date, time16


def add_file(img_path, name, content):
    data = content.encode("utf-8") if isinstance(content, str) else content
    with open(img_path, "r+b") as f:
        bpb = read_bpb(f)
        cluster_bytes = bpb["bps"] * bpb["spc"]

        # Allocate cluster chain big enough for the data.
        n_clusters = max(1, (len(data) + cluster_bytes - 1) // cluster_bytes)
        clusters = []
        start = 3
        for _ in range(n_clusters):
            c = find_free_cluster(f, bpb, start)
            clusters.append(c)
            start = c + 1

        # Link them: each entry points to the next, last is EOF.
        for i, c in enumerate(clusters):
            nxt = clusters[i + 1] if i + 1 < len(clusters) else 0x0FFFFFFF
            write_fat_entry(f, bpb, c, nxt)

        # Write data into clusters.
        for i, c in enumerate(clusters):
            off = cluster_to_offset(bpb, c)
            chunk = data[i * cluster_bytes:(i + 1) * cluster_bytes]
            if len(chunk) < cluster_bytes:
                chunk = chunk + b"\x00" * (cluster_bytes - len(chunk))
            f.seek(off)
            f.write(chunk)

        # Craft directory entry.
        short = build_short_name(name)
        attr = 0x20  # ARCHIVE
        first_clus = clusters[0]
        date, time16 = fat_date_time()
        entry = bytearray(32)
        entry[0:11] = short
        entry[11] = attr
        entry[12] = 0         # NT reserved
        entry[13] = 0         # creation time tenths
        struct.pack_into("<HH", entry, 14, time16, date)  # creation time/date
        struct.pack_into("<H", entry, 18, date)           # last access date
        struct.pack_into("<H", entry, 20, (first_clus >> 16) & 0xFFFF)
        struct.pack_into("<HH", entry, 22, time16, date)  # write time/date
        struct.pack_into("<H", entry, 26, first_clus & 0xFFFF)
        struct.pack_into("<I", entry, 28, len(data))

        # Scan root dir for first free slot (0x00 = end, 0xE5 = deleted).
        # Root is a cluster chain starting at bpb.root_clus.
        cluster = bpb["root_clus"]
        placed = False
        while not placed:
            off = cluster_to_offset(bpb, cluster)
            f.seek(off)
            dir_data = bytearray(f.read(cluster_bytes))
            for i in range(0, cluster_bytes, 32):
                marker = dir_data[i]
                if marker == 0x00 or marker == 0xE5:
                    dir_data[i:i + 32] = entry
                    f.seek(off + i)
                    f.write(entry)
                    placed = True
                    break
            if not placed:
                nxt = read_fat_entry(f, bpb, cluster)
                if nxt >= 0x0FFFFFF8:
                    # Need to extend root.
                    new_c = find_free_cluster(f, bpb)
                    write_fat_entry(f, bpb, cluster, new_c)
                    write_fat_entry(f, bpb, new_c, 0x0FFFFFFF)
                    # Zero the new cluster.
                    f.seek(cluster_to_offset(bpb, new_c))
                    f.write(b"\x00" * cluster_bytes)
                    cluster = new_c
                else:
                    cluster = nxt

        print(f"added {name}: cluster={first_clus} size={len(data)} "
              f"chain={clusters}")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("usage: fat32_add_file.py <image> <name> <content>", file=sys.stderr)
        sys.exit(1)
    add_file(sys.argv[1], sys.argv[2], sys.argv[3])
