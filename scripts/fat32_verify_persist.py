#!/usr/bin/env python3
# fat32_verify_persist.py — read FAT32 image after the kernel self-test
# run and confirm every expected artefact (creates + deletes + renames
# + mkdir/rmdir) landed on disk as written. Uses pyfatfs-free parsing
# (matches fat32_add_file.py semantics).
#
# Expected post-kernel state:
#   /hello.txt        — 27B seed (untouched)
#   /bigfile.bin      — 1200B seed (untouched)
#   /long-name-with-spaces and mixed case.txt — 16B seed (untouched)
#   /docs/            — seeded subdir, now ALSO holds notebook.md (renamed)
#   /docs/readme.md   — 36B seed
#   /docs/notebook.md — 11B, moved from /data (kernel test)
#   /long round-trip name with spaces.md — 20B (kernel test)
#   /large.bin        — 2600B pattern (i*31+7)&0xFF (kernel test)
#   /data/            — DELETED (kernel rmdir)
#   /roundtrip.txt    — DELETED (kernel unlink)

import struct
import sys


def read_bpb(f):
    f.seek(0)
    s = f.read(512)
    bps, spc = struct.unpack_from("<HB", s, 0x0B)
    rsvd, nfats = struct.unpack_from("<HB", s, 0x0E)
    fat_sz = struct.unpack_from("<I", s, 0x24)[0]
    root_clus = struct.unpack_from("<I", s, 0x2C)[0]
    return dict(bps=bps, spc=spc, rsvd=rsvd, nfats=nfats,
                fat_sz=fat_sz, root_clus=root_clus)


def cluster_off(bpb, c):
    data_lba = bpb["rsvd"] + bpb["nfats"] * bpb["fat_sz"]
    return (data_lba + (c - 2) * bpb["spc"]) * bpb["bps"]


def fat_next(f, bpb, c):
    fat_off = bpb["rsvd"] * bpb["bps"] + c * 4
    f.seek(fat_off)
    return struct.unpack("<I", f.read(4))[0] & 0x0FFFFFFF


def walk_dir(f, bpb, start_cluster):
    """Yield (long_name, attr, first_cluster, size) for each live entry."""
    cluster = start_cluster
    cbytes = bpb["bps"] * bpb["spc"]
    lfn_chars = [None] * 260
    lfn_total = 0
    while True:
        f.seek(cluster_off(bpb, cluster))
        data = f.read(cbytes)
        for i in range(0, cbytes, 32):
            e = data[i:i + 32]
            m = e[0]
            if m == 0:
                return
            if m == 0xE5:
                lfn_chars = [None] * 260
                lfn_total = 0
                continue
            attr = e[11]
            if attr == 0x0F:
                order = m
                seq = order & 0x3F
                if order & 0x40:
                    lfn_total = seq
                    lfn_chars = [None] * 260
                # 13 UCS-2 code units
                byte_pairs = (list(range(1, 11, 2)) +
                              list(range(14, 26, 2)) +
                              list(range(28, 32, 2)))
                base = (seq - 1) * 13
                for k, bo in enumerate(byte_pairs):
                    lo = e[bo]
                    hi = e[bo + 1]
                    if lo == 0 and hi == 0:
                        if lfn_chars[base + k] is None:
                            lfn_chars[base + k] = 0
                    elif hi == 0:
                        lfn_chars[base + k] = lo
                    else:
                        lfn_chars[base + k] = 0xFF   # non-ASCII sentinel
            else:
                long_name = None
                if lfn_total > 0:
                    max_end = lfn_total * 13
                    out = []
                    for k in range(max_end):
                        c = lfn_chars[k]
                        if c is None or c == 0:
                            break
                        out.append(c)
                    try:
                        long_name = bytes(out).decode("ascii")
                    except UnicodeDecodeError:
                        long_name = None
                lfn_chars = [None] * 260
                lfn_total = 0
                short = e[0:11]
                first_hi = struct.unpack("<H", e[20:22])[0]
                first_lo = struct.unpack("<H", e[26:28])[0]
                fc = (first_hi << 16) | first_lo
                size = struct.unpack("<I", e[28:32])[0]
                if long_name is None:
                    base = short[0:8].decode("ascii").rstrip()
                    ext = short[8:11].decode("ascii").rstrip()
                    long_name = base + ("." + ext if ext else "")
                yield long_name, attr, fc, size
        nxt = fat_next(f, bpb, cluster)
        if nxt >= 0x0FFFFFF8:
            return
        cluster = nxt


def read_file(f, bpb, first_cluster, size):
    out = bytearray()
    cluster = first_cluster
    cbytes = bpb["bps"] * bpb["spc"]
    while size > 0 and cluster >= 2:
        f.seek(cluster_off(bpb, cluster))
        chunk = f.read(min(cbytes, size))
        out.extend(chunk)
        size -= len(chunk)
        if size <= 0:
            break
        nxt = fat_next(f, bpb, cluster)
        if nxt >= 0x0FFFFFF8:
            break
        cluster = nxt
    return bytes(out)


def main(path):
    failures = []

    def expect(cond, msg):
        if not cond:
            failures.append(msg)
            print(f"FAIL: {msg}")
        else:
            print(f"  ok: {msg}")

    with open(path, "rb") as f:
        bpb = read_bpb(f)
        root_entries = {
            name.lower(): (name, attr, fc, size)
            for name, attr, fc, size in walk_dir(f, bpb, bpb["root_clus"])
        }

        # Preserved seeds
        expect("hello.txt" in root_entries, "/hello.txt present")
        expect("bigfile.bin" in root_entries, "/bigfile.bin present")
        expect("long-name-with-spaces and mixed case.txt" in root_entries,
               "/long-name-with-spaces and mixed case.txt present")
        expect("docs" in root_entries, "/docs/ present")

        # Kernel-created
        lfn_key = "long round-trip name with spaces.md"
        expect(lfn_key in root_entries,
               f"/{lfn_key} created by kernel")
        if lfn_key in root_entries:
            _, attr, fc, size = root_entries[lfn_key]
            expect(size == 20, f"{lfn_key}: size == 20 (got {size})")
            content = read_file(f, bpb, fc, size)
            expect(content == b"write-path LFN works",
                   f"{lfn_key}: payload matches")

        expect("large.bin" in root_entries,
               "/large.bin created by kernel")
        if "large.bin" in root_entries:
            _, attr, fc, size = root_entries["large.bin"]
            expect(size == 2600, f"large.bin: size == 2600 (got {size})")
            content = read_file(f, bpb, fc, size)
            expected = bytes([(i * 31 + 7) & 0xFF for i in range(2600)])
            expect(content == expected,
                   "large.bin: pattern (i*31+7)&0xFF over 2600B")

        # Deleted
        expect("roundtrip.txt" not in root_entries,
               "/roundtrip.txt deleted")
        expect("data" not in root_entries,
               "/data/ deleted")

        # /docs listing — should contain readme.md (seed) + notebook.md (moved).
        docs_entry = root_entries.get("docs")
        if docs_entry:
            docs_children = {
                name.lower(): (name, attr, fc, size)
                for name, attr, fc, size in walk_dir(f, bpb, docs_entry[2])
                if name not in (".", "..")
            }
            expect("readme.md" in docs_children, "/docs/readme.md present")
            expect("notebook.md" in docs_children,
                   "/docs/notebook.md present (moved from /data)")
            if "notebook.md" in docs_children:
                _, attr, fc, size = docs_children["notebook.md"]
                content = read_file(f, bpb, fc, size)
                expect(content == b"inside data",
                       "/docs/notebook.md payload survived the rename")

    print()
    if failures:
        print(f"{len(failures)} FAILURES")
        sys.exit(1)
    print("ALL PERSISTENCE CHECKS PASSED")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "build/disk.img")
