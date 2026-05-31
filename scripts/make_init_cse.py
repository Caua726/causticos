#!/usr/bin/env python3
# make_init_cse.py — emit a minimal /init.cse stub for the boot→userspace
# bootstrap proof. The kernel loads this from the FAT32 disk (open → read →
# proc_spawn → proc_start); it runs in ring 3 and writes a serial marker, then
# exits. The marker appearing in the serial log proves the disk-loaded image
# actually executed in userspace — end to end, no kernel-embedded image.
#
# It is a STUB: the real /init (the terminal, Fatia 4) replaces it on the disk
# with no kernel change. The CSE layout mirrors the proven build_*_cse smokes
# in kernel/userspace.cst (CST_ v2, x86_64, fixed base 0x400000).
#
# Usage: make_init_cse.py <out.cse>
import struct
import sys

ENTRY = 0x401000
BASE  = 0x400000
FOFF  = 0x50
BSS   = 0x402000

MARKER = b"init.cse: hello from ring 3 (loaded from /init.cse on disk)\n"


def main():
    if len(sys.argv) != 2:
        print("usage: make_init_cse.py <out.cse>", file=sys.stderr)
        sys.exit(1)

    # --- code: SYS_IO_WRITE_SERIAL(marker_va, len) then SYS_PROC_EXIT(0) ---
    code = bytearray()
    code += bytes([0x48, 0xC7, 0xC0, 0x06, 0x00, 0x00, 0x00])      # mov rax, 6 (write_serial)
    movabs_imm_off = len(code) + 2                                  # imm of: movabs rdi, <va>
    code += bytes([0x48, 0xBF]) + b"\x00" * 8                       # movabs rdi, STR_VA (patched)
    code += bytes([0x48, 0xC7, 0xC6]) + struct.pack("<i", len(MARKER))  # mov rsi, len
    code += bytes([0x0F, 0x05])                                     # syscall
    code += bytes([0x48, 0xC7, 0xC0, 0x03, 0x00, 0x00, 0x00])      # mov rax, 3 (exit)
    code += bytes([0x31, 0xFF])                                     # xor edi, edi
    code += bytes([0x0F, 0x05])                                     # syscall

    # The marker string sits right after the code in the same R-X segment
    # (text is readable); its VA = ENTRY + offset-past-code.
    str_va = ENTRY + len(code)
    code[movabs_imm_off:movabs_imm_off + 8] = struct.pack("<Q", str_va)

    text = bytes(code) + MARKER
    text_size = len(text)

    # --- header (32 B) + 2 segment descriptors (24 B each) ---
    buf = bytearray(FOFF + text_size)
    buf[0:4] = b"CST_"
    struct.pack_into("<H", buf, 0x04, 2)        # version
    buf[0x06] = 1                                # arch x86_64
    buf[0x07] = 0                                # flags
    struct.pack_into("<Q", buf, 0x08, ENTRY)
    struct.pack_into("<Q", buf, 0x10, BASE)
    struct.pack_into("<I", buf, 0x18, 2)        # seg_count
    struct.pack_into("<I", buf, 0x1C, 0)
    # seg0: text R-X
    struct.pack_into("<Q", buf, 0x20, ENTRY)
    struct.pack_into("<I", buf, 0x28, FOFF)
    struct.pack_into("<I", buf, 0x2C, text_size)
    struct.pack_into("<I", buf, 0x30, text_size)
    struct.pack_into("<I", buf, 0x34, 5)        # R|X
    # seg1: bss R-W (unused by the stub, kept for loader symmetry with smokes)
    struct.pack_into("<Q", buf, 0x38, BSS)
    struct.pack_into("<I", buf, 0x40, 0)
    struct.pack_into("<I", buf, 0x44, 0)
    struct.pack_into("<I", buf, 0x48, 0x1000)
    struct.pack_into("<I", buf, 0x4C, 3)        # R|W
    # code
    buf[FOFF:FOFF + text_size] = text

    with open(sys.argv[1], "wb") as out:
        out.write(buf)
    print(f"wrote {sys.argv[1]} ({len(buf)} bytes, marker {len(MARKER)}B)")


if __name__ == "__main__":
    main()
