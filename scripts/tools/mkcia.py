#!/usr/bin/env python3
"""Builds tiny, unencrypted, unsigned test CIAs for the install / update / DLC tests.

    mkcia.py app    --elf solid-red.elf   --tid 0004000000B1F000 --name "CIA Test" -o base.cia
    mkcia.py update --elf solid-green.elf --tid 0004000E00B1F000 --version 1040 -o update.cia
    mkcia.py dlc    --tid 0004008C00B1F000 -o dlc.cia

Only meant for Azahar, which does not check signatures or hashes (see the notes in
Core/tests and README): signatures are zero, the cert chain is empty, the NCCH has the
NoCrypto flag. The ELF must be position independent and is loaded at 0x00100000 with the
same kernel capabilities Azahar gives an ELF/3DSX (all syscalls, VRAM mapped).
"""
import argparse
import struct
import sys

MEDIA = 0x200


def align(v, a):
    return (v + a - 1) & ~(a - 1)


def pad_to(data, size):
    return data + b"\0" * (size - len(data))


def elf_load_segment(path):
    """Returns the bytes of the (single) PT_LOAD segment of a 32-bit little-endian ELF."""
    data = open(path, "rb").read()
    if data[:4] != b"\x7fELF" or data[4] != 1:
        sys.exit("not a 32-bit ELF: " + path)
    e_phoff, = struct.unpack_from("<I", data, 0x1C)
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 0x2A)
    out = None
    for i in range(e_phnum):
        p_type, p_offset, p_vaddr, _, p_filesz, p_memsz, _, _ = struct.unpack_from("<8I", data, e_phoff + i * e_phentsize)
        if p_type == 1:
            if out is not None:
                sys.exit("expected one PT_LOAD segment")
            if p_vaddr != 0:
                sys.exit("segment must be linked at 0 (it is loaded at 0x00100000)")
            out = data[p_offset:p_offset + p_filesz] + b"\0" * (p_memsz - p_filesz)
    if out is None:
        sys.exit("no PT_LOAD segment")
    return out


def smdh(name, publisher="Bifold tests"):
    """Minimal SMDH: the same short/long title and publisher for all 16 languages, no icon art."""
    out = bytearray(0x36C0)
    out[0:4] = b"SMDH"
    for lang in range(16):
        base = 8 + lang * 0x200
        short = name.encode("utf-16-le")[:0x7E]
        out[base:base + len(short)] = short
        long_ = name.encode("utf-16-le")[:0xFE]
        out[base + 0x80:base + 0x80 + len(long_)] = long_
        pub = publisher.encode("utf-16-le")[:0x7E]
        out[base + 0x180:base + 0x180 + len(pub)] = pub
    # Region lock: all regions (settings at 0x2008, region lockout u32 at +0x10).
    struct.pack_into("<I", out, 0x2018, 0x7FFFFFFF)
    return bytes(out)


def exefs(files):
    """ExeFS: 0x200 header ({name[8], offset, size} × 8, offsets after the header), files 0x200-aligned."""
    header = bytearray(0x200)
    body = b""
    for i, (name, data) in enumerate(files):
        struct.pack_into("<8sII", header, i * 0x10, name.encode(), len(body), len(data))
        body += pad_to(data, align(len(data), MEDIA))
    return bytes(header) + body


def kernel_caps():
    caps = [0xFFFFFFFF] * 28
    i = 0
    for idx in range(6):                       # syscall mask: everything (not enforced anyway)
        caps[i] = 0xF0000000 | (idx << 24) | 0xFFFFFF
        i += 1
    caps[i] = 0xFF81F000; i += 1               # map VRAM 0x1F000000 ..
    caps[i] = 0xFF81F600; i += 1               # .. 0x1F600000 (read/write)
    caps[i] = 0xFE000200; i += 1               # handle table size 0x200
    caps[i] = 0xFF000100; i += 1               # misc flags: memory region APPLICATION
    caps[i] = 0xFC00023A; i += 1               # kernel version 2.58 (what Azahar gives 3DSX)
    return caps


def exheader(name, program_id, text_pages):
    eh = bytearray(0x800)
    struct.pack_into("<8s", eh, 0x00, name.encode()[:8])
    eh[0x0D] = 0                               # .code not compressed
    base = 0x00100000
    ro = base + text_pages * 0x1000
    data = ro + 0x1000
    struct.pack_into("<III", eh, 0x10, base, text_pages, text_pages * 0x1000)
    struct.pack_into("<I", eh, 0x1C, 0x4000)   # stack
    struct.pack_into("<III", eh, 0x20, ro, 1, 0x1000)
    struct.pack_into("<III", eh, 0x30, data, 1, 0x1000)
    struct.pack_into("<I", eh, 0x3C, 0x1000)   # bss
    struct.pack_into("<Q", eh, 0x200, program_id)
    struct.pack_into("<I", eh, 0x208, 2)       # core version
    eh[0x20E] = 0                              # ideal processor 0, system mode prod
    eh[0x20F] = 0x30                           # main thread priority
    eh[0x36F] = 0                              # resource limit category: application
    struct.pack_into("<28I", eh, 0x370, *kernel_caps())
    eh[0x600:0x800] = eh[0x200:0x400]          # access descriptor copy (unused by Azahar)
    return bytes(eh)


def ncch(program_id, *, code=None, name="TEST", title="", data_only=False, mark_encrypted=False):
    out = bytearray(0x200)
    out[0x100:0x104] = b"NCCH"
    struct.pack_into("<Q", out, 0x108, program_id)  # partition id
    struct.pack_into("<H", out, 0x110, 0x3030)      # maker "00"
    struct.pack_into("<H", out, 0x112, 2)           # NCCH version
    struct.pack_into("<Q", out, 0x118, program_id)
    out[0x150:0x160] = pad_to(b"CTR-P-BFLD", 0x10)
    out[0x18C] = 1                                  # platform: CTR
    out[0x18E] = 0                                  # content unit size 0x200
    out[0x18F] = 0x04 | 0x02                        # NoCrypto | no RomFS
    if mark_encrypted:
        out[0x18F] = 0x02                           # claims NCCH-level crypto (tests rejection only)
    if data_only:
        out[0x18D] = 0x01                           # data, not executable
        body = b""
    else:
        text_pages = max(1, align(len(code), 0x1000) // 0x1000)
        code_blob = pad_to(code, (text_pages + 2) * 0x1000)  # text + 1 ro page + 1 data page
        files = [(".code", code_blob)]
        if title:
            files.append(("icon", smdh(title)))
        fs = exefs(files)
        struct.pack_into("<I", out, 0x180, 0x400)   # exheader size
        out[0x18D] = 0x03                           # data | executable
        struct.pack_into("<II", out, 0x1A0, 0xA00 // MEDIA, len(fs) // MEDIA)
        struct.pack_into("<I", out, 0x1A8, 1)
        body = exheader(name, program_id, text_pages) + fs
    total = align(0x200 + len(body), MEDIA)
    if data_only:
        # A data-only content needs at least something after the header.
        total = 0x400
    struct.pack_into("<I", out, 0x104, total // MEDIA)
    return pad_to(bytes(out) + body, total)


def sig_block(body):
    # RSA-2048/SHA-256 signature type (big endian), zero signature, padded to 0x40.
    return struct.pack(">I", 0x00010004) + b"\0" * 0x100 + b"\0" * 0x3C + body


def ticket(title_id):
    body = bytearray(0x164)
    body[0x00:0x1A] = b"Root-CA00000003-XS0000000c"
    body[0x7C] = 1                                   # ticket format v1
    struct.pack_into(">Q", body, 0x90, 0x0004000000000001)
    struct.pack_into(">Q", body, 0x9C, title_id)
    index = bytearray()
    index += struct.pack(">HHIIHHI", 1, 0x14, 0xAC, 0x14, 1, 0x14, 0)
    index += struct.pack(">IIIIHH", 0x28, 1, 0x84, 0x84, 3, 0)
    index += struct.pack(">HH", 0, 0) + b"\xFF" * 0x80
    assert len(index) == 0xAC
    return sig_block(bytes(body) + bytes(index))


def tmd(title_id, version, content):
    body = bytearray(0x9C4)
    body[0x00:0x1A] = b"Root-CA00000003-CP0000000b"
    body[0x40] = 1
    struct.pack_into(">Q", body, 0x4C, title_id)
    struct.pack_into(">I", body, 0x54, 0x40)         # title type: CTR
    struct.pack_into(">H", body, 0x9C, version)
    struct.pack_into(">H", body, 0x9E, 1)            # one content
    struct.pack_into(">HH", body, 0xC4, 0, 1)        # content info record 0 covers 1 chunk
    chunk = struct.pack(">IHHQ", 0, 0, 0, len(content)) + b"\0" * 0x20
    return sig_block(bytes(body) + chunk)


def cia(title_id, version, content, smdh_blob=None):
    tik = ticket(title_id)
    tm = tmd(title_id, version, content)
    meta = b""
    if smdh_blob:
        meta = b"\0" * 0x400 + smdh_blob             # dependencies + core version, then SMDH
    header = bytearray(0x2020)
    struct.pack_into("<IHHIIIIQ", header, 0, 0x2020, 0, 0, 0, len(tik), len(tm), len(meta), len(content))
    header[0x20] = 0x80                              # content 0 present
    out = bytearray(header)
    out = pad_to(bytes(out), align(len(out), 0x40))  # (empty) cert chain
    out = pad_to(out + tik, align(len(out) + len(tik), 0x40))
    out = pad_to(out + tm, align(len(out) + len(tm), 0x40))
    out += content
    if meta:
        out = pad_to(out, align(len(out), 0x40)) + meta
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("kind", choices=["app", "update", "dlc"])
    ap.add_argument("--elf")
    ap.add_argument("--tid", required=True, type=lambda s: int(s, 16))
    ap.add_argument("--version", type=int, default=0)
    ap.add_argument("--name", default="")
    ap.add_argument("--mark-ncch-encrypted", action="store_true",
                    help="clear the NoCrypto flag (content stays plain): for testing that such CIAs are rejected")
    ap.add_argument("-o", "--output", required=True)
    a = ap.parse_args()
    high = a.tid >> 32
    expected = {"app": 0x00040000, "update": 0x0004000E, "dlc": 0x0004008C}[a.kind]
    if high != expected:
        sys.exit(f"title id for {a.kind} must start with {expected:08X}")
    if a.tid & 0x2:
        sys.exit("low byte of the title id must have bit 1 clear (otherwise it installs to NAND)")
    if a.kind == "dlc":
        content = ncch(a.tid, data_only=True)
    else:
        if not a.elf:
            sys.exit("--elf is required for app/update")
        content = ncch(a.tid, code=elf_load_segment(a.elf), name="BFLDTEST", title=a.name,
                       mark_encrypted=a.mark_ncch_encrypted)
    blob = cia(a.tid, a.version, content, smdh(a.name) if a.name else None)
    open(a.output, "wb").write(blob)
    print(f"{a.output}: {len(blob)} bytes, title {a.tid:016X} v{a.version}")


if __name__ == "__main__":
    main()
