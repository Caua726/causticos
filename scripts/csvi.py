#!/usr/bin/env python3
"""csvi.py — CSVI v1: the sparse container the ISO carries the live root in.

A 33 MiB root holding ~2.2 MiB of programs is 93% zeros. CSVI stores only the
sectors that carry data, each tagged with its LBA; the record region can also
be compressed as a raw DEFLATE stream. The kernel bounds decoded output by the
record count in the header and uses its own heap for decoder allocations.

Format, little-endian throughout:

  Header — 64 bytes at offset 0
    off  size  field
      0     4  magic          "CSVI" (u32 0x49565343)
      4     4  version        1
      8     8  volume_bytes   size of the EXPANDED volume; == sectors * sector_size
     16     8  volume_sectors sectors in the expanded volume
     24     4  sector_size    512 (v1 accepts only 512)
     28     4  flags          bit 0 = FAT32; bit 1 = raw DEFLATE; bits 2..31 reserved
     32     8  record_count   number of decoded records
     40     8  records_offset MUST be 64 in v1
     48     4  checksum       FNV-1a 32 over decoded (uncompressed) records
     52     4  reserved0      0
     56     8  reserved1      0

  Records — record_count of them, each 8 + sector_size bytes when decoded
    off  size  field
      0     8  lba            0-based sector index in the expanded volume
      8   512  data

  With bit 1 clear, records are stored contiguously after the header. With bit
  1 set, the entire remaining file is one raw DEFLATE stream of those records.

  Invariants, all checked on both sides:
    - uncompressed file_size == records_offset + record_count * (8 + sector_size)
    - compressed stream consumes the remaining file and expands to exactly
      record_count * (8 + sector_size) bytes
    - checksum is FNV-1a 32 over the decoded record region
    - lba strictly ascending across records: no duplicates, no reordering
    - lba < volume_sectors for every record
    - any sector not named by a record is zero in the expanded volume

Why one record per sector rather than run-length extents: extents would save
about 64 KB on a 2 MB container (the 8-byte LBAs) and buy a variable-length
bounds check inside the kernel. Per-sector records keep expansion simple. The
uncompressed size follows directly from the header; compressed streams instead
must match that exact decoded size and checksum.

Why FNV-1a 32 rather than a cryptographic hash: it is four lines of Caustic and
it catches the two failure modes that actually happen to a file the bootloader
read off optical media — truncation and garbling. Limine's own `#blake2b` suffix
in `module_path` is the answer if Secure Boot ever enters the picture.
"""

import argparse
import struct
import sys

MAGIC = 0x49565343          # "CSVI" little-endian
VERSION = 1
HEADER_BYTES = 64
SECTOR = 512
FLAG_FAT32 = 1
# bit 1: the RECORD REGION is a raw DEFLATE stream (no zlib or gzip wrapper —
# the CSVI header already carries the length and the checksum, so a second
# framing would only repeat them).
#
# Deflate rather than xz or zstd: the shared decoder supports a caller-provided
# allocator, so the kernel can use its heap instead of calling an OS mmap API.
# The header stays plain because the kernel needs the output size before it can
# allocate. The compressed region is raw DEFLATE (no zlib/gzip wrapper).
#
# The checksum covers the UNCOMPRESSED records, so it verifies what was packed
# rather than the compressed bytes that happened to arrive.
FLAG_DEFLATE = 2

FNV_OFFSET = 0x811C9DC5
FNV_PRIME = 0x01000193


def fnv1a32(data):
    h = FNV_OFFSET
    for b in data:
        h ^= b
        h = (h * FNV_PRIME) & 0xFFFFFFFF
    return h

def _inflate_records(region, expected):
    """Inflate one exact raw-DEFLATE record stream without unbounded growth."""
    import zlib
    decoder = zlib.decompressobj(-15)
    try:
        records = decoder.decompress(region, expected + 1)
    except zlib.error as err:
        raise ValueError("invalid raw DEFLATE stream: {}".format(err)) from None
    if len(records) > expected or decoder.unconsumed_tail:
        raise ValueError("raw DEFLATE stream expands beyond {} bytes".format(expected))
    if not decoder.eof:
        raise ValueError("incomplete raw DEFLATE stream")
    if decoder.unused_data:
        raise ValueError("trailing bytes after raw DEFLATE stream")
    return records


def pack(image, sector_size=SECTOR, flags=FLAG_FAT32, compress=False):
    """Compact a raw volume image into a CSVI container."""
    if len(image) % sector_size:
        raise ValueError("image of {} bytes is not a whole number of {}-byte sectors"
                         .format(len(image), sector_size))
    total = len(image) // sector_size
    zero = bytes(sector_size)

    records = bytearray()
    count = 0
    for lba in range(total):
        chunk = bytes(image[lba * sector_size:(lba + 1) * sector_size])
        if chunk == zero:
            continue
        records += struct.pack("<Q", lba)
        records += chunk
        count += 1

    checksum = fnv1a32(records)
    if compress:
        import zlib
        # wbits=-15: raw deflate, no wrapper. Level 9 because this runs once at
        # build time and the size is the entire point.
        co = zlib.compressobj(9, zlib.DEFLATED, -15)
        records = co.compress(bytes(records)) + co.flush()
        flags = flags | FLAG_DEFLATE

    header = bytearray(HEADER_BYTES)
    struct.pack_into("<I", header, 0, MAGIC)
    struct.pack_into("<I", header, 4, VERSION)
    struct.pack_into("<Q", header, 8, total * sector_size)
    struct.pack_into("<Q", header, 16, total)
    struct.pack_into("<I", header, 24, sector_size)
    struct.pack_into("<I", header, 28, flags)
    struct.pack_into("<Q", header, 32, count)
    struct.pack_into("<Q", header, 40, HEADER_BYTES)
    struct.pack_into("<I", header, 48, checksum)
    return bytes(header) + bytes(records)


def parse_header(blob):
    if len(blob) < HEADER_BYTES:
        raise ValueError("shorter than a header ({} bytes)".format(len(blob)))
    magic, version = struct.unpack_from("<II", blob, 0)
    if magic != MAGIC:
        raise ValueError("bad magic 0x{:08X}, wanted 0x{:08X} (\"CSVI\")".format(magic, MAGIC))
    if version != VERSION:
        raise ValueError("version {}, this tool speaks {}".format(version, VERSION))
    vol_bytes, vol_sectors = struct.unpack_from("<QQ", blob, 8)
    sector_size, flags = struct.unpack_from("<II", blob, 24)
    count, rec_off = struct.unpack_from("<QQ", blob, 32)
    checksum = struct.unpack_from("<I", blob, 48)[0]

    if sector_size != SECTOR:
        raise ValueError("sector_size {}, v1 accepts only {}".format(sector_size, SECTOR))
    if vol_sectors <= 0:
        raise ValueError("volume_sectors is {}".format(vol_sectors))
    if vol_bytes != vol_sectors * sector_size:
        raise ValueError("volume_bytes {} != volume_sectors {} * {}"
                         .format(vol_bytes, vol_sectors, sector_size))
    if rec_off != HEADER_BYTES:
        raise ValueError("records_offset {}, v1 requires {}".format(rec_off, HEADER_BYTES))
    if flags & ~(FLAG_FAT32 | FLAG_DEFLATE):
        raise ValueError("reserved flag bits set: 0x{:08X}".format(flags))

    if count > vol_sectors:
        raise ValueError("record_count {} exceeds volume_sectors {}"
                         .format(count, vol_sectors))
    stride = 8 + sector_size
    want = rec_off + count * stride
    if flags & FLAG_DEFLATE:
        recs = _inflate_records(blob[rec_off:], count * stride)
        if len(recs) != count * stride:
            raise ValueError("decompressed to {} bytes, header describes {} "
                             "({} records x {})".format(len(recs), count * stride, count, stride))
    else:
        recs = blob[rec_off:]
        if len(blob) != want:
            raise ValueError("file is {} bytes, header describes {} "
                             "({} records x {} + {} header)"
                             .format(len(blob), want, count, stride, rec_off))
    actual = fnv1a32(recs)
    if actual != checksum:
        raise ValueError("checksum mismatch: stored 0x{:08X}, computed 0x{:08X}"
                         .format(checksum, actual))

    return dict(volume_bytes=vol_bytes, volume_sectors=vol_sectors,
                sector_size=sector_size, flags=flags, record_count=count,
                records_offset=rec_off, checksum=checksum)


def records_of(blob, hdr):
    """The record region, decompressed if the header says it is compressed.

    Everything that walks records goes through here, so a compressed container
    is not a second code path — only a different way of getting to the same
    bytes."""
    region = blob[hdr["records_offset"]:]
    if hdr["flags"] & FLAG_DEFLATE:
        stride = 8 + hdr["sector_size"]
        return _inflate_records(region, hdr["record_count"] * stride)
    return region


def iter_records(blob, hdr):
    """Yield (lba, data), enforcing the ordering invariant as it goes."""
    stride = 8 + hdr["sector_size"]
    prev = -1
    recs = records_of(blob, hdr)
    off = 0
    for i in range(hdr["record_count"]):
        lba = struct.unpack_from("<Q", recs, off)[0]
        if lba <= prev:
            raise ValueError("record {}: lba {} not greater than previous {} "
                             "(records must be strictly ascending)".format(i, lba, prev))
        if lba >= hdr["volume_sectors"]:
            raise ValueError("record {}: lba {} outside a {}-sector volume"
                             .format(i, lba, hdr["volume_sectors"]))
        prev = lba
        yield lba, recs[off + 8:off + stride]
        off += stride


def expand(blob):
    """Rebuild the full raw volume image. The inverse of pack()."""
    hdr = parse_header(blob)
    out = bytearray(hdr["volume_bytes"])
    for lba, data in iter_records(blob, hdr):
        out[lba * hdr["sector_size"]:(lba + 1) * hdr["sector_size"]] = data
    return bytes(out)


def _runs(blob, hdr):
    """Collapse the record LBAs into contiguous runs, for display only."""
    runs = []
    for lba, _ in iter_records(blob, hdr):
        if runs and runs[-1][1] + 1 == lba:
            runs[-1][1] = lba
        else:
            runs.append([lba, lba])
    return runs


def _cli():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="op", required=True)

    p = sub.add_parser("pack", help="raw volume image -> CSVI container")
    p.add_argument("image")
    p.add_argument("out")
    p.add_argument("--compress", action="store_true",
                   help="raw DEFLATE-compress the sparse record region")

    e = sub.add_parser("expand", help="CSVI container -> raw volume image")
    e.add_argument("csvi")
    e.add_argument("out")

    i = sub.add_parser("info", help="dump the header and verify every invariant")
    i.add_argument("csvi")
    i.add_argument("--runs", action="store_true", help="also list contiguous LBA runs")

    a = ap.parse_args()
    try:
        return _run(a)
    except ValueError as err:
        # A malformed container is a data problem, not a crash. Report it the
        # way the kernel's expander will — say what was wrong — and exit 1,
        # rather than handing the user a Python traceback.
        print("{}: INVALID: {}".format(a.op, err), file=sys.stderr)
        return 1


def _run(a):
    if a.op == "pack":
        with open(a.image, "rb") as fh:
            image = fh.read()
        blob = pack(image, compress=a.compress)
        with open(a.out, "wb") as fh:
            fh.write(blob)
        hdr = parse_header(blob)
        ratio = 100.0 * len(blob) / len(image) if image else 0
        print("{} -> {}".format(a.image, a.out))
        print("  volume   {} sectors ({:.1f} MiB)".format(
            hdr["volume_sectors"], hdr["volume_bytes"] / 1048576))
        print("  records  {} ({:.1f}% of sectors carry data)".format(
            hdr["record_count"], 100.0 * hdr["record_count"] / hdr["volume_sectors"]))
        print("  size     {} bytes ({:.1f} KiB, {:.2f}% of the raw image)".format(
            len(blob), len(blob) / 1024, ratio))
        return 0

    if a.op == "expand":
        with open(a.csvi, "rb") as fh:
            blob = fh.read()
        image = expand(blob)
        with open(a.out, "wb") as fh:
            fh.write(image)
        print("{} -> {} ({} bytes)".format(a.csvi, a.out, len(image)))
        return 0

    if a.op == "info":
        with open(a.csvi, "rb") as fh:
            blob = fh.read()
        hdr = parse_header(blob)
        # Validate the record stream BEFORE printing a reassuring header: a
        # container whose LBAs are out of order is invalid, and saying
        # "checksum ok" first reads like a pass.
        runs = _runs(blob, hdr)
        print("magic           CSVI v{}".format(VERSION))
        print("volume          {} sectors x {} B = {} bytes ({:.1f} MiB)".format(
            hdr["volume_sectors"], hdr["sector_size"], hdr["volume_bytes"],
            hdr["volume_bytes"] / 1048576))
        print("flags           0x{:08X}{}".format(
            hdr["flags"], "  (FAT32)" if hdr["flags"] & FLAG_FAT32 else ""))
        print("records         {} x {} B = {} bytes".format(
            hdr["record_count"], 8 + hdr["sector_size"],
            hdr["record_count"] * (8 + hdr["sector_size"])))
        print("checksum        0x{:08X}  ok".format(hdr["checksum"]))
        print("file size       {} bytes  ok".format(len(blob)))
        try:
            runs = _runs(blob, hdr)
        except ValueError as err:
            print("INVALID: {}".format(err), file=sys.stderr)
            return 1
        print("lba ordering    strictly ascending, all in range  ok")
        print("contiguous runs {}".format(len(runs)))
        if a.runs:
            for lo, hi in runs:
                print("  {:>8} .. {:<8} ({} sectors)".format(lo, hi, hi - lo + 1))
        return 0


if __name__ == "__main__":
    sys.exit(_cli())
