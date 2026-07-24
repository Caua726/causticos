#!/usr/bin/env python3
# fat32_get.py — extract a file from a FAT32 image to the host.
#
# The write-counterpart of fat32_add_file.py: reuses the proven FAT32 reader in
# fat32_verify_persist.py (read_bpb / walk_dir / read_file) to pull a file's
# bytes out of build/disk.img. This is the host half of the bootstrap "save":
# CausticOS writes <out>.cse via the VFS, and we lift it off the disk here.
#
# Usage: fat32_get.py <image> <path> <outpath>
#
# `path` is walked component by component, the way the kernel's path_lookup
# does — "var/wm/pointer.cst" means a file inside two real directories. A
# reader that matched the whole string against root entries would agree with a
# writer that stored it flat and both would be wrong about the same disk.
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fat32_verify_persist import read_bpb, walk_dir, read_file


def main():
    if len(sys.argv) != 4:
        print("usage: fat32_get.py <image> <path> <outpath>", file=sys.stderr)
        sys.exit(2)
    img, path, outpath = sys.argv[1], sys.argv[2], sys.argv[3]
    parts = [p for p in path.split("/") if p]
    if not parts:
        print("empty path", file=sys.stderr)
        sys.exit(2)
    with open(img, "rb") as f:
        bpb = read_bpb(f)
        cluster = bpb["root_clus"]
        for comp in parts[:-1]:
            nxt = None
            for long_name, attr, fc, size in walk_dir(f, bpb, cluster):
                if (attr & 0x10) and long_name.upper() == comp.upper():
                    nxt = fc
            if nxt is None:
                print(f"no such directory: {comp} (in {path})", file=sys.stderr)
                sys.exit(1)
            cluster = nxt
        for long_name, attr, fc, size in walk_dir(f, bpb, cluster):
            if attr & 0x10:
                continue  # directory
            if long_name.upper() == parts[-1].upper():
                data = read_file(f, bpb, fc, size)
                with open(outpath, "wb") as o:
                    o.write(data)
                print(f"extracted {path}: {len(data)} bytes -> {outpath}")
                return
    print(f"not found: {path}", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
