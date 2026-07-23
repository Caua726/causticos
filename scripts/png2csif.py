#!/usr/bin/env python3
# png2csif.py — host encoder for the Caustic Standard Image Format (CSIF).
#
# Writes a spec-conformant BASELINE (profile 0) CSIF: a 64-byte header, a
# 32-byte-per-record chunk directory, and CRC32-protected chunks
# (ILIM / IHDR / ICOL / ICOD / IDAT / IEND), carrying one of two lossless codecs:
#   codec 0 = RAW  (interleaved, byte-aligned identity)
#   codec 1 = QOI  (run + 64-index + delta)
# It is the *reference* the in-OS Caustic decoder (std/causticos/img/) must match
# byte-for-byte; it also round-trips itself (--selftest) so the byte layout is
# pinned in code, not just prose. See docs/CSIF_FORMAT.md.
#
# Spec reconciliation note: §1 (container) is authoritative for structure, so the
# CICP colour block lives in its own ICOL chunk (not inside IHDR as §2.1's prose
# suggests). Flagged in docs for a later spec fix.
#
# Usage:
#   png2csif.py <in.png|in.ppm> <out.csif> [--codec raw|qoi]
#   png2csif.py --test  <out.csif> [--codec raw|qoi]   # synthesize a test image
#   png2csif.py --selftest                              # encode+decode round-trip

import sys, struct, zlib

# ------------------------------------------------------------------ CRC / le
def crc32(b):                       # CRC32-IEEE, poly 0xEDB88320, init/final 0xFFFFFFFF
    return zlib.crc32(b) & 0xFFFFFFFF

def u8(v):  return struct.pack('<B', v & 0xFF)
def u16(v): return struct.pack('<H', v & 0xFFFF)
def u32(v): return struct.pack('<I', v & 0xFFFFFFFF)
def u64(v): return struct.pack('<Q', v & 0xFFFFFFFFFFFFFFFF)
def i32(v): return struct.pack('<i', v)
def f32(v): return struct.pack('<f', v)

def pad8(n): return (-n) % 8       # bytes needed to reach the next multiple of 8

# ------------------------------------------------------------------ constants
MAGIC = b'CSIF'
PROBE = bytes([0x89, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])

# chunk flag bits (§1.4)
F_CRITICAL, F_PUBLIC, F_SAFE_COPY = 1 << 0, 1 << 1, 1 << 2
F_SINGLETON, F_PER_ITEM, F_PAYLOAD = 1 << 3, 1 << 4, 1 << 5

# ------------------------------------------------------------------ chunk payloads
def ihdr_payload(w, h, nchan):
    has_alpha = (nchan == 4)
    color_model = 3 if has_alpha else 2            # RGBA=3, RGB=2
    alpha_mode  = 1 if has_alpha else 0            # STRAIGHT / NONE
    p  = u64(0)                                     # item_id
    p += u32(w) + u32(h) + u32(1)                  # width, height, depth
    p += u8(0)                                      # sample_format = UINT8
    p += u8(0)                                      # sample_endian = little
    p += u8(8)                                      # bit_depth
    p += u8(0)                                      # sample_layout = FLAT
    p += u8(color_model)
    p += u8(nchan)                                  # component_count
    p += u8(1) + u8(1)                             # chroma h/v subsample = 4:4:4
    p += u8(0)                                      # chroma_sample_position = N/A
    p += u8(alpha_mode)
    p += u8(0)                                      # orientation = identity
    p += u8(0)                                      # reserved0
    # display_window + data_window: Rect{x:i32,y:i32,w:u32,h:u32}
    p += i32(0) + i32(0) + u32(w) + u32(h)
    p += i32(0) + i32(0) + u32(w) + u32(h)
    p += struct.pack('<iI', 1, 1)                  # pixel_aspect_ratio {num,den}
    p += f32(0.0)                                   # intensity_target_nits (0 = std ref)
    assert len(p) == 0x4C, len(p)
    return p

def ilim_payload(w, h):
    ceils = [
        1 << 16, 1 << 16,          # max_width, max_height
        1 << 30, 1 << 24,          # max_pixels, max_tile_pixels
        1 << 30,                   # max_alloc_bytes
        16, 16,                    # max_components, max_aux_channels
        1 << 30,                   # max_chunk_size
        4096, 1 << 20,             # max_items, max_tiles
        16, 65536,                 # max_mip_levels, max_frames
        16, 16, 16,                # ref_slots, deriv_depth, deriv_fanin
        1 << 16,                   # max_entropy_streams
        1 << 20,                   # max_ma_tree_nodes
        65536,                     # max_palette_entries
        1 << 16, 1 << 16, 1 << 20, # patches, splines, spline_points
        1 << 24, 256,              # max_metadata_bytes, max_manifests
    ]
    assert len(ceils) == 23, len(ceils)
    return b''.join(u64(c) for c in ceils)

def icol_payload():
    # item_id(8) + CICP block(8): sRGB/BT.709 primaries, sRGB transfer, Identity matrix.
    p  = u64(0)
    p += u8(0)     # color_authority = CICP
    p += u8(1)     # color_primaries = BT.709 (sRGB gamut)
    p += u8(13)    # transfer_function = IEC 61966-2-1 sRGB
    p += u8(0)     # matrix_coefficients = Identity (RGB)
    p += u8(1)     # full_range
    p += u8(0)     # chroma_sample_position = N/A
    p += u8(1) + u8(1)   # h/v subsample = 4:4:4
    return p

def icod_payload(codec_id, params):
    p  = u64(0)                    # item_id
    p += u16(codec_id) + u16(1)   # codec_id, codec_version
    p += u8(1)                     # is_lossless
    p += u8(0)                     # color_transform = NONE
    p += u8(0)                     # supercompress_id = none
    p += u8(0)                     # cross_tile_prediction = NONE
    p += u32(0) + u32(0)          # tile_w, tile_h (0 = single tile)
    p += u32(1) + u32(1)          # n_tiles_x, n_tiles_y
    p += u32(1) + u32(1)          # n_resolution_levels, n_quality_layers
    p += u32(0)                    # progression_order = NONE
    p += u16(3)                    # entropy_method_id = raw (RAW/QOI carry no entropy stream)
    p += u8(0) + u8(0)            # sub_image_count, reserved0
    assert len(p) == 0x30, len(p)
    p += u32(len(params)) + params
    return p

def idat_payload(codec_bytes):
    p  = u64(0)                    # item_id
    p += u32(0)                    # idat_index
    p += u32(0)                    # coord_kind = WHOLE
    p += u32(0) * 0 + b''.join(u32(0) for _ in range(4))  # coords[4]
    p += codec_bytes
    return p

# ------------------------------------------------------------------ codecs
def raw_params():
    # pixel_layout=1 (interleaved), sample_pack=0 (byte-aligned), row_alignment=1, reserved[5]
    return u8(1) + u8(0) + u8(1) + b'\x00' * 5

def raw_encode(px, w, h, nchan):
    # interleaved, byte-aligned, row_alignment=1 → the pixel bytes verbatim.
    return bytes(px)

def qoi_params(nchan):
    return u8(1 if nchan == 4 else 0) + u8(0) + u16(0)   # has_alpha, premul, reserved

def _sw8(x):                       # C signed-char wrap of a byte difference
    x &= 0xFF
    return x - 256 if x >= 128 else x

def qoi_encode(px, w, h, nchan):
    out = bytearray()
    index = [(0, 0, 0, 0)] * 64
    pr, pg, pb, pa = 0, 0, 0, 255
    run = 0
    n = w * h
    for i in range(n):
        base = i * nchan
        r, g, b = px[base], px[base + 1], px[base + 2]
        a = px[base + 3] if nchan == 4 else 255
        if (r, g, b, a) == (pr, pg, pb, pa):
            run += 1
            if run == 62:
                out.append(0xC0 | (run - 1)); run = 0
        else:
            if run > 0:
                out.append(0xC0 | (run - 1)); run = 0
            hsh = (r * 3 + g * 5 + b * 7 + a * 11) & 63
            if index[hsh] == (r, g, b, a):
                out.append(hsh)                         # QOI_OP_INDEX (0b00)
            else:
                index[hsh] = (r, g, b, a)
                if a == pa:
                    vr, vg, vb = _sw8(r - pr), _sw8(g - pg), _sw8(b - pb)
                    vg_r, vg_b = vr - vg, vb - vg
                    if -2 <= vr <= 1 and -2 <= vg <= 1 and -2 <= vb <= 1:
                        out.append(0x40 | ((vr + 2) << 4) | ((vg + 2) << 2) | (vb + 2))
                    elif -32 <= vg <= 31 and -8 <= vg_r <= 7 and -8 <= vg_b <= 7:
                        out.append(0x80 | (vg + 32))
                        out.append(((vg_r + 8) << 4) | (vg_b + 8))
                    else:
                        out += bytes([0xFE, r, g, b])
                else:
                    out += bytes([0xFF, r, g, b, a])
        pr, pg, pb, pa = r, g, b, a
    if run > 0:
        out.append(0xC0 | (run - 1))
    return bytes(out)

# ------------------------------------------------------------------ file assembly
def build_csif(w, h, nchan, codec_id):
    if codec_id == 0:
        params, codec_bytes = raw_params(), raw_encode(PIXELS, w, h, nchan)
    elif codec_id == 1:
        params, codec_bytes = qoi_params(nchan), qoi_encode(PIXELS, w, h, nchan)
    else:
        raise ValueError("unknown codec")

    # (type, flags, payload) in declared logical order; IEND appended specially.
    per = F_CRITICAL | F_PUBLIC | F_PER_ITEM | F_SINGLETON
    chunks = [
        (b'ILIM', F_CRITICAL | F_PUBLIC | F_SINGLETON, ilim_payload(w, h)),
        (b'IHDR', per, ihdr_payload(w, h, nchan)),
        (b'ICOL', per, icol_payload()),
        (b'ICOD', per, icod_payload(codec_id, params)),
        (b'IDAT', F_CRITICAL | F_PUBLIC | F_PER_ITEM | F_PAYLOAD, idat_payload(codec_bytes)),
    ]
    chunk_count = len(chunks) + 1                          # + IEND

    HDR = 64
    dir_off = HDR
    payload_start = dir_off + chunk_count * 32
    payload_start += pad8(payload_start)

    # lay out chunk offsets/lengths (each chunk: 16 hdr + payload + 4 crc, 8-aligned)
    layout = []                                           # (type, flags, payload, offset, total)
    off = payload_start
    for (t, fl, pl) in chunks:
        total = 16 + len(pl) + 4
        layout.append((t, fl, pl, off, total))
        off += total + pad8(total)
    iend_off = off
    iend_total = 16 + 24 + 4
    file_size = iend_off + iend_total + pad8(iend_off + iend_total)

    buf = bytearray(file_size)

    # ---- header (§1.2) ----
    hdr  = MAGIC + PROBE + u16(1) + u8(0) + u8(1) + u8(0) + u8(1)   # magic,probe,ver,endian,arch,layout,cksum
    hdr += u8(0) + u8(1) + u16(0)                                    # profile=BASELINE, level=1, header_flags
    hdr += u32(chunk_count) + u64(dir_off) + u64(file_size)
    hdr += u64(0) + u64(0)                                           # primary_item_id, directory_offset_tail
    assert len(hdr) == 0x38, len(hdr)
    hdr += u64(crc32(hdr[:0x38]))                                    # header_crc over 0x00..0x37
    buf[0:64] = hdr

    # ---- chunks ----
    def write_chunk(t, fl, pl, offset):
        head = t + u32(fl) + u64(len(pl))
        body = head + pl
        buf[offset:offset + len(body)] = body
        buf[offset + len(body):offset + len(body) + 4] = u32(crc32(body))

    seq = 0
    dir_recs = []
    for (t, fl, pl, offset, total) in layout:
        write_chunk(t, fl, pl, offset)
        dir_recs.append((t, fl, offset, total, seq)); seq += 1

    # ---- IEND (§1.19): whole_file_checksum over [0 .. start-of-IEND-payload) ----
    iend_head = b'IEND' + u32(F_CRITICAL | F_PUBLIC | F_SINGLETON) + u64(24)
    buf[iend_off:iend_off + 16] = iend_head
    iend_payload_start = iend_off + 16
    whole = crc32(bytes(buf[:iend_payload_start]))
    iend_pl = u32(whole) + u64(0) + u32(0) + u64(0)                 # cksum, dir_tail, reserved, marker
    assert len(iend_pl) == 24
    buf[iend_payload_start:iend_payload_start + 24] = iend_pl
    iend_body = iend_head + iend_pl
    buf[iend_off + 16 + 24:iend_off + 16 + 24 + 4] = u32(crc32(iend_body))
    dir_recs.append((b'IEND', F_CRITICAL | F_PUBLIC | F_SINGLETON, iend_off, iend_total, seq))

    # ---- directory (§1.3), sorted by ascending offset (already in order) ----
    drec = bytearray()
    for (t, fl, offset, total, sq) in dir_recs:
        drec += t + u32(fl) + u64(offset) + u64(total) + u32(sq) + u32(0)
    buf[dir_off:dir_off + len(drec)] = drec

    return bytes(buf)

# ------------------------------------------------------------------ decoder (self-test / reference cross-check)
def _rd(b, off, n): return b[off:off + n]
def _u16(b, o): return struct.unpack_from('<H', b, o)[0]
def _u32(b, o): return struct.unpack_from('<I', b, o)[0]
def _u64(b, o): return struct.unpack_from('<Q', b, o)[0]

def decode_csif(buf):
    assert buf[0:4] == MAGIC, "bad magic"
    assert buf[4:10] == PROBE, "bad transmission probe"
    assert _u16(buf, 0x0A) == 1, "bad version"
    assert _u32(buf, 0x38 - 0) or True
    assert crc32(buf[:0x38]) == (_u64(buf, 0x38) & 0xFFFFFFFF), "header crc"
    assert _u64(buf, 0x20) == len(buf), "file_size mismatch"
    chunk_count = _u32(buf, 0x14)
    dir_off = _u64(buf, 0x18)
    chunks = {}
    for i in range(chunk_count):
        rec = dir_off + i * 32
        t = bytes(_rd(buf, rec, 4))
        off = _u64(buf, rec + 0x08)
        total = _u64(buf, rec + 0x10)
        # verify chunk crc
        plen = _u64(buf, off + 8)
        body = buf[off:off + 16 + plen]
        assert crc32(body) == _u32(buf, off + 16 + plen), "chunk crc %s" % t
        chunks.setdefault(t, []).append((off, plen))
    # IHDR
    (ho, hp) = chunks[b'IHDR'][0]; hb = ho + 16
    w, h = _u32(buf, hb + 0x08), _u32(buf, hb + 0x0C)
    nchan = buf[hb + 0x19]
    # ICOD
    (co, cp) = chunks[b'ICOD'][0]; cb = co + 16
    codec_id = _u16(buf, cb + 0x08)
    params_len = _u32(buf, cb + 0x30)
    params = buf[cb + 0x34:cb + 0x34 + params_len]
    # IDAT
    (do, dp) = chunks[b'IDAT'][0]; db = do + 16
    codec_bytes = buf[db + 0x20:do + 16 + dp]
    if codec_id == 0:
        px = bytes(codec_bytes[:w * h * nchan])
    elif codec_id == 1:
        px = qoi_decode(codec_bytes, w, h, nchan)
    else:
        raise ValueError("codec")
    return w, h, nchan, px

def qoi_decode(data, w, h, nchan):
    out = bytearray(w * h * nchan)
    index = [(0, 0, 0, 0)] * 64
    r, g, b, a = 0, 0, 0, 255
    i = 0            # byte cursor
    p = 0            # output cursor (pixels emitted = p // nchan)
    n = w * h
    def put():
        out[p] = r; out[p+1] = g; out[p+2] = b
        if nchan == 4: out[p+3] = a
    while p // nchan < n:
        byte = data[i]
        if byte == 0xFE:
            r, g, b = data[i+1], data[i+2], data[i+3]; i += 4
        elif byte == 0xFF:
            r, g, b, a = data[i+1], data[i+2], data[i+3], data[i+4]; i += 5
        else:
            tag = byte >> 6
            if tag == 0:
                r, g, b, a = index[byte & 63]; i += 1
            elif tag == 1:
                r = (r + ((byte >> 4) & 3) - 2) & 0xFF
                g = (g + ((byte >> 2) & 3) - 2) & 0xFF
                b = (b + (byte & 3) - 2) & 0xFF; i += 1
            elif tag == 2:
                b1 = data[i+1]; vg = (byte & 0x3F) - 32
                r = (r + vg + ((b1 >> 4) & 0x0F) - 8) & 0xFF
                g = (g + vg) & 0xFF
                b = (b + vg + (b1 & 0x0F) - 8) & 0xFF; i += 2
            else:
                runlen = (byte & 0x3F) + 1; i += 1
                for _ in range(runlen):
                    put(); p += nchan
                index[(r*3+g*5+b*7+a*11) & 63] = (r, g, b, a)
                continue
        put(); p += nchan
        index[(r*3+g*5+b*7+a*11) & 63] = (r, g, b, a)
    return bytes(out)

# ------------------------------------------------------------------ input readers
def read_ppm(path):
    with open(path, 'rb') as f:
        data = f.read()
    assert data[:2] == b'P6', "only binary PPM (P6)"
    # parse header tokens
    idx = 2; toks = []
    while len(toks) < 3:
        while idx < len(data) and data[idx] in b' \t\r\n': idx += 1
        if data[idx:idx+1] == b'#':
            while data[idx] not in b'\r\n': idx += 1
            continue
        s = idx
        while data[idx] not in b' \t\r\n': idx += 1
        toks.append(int(data[s:idx]))
    idx += 1                       # single whitespace after maxval
    w, h, mx = toks
    assert mx == 255
    return w, h, 3, data[idx:idx + w*h*3]

def read_png(path):
    with open(path, 'rb') as f:
        d = f.read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n', "not a PNG"
    i = 8; w = h = 0; bitd = ct = 0; idat = b''
    while i < len(d):
        ln = struct.unpack('>I', d[i:i+4])[0]; typ = d[i+4:i+8]; body = d[i+8:i+8+ln]; i += 12 + ln
        if typ == b'IHDR':
            w, h, bitd, ct = struct.unpack('>IIBB', body[:10])
        elif typ == b'IDAT':
            idat += body
        elif typ == b'IEND':
            break
    assert bitd == 8 and ct in (2, 6), "only 8-bit truecolor PNG (RGB/RGBA)"
    nchan = 3 if ct == 2 else 4
    raw = zlib.decompress(idat)
    stride = w * nchan
    out = bytearray(w * h * nchan)
    prev = bytearray(stride)
    pos = 0
    def paeth(a, b, c):
        pp = a + b - c; pa, pb, pc = abs(pp-a), abs(pp-b), abs(pp-c)
        return a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
    for y in range(h):
        ft = raw[pos]; pos += 1
        line = bytearray(raw[pos:pos+stride]); pos += stride
        for x in range(stride):
            a = line[x-nchan] if x >= nchan else 0
            bb = prev[x]
            c = prev[x-nchan] if x >= nchan else 0
            if ft == 1:   line[x] = (line[x] + a) & 0xFF
            elif ft == 2: line[x] = (line[x] + bb) & 0xFF
            elif ft == 3: line[x] = (line[x] + ((a + bb) >> 1)) & 0xFF
            elif ft == 4: line[x] = (line[x] + paeth(a, bb, c)) & 0xFF
        out[y*stride:(y+1)*stride] = line
        prev = line
    return w, h, nchan, bytes(out)

def make_test(w=64, h=48, nchan=4):
    px = bytearray(w * h * nchan)
    for y in range(h):
        for x in range(w):
            p = (y*w+x)*nchan
            px[p]   = (x * 255) // (w-1)
            px[p+1] = (y * 255) // (h-1)
            px[p+2] = 128 if ((x//8 + y//8) & 1) else 32     # checker for runs
            if nchan == 4: px[p+3] = 255
    return w, h, nchan, bytes(px)

# ------------------------------------------------------------------ selftest / cli
PIXELS = b''

def selftest():
    global PIXELS
    ok = True
    for nchan in (3, 4):
        w, h, nchan, PIXELS = make_test(64, 48, nchan)
        outs = {}
        for name, cid in (('raw', 0), ('qoi', 1)):
            f = build_csif(w, h, nchan, cid)
            dw, dh, dc, dpx = decode_csif(f)
            match = (dw, dh, dc) == (w, h, nchan) and dpx == PIXELS
            outs[name] = (len(f), match)
            print(f"  nchan={nchan} codec={name:3}: {len(f):6d} B  roundtrip={'OK' if match else 'FAIL'}")
            ok = ok and match
    print("SELFTEST:", "PASS" if ok else "FAIL")
    return 0 if ok else 1

def main(argv):
    global PIXELS
    if len(argv) >= 1 and argv[0] == '--selftest':
        return selftest()
    codec = 1
    if '--codec' in argv:
        k = argv.index('--codec'); codec = 0 if argv[k+1] == 'raw' else 1
        argv = argv[:k] + argv[k+2:]
    if len(argv) >= 2 and argv[0] == '--test':
        w, h, nchan, PIXELS = make_test()
        outp = argv[1]
    elif len(argv) >= 2:
        inp, outp = argv[0], argv[1]
        rd = read_png if inp.lower().endswith('.png') else read_ppm
        w, h, nchan, PIXELS = rd(inp)
    else:
        print(__doc__ or "usage: png2csif.py <in.png|in.ppm> <out.csif> [--codec raw|qoi]")
        return 2
    data = build_csif(w, h, nchan, codec)
    with open(outp, 'wb') as f:
        f.write(data)
    dw, dh, dc, dpx = decode_csif(data)
    assert (dw, dh, dc) == (w, h, nchan) and dpx == PIXELS, "internal round-trip failed"
    print(f"wrote {outp}: {w}x{h} nchan={nchan} codec={'raw' if codec==0 else 'qoi'} -> {len(data)} B (verified)")
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
