#!/usr/bin/env python3
# fat32_get.py — extract a file from a FAT32 image to the host.
#
# The write-counterpart of fat32_add_file.py: reuses the proven FAT32 reader in
# fat32_verify_persist.py (read_bpb / walk_dir / read_file) to pull a file's
# bytes out of build/disk.img. This is the host half of the bootstrap "save":
# CausticOS writes <out>.cse via the VFS, and we lift it off the disk here.
#
# Usage: fat32_get.py <image> <name> <outpath>   (name is a root-dir entry)
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fat32_verify_persist import read_bpb, walk_dir, read_file


def main():
    if len(sys.argv) != 4:
        print("usage: fat32_get.py <image> <name> <outpath>", file=sys.stderr)
        sys.exit(2)
    img, name, outpath = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(img, "rb") as f:
        bpb = read_bpb(f)
        for long_name, attr, fc, size in walk_dir(f, bpb, bpb["root_clus"]):
            if attr & 0x10:
                continue  # directory
            if long_name == name:
                data = read_file(f, bpb, fc, size)
                with open(outpath, "wb") as o:
                    o.write(data)
                print(f"extracted {name}: {len(data)} bytes -> {outpath}")
                return
    print(f"not found: {name}", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
