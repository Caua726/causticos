#!/usr/bin/env python3
"""fat32.py — read, write and CREATE FAT32 volumes, without mounting anything.

One library for the whole host side of a CausticOS root image. It replaces four
scripts that had grown apart (fat32_add_file.py, fat32_mirror.py, fat32_get.py
and the reader half of fat32_verify_persist.py) and adds the piece none of them
had: a formatter.

Why a formatter instead of mkfs.fat: the geometry a volume ends up with decides
whether the kernel will mount it, and `fat32.mount` in kernel/fs/fat32.cst is
strict — signature, the literal "FAT32   " fs_type, bps == the device's own
sector size, spc a power of two, nfats in 1..2, root_ent_cnt / tot_sec_16 /
fat_sz_16 / fs_ver all zero, data_lba inside the volume, root_clus in range,
tot_sec <= the device's sector count, and cluster_count >= 65525. Shelling out
to mkfs.fat means inheriting whatever it picks and reverse-engineering the
result when a mount fails. Owning the format means every one of those checks is
satisfied by construction, and it takes mkfs.fat AND qemu-img off the build's
prerequisite list entirely.

That >= 65525 rule is also why a root volume cannot be small: with 512-byte
sectors and one sector per cluster the floor for a legal FAT32 is
32 + 2*512 + 65525 = 66581 sectors, about 32.5 MiB. There is no shortcut around
it that the kernel would accept, and the kernel is right to insist.

Everything operates on an in-memory bytearray through a BytesIO view, so a whole
image is built in one process — the seed step used to be ~45 separate python
invocations, of which more than half the wall time was interpreter startup.
"""

import io
import struct
import sys
import time

SECTOR = 512
ATTR_VOLUME_ID = 0x08
ATTR_DIR = 0x10
ATTR_ARCHIVE = 0x20
ATTR_LFN = 0x0F
EOC = 0x0FFFFFFF          # end-of-chain marker written into the FAT
EOC_MIN = 0x0FFFFFF8      # any value >= this terminates a chain

# The smallest legal FAT32, in sectors, for the geometry format_fat32 uses
# (512 B sectors, 1 sector/cluster, 32 reserved, 2 FATs). Anything below this is
# a FAT16 by the spec's own definition and the kernel rejects it by name.
MIN_SECTORS = 66581


# ── Geometry ──────────────────────────────────────────────────────────────

def read_bpb(f):
    """Parse the BIOS Parameter Block. Also resets the free-cluster hint: a new
    volume view must not inherit the previous one's allocation position."""
    global _next_free
    _next_free = 3
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


def cluster_bytes(bpb):
    return bpb["bps"] * bpb["spc"]


def cluster_count(bpb):
    data_secs = bpb["tot_sec"] - bpb["rsvd"] - bpb["nfats"] * bpb["fat_sz"]
    return data_secs // bpb["spc"]


# ── FAT ───────────────────────────────────────────────────────────────────

def read_fat_entry(f, bpb, cluster):
    fat_off = bpb["rsvd"] * bpb["bps"] + cluster * 4
    f.seek(fat_off)
    return struct.unpack("<I", f.read(4))[0] & 0x0FFFFFFF


def write_fat_entry(f, bpb, cluster, value):
    """Write into every FAT copy. The kernel reads FAT 0, but a volume whose
    copies disagree is a volume that fails the first time anything else looks."""
    value &= 0x0FFFFFFF
    for fat_idx in range(bpb["nfats"]):
        fat_off = (bpb["rsvd"] + fat_idx * bpb["fat_sz"]) * bpb["bps"] + cluster * 4
        f.seek(fat_off)
        existing = struct.unpack("<I", f.read(4))[0]
        new_val = (existing & 0xF0000000) | value
        f.seek(fat_off)
        f.write(struct.pack("<I", new_val))


# Allocation hint. find_free_cluster used to restart its scan at cluster 3 on
# every single allocation, so filling a volume was quadratic in the number of
# clusters — packing a source tree of a few thousand files spent essentially all
# of its time re-reading FAT entries it had already rejected. The hint only ever
# moves forward within one build; free() would have to reset it, and nothing
# here frees.
_next_free = 3


def find_free_cluster(f, bpb, start=None):
    global _next_free
    fat_entries = (bpb["fat_sz"] * bpb["bps"]) // 4
    limit = min(fat_entries, cluster_count(bpb) + 2)
    begin = _next_free if start is None else start
    for c in range(begin, limit):
        if read_fat_entry(f, bpb, c) == 0:
            if start is None:
                _next_free = c
            return c
    # The hint can only ever be too far along, never too far back, so one
    # rescan from the beginning is enough to be sure.
    for c in range(3, begin):
        if read_fat_entry(f, bpb, c) == 0:
            return c
    raise RuntimeError(
        "no free cluster: volume is full ({} clusters)".format(cluster_count(bpb)))


def allocate_chain(f, bpb, n_clusters):
    global _next_free
    clusters = []
    for _ in range(n_clusters):
        c = find_free_cluster(f, bpb)
        clusters.append(c)
        write_fat_entry(f, bpb, c, EOC)   # claim it so the next search skips it
        _next_free = c + 1
    for i, c in enumerate(clusters):
        nxt = clusters[i + 1] if i + 1 < len(clusters) else EOC
        write_fat_entry(f, bpb, c, nxt)
    return clusters


# ── Names: 8.3 and LFN ────────────────────────────────────────────────────

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
    """11-byte uppercase 8.3 representation, with a ~N tail on collision."""
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
        n = 1
        while True:
            trial = "{}~{}".format(base, n)
            if (trial.ljust(8)[:8] + ext.ljust(3)[:3]).encode("ascii") not in existing_shorts:
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
    """32-byte LFN entries in PHYSICAL order (highest sequence first), which is
    the order a directory reader walks them in."""
    checksum = lfn_checksum(short11)
    chars = list(name.encode("utf-16-le"))
    chars.extend([0x00, 0x00])
    while len(chars) % 26 != 0:
        chars.extend([0xFF, 0xFF])

    n_entries = len(chars) // 26
    entries = []
    for seq in range(1, n_entries + 1):
        e = bytearray(32)
        order = seq
        if seq == n_entries:
            order |= 0x40                      # last-physical marker
        e[0] = order
        sl = chars[(seq - 1) * 26:(seq - 1) * 26 + 26]
        e[1:1 + 10] = bytes(sl[0:10])          # chars 1..5
        e[11] = ATTR_LFN
        e[12] = 0x00
        e[13] = checksum
        e[14:14 + 12] = bytes(sl[10:22])       # chars 6..11
        e[26:26 + 2] = b"\x00\x00"             # first cluster = 0
        e[28:28 + 4] = bytes(sl[22:26])        # chars 12..13
        entries.append(bytes(e))
    entries.reverse()
    return entries


# Fixed timestamp. A build that runs twice on the same inputs should produce the
# same bytes — the CSVI container's checksum and any "did the image actually
# change" check both depend on it — and a wall-clock stamp in every directory
# entry would break that for no gain. 1980-01-01 00:00:00 is the FAT epoch.
FAT_EPOCH_DATE = (0 << 9) | (1 << 5) | 1
FAT_EPOCH_TIME = 0


def fat_date_time(deterministic=True):
    if deterministic:
        return FAT_EPOCH_DATE, FAT_EPOCH_TIME
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
    struct.pack_into("<HH", entry, 14, time16, date)   # create time/date
    struct.pack_into("<H", entry, 18, date)            # access date
    struct.pack_into("<H", entry, 20, (first_clus >> 16) & 0xFFFF)
    struct.pack_into("<HH", entry, 22, time16, date)   # write time/date
    struct.pack_into("<H", entry, 26, first_clus & 0xFFFF)
    struct.pack_into("<I", entry, 28, size)
    return bytes(entry)


# ── Directories ───────────────────────────────────────────────────────────

def collect_existing_shorts(f, bpb, dir_cluster):
    out = set()
    cluster = dir_cluster
    cb = cluster_bytes(bpb)
    while True:
        f.seek(cluster_to_offset(bpb, cluster))
        data = f.read(cb)
        for i in range(0, cb, 32):
            marker = data[i]
            if marker == 0x00:
                return out
            if marker == 0xE5:
                continue
            if data[i + 11] == ATTR_LFN:
                continue
            out.add(data[i:i + 11])
        nxt = read_fat_entry(f, bpb, cluster)
        if nxt >= EOC_MIN:
            return out
        cluster = nxt


def write_entries_to_dir(f, bpb, dir_cluster, entries):
    """Append an LFN+SFN run at the directory's true end, writing entries
    SEQUENTIALLY and spanning into a freshly-extended cluster when the current
    one fills.

    It must never leave a 0x00 slot BEFORE the new entries: 0x00 marks
    end-of-directory, so a gap in an earlier cluster makes readers stop and never
    see entries written into a later one — which is what used to silently drop
    every file added after a directory grew past a single cluster."""
    cb = cluster_bytes(bpb)
    n_slots = cb // 32

    # 1. Walk to the append point = first 0x00 (the true end of the directory).
    cluster = dir_cluster
    data = None
    slot = -1
    while True:
        f.seek(cluster_to_offset(bpb, cluster))
        data = bytearray(f.read(cb))
        found = -1
        for i in range(n_slots):
            if data[i * 32] == 0x00:
                found = i
                break
        if found != -1:
            slot = found
            break
        nxt = read_fat_entry(f, bpb, cluster)
        if nxt >= EOC_MIN:
            # Full cluster with no terminator — extend; the end is slot 0 of the new one.
            new_c = find_free_cluster(f, bpb)
            write_fat_entry(f, bpb, cluster, new_c)
            write_fat_entry(f, bpb, new_c, EOC)
            cluster = new_c
            data = bytearray(b"\x00" * cb)
            slot = 0
            break
        cluster = nxt

    # 2. Write one slot at a time, extending the chain when a cluster fills.
    #    Trailing slots stay 0x00, which is the terminator.
    for e in entries:
        if slot >= n_slots:
            f.seek(cluster_to_offset(bpb, cluster))
            f.write(data)
            nxt = read_fat_entry(f, bpb, cluster)
            if nxt >= EOC_MIN:
                new_c = find_free_cluster(f, bpb)
                write_fat_entry(f, bpb, cluster, new_c)
                write_fat_entry(f, bpb, new_c, EOC)
                cluster = new_c
                data = bytearray(b"\x00" * cb)
            else:
                cluster = nxt
                f.seek(cluster_to_offset(bpb, cluster))
                data = bytearray(f.read(cb))
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


def addfile(f, bpb, name, content, parent_cluster):
    data = content.encode("utf-8") if isinstance(content, str) else content
    cb = cluster_bytes(bpb)
    n_clusters = max(1, (len(data) + cb - 1) // cb)
    clusters = allocate_chain(f, bpb, n_clusters)
    for i, c in enumerate(clusters):
        chunk = data[i * cb:(i + 1) * cb]
        if len(chunk) < cb:
            chunk = chunk + b"\x00" * (cb - len(chunk))
        f.seek(cluster_to_offset(bpb, c))
        f.write(chunk)
    add_entry(f, bpb, parent_cluster, name, ATTR_ARCHIVE, clusters[0], len(data))
    return clusters[0]


def mkdir(f, bpb, name, parent_cluster):
    cb = cluster_bytes(bpb)
    new_c = allocate_chain(f, bpb, 1)[0]
    f.seek(cluster_to_offset(bpb, new_c))
    f.write(b"\x00" * cb)
    dot = build_sfn_entry(b".          ", ATTR_DIR, new_c, 0)
    # '..' points at the parent; a parent that IS the root encodes as 0.
    parent_for_dotdot = parent_cluster
    if parent_for_dotdot == bpb["root_clus"]:
        parent_for_dotdot = 0
    dotdot = build_sfn_entry(b"..         ", ATTR_DIR, parent_for_dotdot, 0)
    f.seek(cluster_to_offset(bpb, new_c))
    f.write(dot + dotdot)
    add_entry(f, bpb, parent_cluster, name, ATTR_DIR, new_c, 0)
    return new_c


# ── Reading ───────────────────────────────────────────────────────────────

def walk_dir(f, bpb, dir_cluster):
    """Yield (name, first_cluster, attr, size) for every live entry, resolving
    LFN runs so a long name comes back with its real spelling."""
    cb = cluster_bytes(bpb)
    cluster = dir_cluster
    lfn_parts = {}
    while True:
        f.seek(cluster_to_offset(bpb, cluster))
        data = f.read(cb)
        for i in range(0, cb, 32):
            e = data[i:i + 32]
            if e[0] == 0x00:
                return
            if e[0] == 0xE5:
                lfn_parts = {}
                continue
            if e[11] == ATTR_LFN:
                seq = e[0] & 0x1F
                raw = e[1:11] + e[14:26] + e[28:32]
                lfn_parts[seq] = raw.decode("utf-16-le", "ignore").split("\x00")[0]
                continue
            if e[11] & ATTR_VOLUME_ID:
                # The volume label lives in the root as a directory entry. It is
                # not a file, and the kernel's readdir skips it too
                # (kernel/fs/fat32.cst:2221) — so neither side ever sees a
                # phantom "CAUSTICOS" in a listing.
                lfn_parts = {}
                continue
            long_name = "".join(lfn_parts[k] for k in sorted(lfn_parts)) if lfn_parts else ""
            lfn_parts = {}
            base = e[:8].decode("ascii", "ignore").rstrip()
            ext = e[8:11].decode("ascii", "ignore").rstrip()
            short = base + ("." + ext if ext else "")
            name = long_name or short
            clus = struct.unpack_from("<H", e, 26)[0] | (struct.unpack_from("<H", e, 20)[0] << 16)
            size = struct.unpack_from("<I", e, 28)[0]
            yield (name, clus, e[11], size)
        nxt = read_fat_entry(f, bpb, cluster)
        if nxt >= EOC_MIN:
            return
        cluster = nxt


def dir_find(f, bpb, dir_cluster, name):
    """(first_cluster, attr, size) for `name`, case-insensitively, or None."""
    want = name.upper()
    for nm, clus, attr, size in walk_dir(f, bpb, dir_cluster):
        if nm.upper() == want:
            return (clus, attr, size)
    return None


def read_file(f, bpb, first_cluster, size):
    cb = cluster_bytes(bpb)
    out = bytearray()
    cluster = first_cluster
    while len(out) < size and cluster >= 2:
        f.seek(cluster_to_offset(bpb, cluster))
        out.extend(f.read(cb))
        nxt = read_fat_entry(f, bpb, cluster)
        if nxt >= EOC_MIN:
            break
        cluster = nxt
    return bytes(out[:size])


def lookup(f, bpb, path):
    """Walk an absolute-ish path. Returns (first_cluster, attr, size) or None."""
    parts = [p for p in path.split("/") if p]
    cluster = bpb["root_clus"]
    attr = ATTR_DIR
    size = 0
    for comp in parts:
        found = dir_find(f, bpb, cluster, comp)
        if found is None:
            return None
        cluster, attr, size = found
    return (cluster, attr, size)


def resolve_path(f, bpb, path, make_dirs):
    """Split on '/' and walk it for real, so "var/wm/pointer.cst" becomes a file
    "pointer.cst" inside a directory "wm" inside a directory "var" — not one root
    entry whose name contains slashes. The kernel's path_lookup walks components;
    a flat entry is invisible to it, which is why seeded nested fixtures used to
    read back as E_NOENT.

    Returns (parent_cluster, leaf_name)."""
    parts = [p for p in path.split("/") if p]
    if not parts:
        raise ValueError("empty path")
    cluster = bpb["root_clus"]
    for comp in parts[:-1]:
        found = dir_find(f, bpb, cluster, comp)
        if found is None:
            if not make_dirs:
                raise ValueError("no such directory: {} (in {})".format(comp, path))
            cluster = mkdir(f, bpb, comp, cluster)
        else:
            if not (found[1] & ATTR_DIR):
                raise ValueError("not a directory: {} (in {})".format(comp, path))
            cluster = found[0]
    return cluster, parts[-1]


# ── Formatting ────────────────────────────────────────────────────────────

def fat_size_for(total_sectors, bps=512, spc=1, rsvd=32, nfats=2):
    """Sectors per FAT: the smallest that can address every cluster the leftover
    data area yields. Solved by iteration rather than the classic closed form,
    because the closed form is an approximation that can come out one short and
    the failure mode is a volume whose last clusters have no FAT entry."""
    fat_sz = 1
    while True:
        data_secs = total_sectors - rsvd - nfats * fat_sz
        if data_secs <= 0:
            raise ValueError("volume too small for any FAT")
        ccount = data_secs // spc
        need_bytes = (ccount + 2) * 4          # entries 0 and 1 are reserved
        if fat_sz * bps >= need_bytes:
            return fat_sz
        fat_sz += (need_bytes - fat_sz * bps + bps - 1) // bps


def format_fat32(buf, total_sectors, label="CAUSTICOS", volume_id=0x43415553):
    """Lay a fresh FAT32 into `buf` (a bytearray of at least total_sectors*512).

    Geometry is fixed at 512-byte sectors and one sector per cluster: it matches
    the sector size every backend here reports, it wastes nothing on small files
    (a 40-byte config costs 512 bytes, not 4 KiB), and it keeps the legal minimum
    volume as small as FAT32 allows. Every field below is what kernel/fs/fat32.cst
    checks on mount, in the order it checks them."""
    bps, spc, rsvd, nfats = 512, 1, 32, 2
    if total_sectors < MIN_SECTORS:
        raise ValueError(
            "{} sectors is below the FAT32 minimum of {} ({:.1f} MiB): "
            "fewer than 65525 clusters is a FAT16 by definition and the kernel "
            "rejects it".format(total_sectors, MIN_SECTORS, MIN_SECTORS * 512 / 1048576))
    fat_sz = fat_size_for(total_sectors, bps, spc, rsvd, nfats)
    ccount = (total_sectors - rsvd - nfats * fat_sz) // spc
    if ccount < 65525:
        raise ValueError("cluster_count {} < 65525 after layout".format(ccount))

    need = total_sectors * bps
    if len(buf) < need:
        buf.extend(b"\x00" * (need - len(buf)))

    boot = bytearray(512)
    boot[0:3] = b"\xEB\x58\x90"                      # jmp short +0x58; nop
    boot[3:11] = b"CAUSTIC "                         # OEM name
    struct.pack_into("<H", boot, 0x0B, bps)
    boot[0x0D] = spc
    struct.pack_into("<H", boot, 0x0E, rsvd)
    boot[0x10] = nfats
    struct.pack_into("<H", boot, 0x11, 0)            # root_ent_cnt: 0 on FAT32
    struct.pack_into("<H", boot, 0x13, 0)            # tot_sec_16:   0 on FAT32
    boot[0x15] = 0xF8                                # media: fixed disk
    struct.pack_into("<H", boot, 0x16, 0)            # fat_sz_16:    0 on FAT32
    struct.pack_into("<H", boot, 0x18, 63)           # sectors per track (CHS legacy)
    struct.pack_into("<H", boot, 0x1A, 255)          # heads          (CHS legacy)
    struct.pack_into("<I", boot, 0x1C, 0)            # hidden sectors: unpartitioned
    struct.pack_into("<I", boot, 0x20, total_sectors)
    struct.pack_into("<I", boot, 0x24, fat_sz)
    struct.pack_into("<H", boot, 0x28, 0)            # ext_flags: all FATs mirrored
    struct.pack_into("<H", boot, 0x2A, 0)            # fs_ver: must be 0
    struct.pack_into("<I", boot, 0x2C, 2)            # root cluster
    struct.pack_into("<H", boot, 0x30, 1)            # FSInfo sector
    struct.pack_into("<H", boot, 0x32, 6)            # backup boot sector
    boot[0x40] = 0x80                                # drive number
    boot[0x42] = 0x29                                # extended boot signature
    struct.pack_into("<I", boot, 0x43, volume_id)
    boot[0x47:0x52] = label.upper().ljust(11)[:11].encode("ascii")
    boot[0x52:0x5A] = b"FAT32   "
    struct.pack_into("<H", boot, 0x1FE, 0xAA55)
    buf[0:512] = boot

    fsinfo = bytearray(512)
    struct.pack_into("<I", fsinfo, 0x000, 0x41615252)     # lead signature
    struct.pack_into("<I", fsinfo, 0x1E4, 0x61417272)     # struct signature
    struct.pack_into("<I", fsinfo, 0x1E8, ccount - 1)     # free count (root uses one)
    struct.pack_into("<I", fsinfo, 0x1EC, 3)              # next free hint
    struct.pack_into("<I", fsinfo, 0x1FC, 0xAA550000)     # trail signature
    buf[512:1024] = fsinfo

    # Backup boot sector + its FSInfo, at the offset the BPB advertises.
    buf[6 * bps:6 * bps + 512] = boot
    buf[7 * bps:7 * bps + 512] = fsinfo

    # Seed both FATs: entry 0 is the media descriptor, entry 1 the end marker,
    # entry 2 the root directory's single-cluster chain.
    for fat_idx in range(nfats):
        base = (rsvd + fat_idx * fat_sz) * bps
        struct.pack_into("<I", buf, base + 0, 0x0FFFFFF8)
        struct.pack_into("<I", buf, base + 4, 0x0FFFFFFF)
        struct.pack_into("<I", buf, base + 8, EOC)

    return dict(bps=bps, spc=spc, rsvd=rsvd, nfats=nfats,
                fat_sz=fat_sz, root_clus=2, tot_sec=total_sectors,
                cluster_count=ccount)


def new_volume(total_sectors, label="CAUSTICOS"):
    """A freshly formatted volume, ready to write into: (BytesIO view, bpb)."""
    buf = bytearray(total_sectors * SECTOR)
    format_fat32(buf, total_sectors, label)
    f = io.BytesIO(buf)
    # BytesIO copies its initialiser, so hand back the object we actually write
    # through — the caller wants the bytes that come out of getbuffer().
    bpb = read_bpb(f)
    # The label belongs in the root directory as well as in the BPB. Without the
    # directory entry fsck.fat reports "no volume label in root directory" and
    # offers to strip the one in the boot sector; the kernel's readdir skips
    # ATTR_VOLUME_ID entries, so this costs nothing on the guest side.
    write_entries_to_dir(f, bpb, bpb["root_clus"],
                         [build_sfn_entry(label.upper().ljust(11)[:11].encode("ascii"),
                                          ATTR_VOLUME_ID, 0, 0)])
    return f, bpb


def open_image(path, writable=False):
    """Load a whole image into memory. Volumes here are tens of MiB and every
    operation touches scattered offsets, so paging one through a file handle
    buys nothing over holding it."""
    with open(path, "rb") as fh:
        data = bytearray(fh.read())
    f = io.BytesIO(data)
    return f, read_bpb(f)


def count_free_clusters(f, bpb):
    """Scan the FAT for entries still at 0. Exact, and cheap enough at this
    scale — one linear pass over the in-memory FAT."""
    fat_base = bpb["rsvd"] * bpb["bps"]
    n = cluster_count(bpb) + 2
    f.seek(fat_base)
    fat = f.read(n * 4)
    free = 0
    for c in range(2, n):
        if struct.unpack_from("<I", fat, c * 4)[0] & 0x0FFFFFFF == 0:
            free += 1
    return free


def finalize(f, bpb):
    """Bring FSInfo back in line with the FAT before the image is written out.

    The free-cluster count is set at format time and nothing updates it as files
    are added, so an image saved without this reports a stale figure — fsck.fat
    flags it ("Free cluster summary wrong") and offers to correct it, which is a
    volume that is subtly wrong even though every file in it reads back fine."""
    free = count_free_clusters(f, bpb)
    fsinfo_off = 1 * bpb["bps"]
    f.seek(fsinfo_off + 0x1E8)
    f.write(struct.pack("<I", free))
    f.seek(fsinfo_off + 0x1EC)
    f.write(struct.pack("<I", _next_free))
    # Keep the backup FSInfo (sector 7) in step with the primary.
    f.seek(fsinfo_off)
    primary = f.read(512)
    f.seek(7 * bpb["bps"])
    f.write(primary)
    return free


def save_image(f, path, bpb=None):
    if bpb is not None:
        finalize(f, bpb)
    with open(path, "wb") as fh:
        fh.write(f.getbuffer())


# ── Bulk operations ───────────────────────────────────────────────────────

def add_path(f, bpb, guest_path, content):
    """Create `guest_path` with `content` (str or bytes), making parents."""
    parent, leaf = resolve_path(f, bpb, guest_path, make_dirs=True)
    return addfile(f, bpb, leaf, content, parent)


def make_dir(f, bpb, guest_path):
    """mkdir -p for a guest path. Returns the leaf's cluster."""
    parts = [p for p in guest_path.split("/") if p]
    cluster = bpb["root_clus"]
    for comp in parts:
        found = dir_find(f, bpb, cluster, comp)
        if found is None:
            cluster = mkdir(f, bpb, comp, cluster)
        else:
            if not (found[1] & ATTR_DIR):
                raise ValueError("not a directory: {} (in {})".format(comp, guest_path))
            cluster = found[0]
    return cluster


def extract_tree(f, bpb, dest_dir, cluster=None, prefix=""):
    """Write the volume's contents out under dest_dir. Returns a list of
    (guest_path, size) — the host half of a round-trip check."""
    import os
    if cluster is None:
        cluster = bpb["root_clus"]
    out = []
    for name, clus, attr, size in walk_dir(f, bpb, cluster):
        if name in (".", ".."):
            continue
        guest = prefix + "/" + name
        if attr & ATTR_DIR:
            os.makedirs(os.path.join(dest_dir, guest.lstrip("/")), exist_ok=True)
            out.extend(extract_tree(f, bpb, dest_dir, clus, guest))
        else:
            host = os.path.join(dest_dir, guest.lstrip("/"))
            os.makedirs(os.path.dirname(host), exist_ok=True)
            with open(host, "wb") as fh:
                fh.write(read_file(f, bpb, clus, size))
            out.append((guest, size))
    return out


def list_tree(f, bpb, cluster=None, prefix=""):
    """Every file in the volume as (guest_path, size), depth-first, sorted."""
    if cluster is None:
        cluster = bpb["root_clus"]
    out = []
    for name, clus, attr, size in sorted(walk_dir(f, bpb, cluster)):
        if name in (".", ".."):
            continue
        guest = prefix + "/" + name
        if attr & ATTR_DIR:
            out.append((guest + "/", 0))
            out.extend(list_tree(f, bpb, clus, guest))
        else:
            out.append((guest, size))
    return out


def _cli():
    import argparse
    ap = argparse.ArgumentParser(description="inspect a FAT32 image")
    ap.add_argument("image")
    sub = ap.add_subparsers(dest="op", required=True)
    sub.add_parser("ls", help="list every file")
    g = sub.add_parser("get", help="extract one file")
    g.add_argument("path")
    g.add_argument("out")
    x = sub.add_parser("extract", help="extract the whole tree")
    x.add_argument("dest")
    sub.add_parser("info", help="show geometry")
    a = ap.parse_args()

    f, bpb = open_image(a.image)
    if a.op == "info":
        print("bytes/sector    {}".format(bpb["bps"]))
        print("sectors/cluster {}".format(bpb["spc"]))
        print("reserved        {}".format(bpb["rsvd"]))
        print("FATs            {} x {} sectors".format(bpb["nfats"], bpb["fat_sz"]))
        print("total sectors   {} ({:.1f} MiB)".format(
            bpb["tot_sec"], bpb["tot_sec"] * bpb["bps"] / 1048576))
        print("clusters        {}".format(cluster_count(bpb)))
        print("root cluster    {}".format(bpb["root_clus"]))
    elif a.op == "ls":
        for path, size in list_tree(f, bpb):
            print("{:>10}  {}".format("" if path.endswith("/") else size, path))
    elif a.op == "get":
        found = lookup(f, bpb, a.path)
        if found is None:
            sys.exit("not found: {}".format(a.path))
        clus, attr, size = found
        if attr & ATTR_DIR:
            sys.exit("is a directory: {}".format(a.path))
        with open(a.out, "wb") as fh:
            fh.write(read_file(f, bpb, clus, size))
        print("{} -> {} ({} bytes)".format(a.path, a.out, size))
    elif a.op == "extract":
        files = extract_tree(f, bpb, a.dest)
        print("{} files -> {}".format(len(files), a.dest))


if __name__ == "__main__":
    _cli()
