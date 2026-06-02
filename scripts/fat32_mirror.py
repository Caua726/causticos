#!/usr/bin/env python3
# fat32_mirror.py — mirror a host source tree onto a FAT32 image.
#
# For the self-host bootstrap: the compiler on CausticOS compiles /src/main.cst,
# which imports the whole tree (src/, std/, caustic-linker/, caustic-assembler/)
# by normalized relative paths. This lays those trees onto the disk at /<name>,
# copying only .cst sources (+ the dirs that hold them). Reuses fat32_add_file's
# proven FAT32 writer (mkdir grows directories, addfile chains clusters).
#
# Usage: fat32_mirror.py <image> <hostdir>...   (each mirrored to /<basename>)
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fat32_add_file import read_bpb, mkdir, addfile

SKIP_DIRS = {"build", ".caustic", ".git", "tests", "examples", "docs", "lsp"}


def has_cst(hostdir):
    for root, dirs, files in os.walk(hostdir):
        if any(n.endswith(".cst") for n in files):
            return True
    return False


def mirror(f, bpb, hostdir, parent_cluster):
    for name in sorted(os.listdir(hostdir)):
        full = os.path.join(hostdir, name)
        if os.path.isdir(full):
            if name in SKIP_DIRS or name.startswith("."):
                continue
            if not has_cst(full):
                continue
            c = mkdir(f, bpb, name, parent_cluster)
            mirror(f, bpb, full, c)
        elif name.endswith(".cst"):
            data = open(full, "rb").read()
            addfile(f, bpb, name, data, parent_cluster)


def main():
    if len(sys.argv) < 3:
        print("usage: fat32_mirror.py <image> <hostdir>...", file=sys.stderr)
        sys.exit(2)
    img = sys.argv[1]
    with open(img, "r+b") as f:
        bpb = read_bpb(f)
        for hostpath in sys.argv[2:]:
            hostpath = hostpath.rstrip("/")
            top = os.path.basename(hostpath)
            c = mkdir(f, bpb, top, bpb["root_clus"])
            mirror(f, bpb, hostpath, c)
            print(f"mirrored {hostpath} -> /{top}")


if __name__ == "__main__":
    main()
