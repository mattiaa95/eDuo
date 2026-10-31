#!/usr/bin/env python3
"""Fix the open replacement system font (stand-in for shared_font) shipped by Azahar.

Problem: the open font from github.com/B3n30/citra_system_archives (the one Azahar
embeds in externals/open_source_archives/include/shared_font.app.romfs.h) has the
glyph order of the official font, but its manifest lost 21 codes: the last one of
each consecutive run. Their cells are there (with the official width) but empty and
have no CMAP entry, so the game draws the fallback character instead.
Among them: ん, ヶ, ～ (U+FF5E), ~, ё and the kanji 企 列 厄 呑 展 彁 扎 杙 疔 賭 邑 雫.
Japanese text comes out "broken" (ん appears in almost every sentence).

Fix, using no Nintendo data: draw those glyphs into their cells with the same open
fonts and the same recipe as the original generator (Montserrat 20 for ASCII,
GNU Unifont 22 for the rest), add them to the CMAP (sorted) and add aliases for
the JIS/CP932 variants (〜 ‖ − ￥). Same glyph order, same metrics.

Output: Native3DS/open_source_archives/include/shared_font.app.romfs.h, which patch
0005 puts ahead of Azahar's own copy. Deterministic: running it again yields the
same file. Usage: python3 scripts/shared_font/fix_open_shared_font.py
"""
import hashlib
import struct
import subprocess
import sys
import urllib.request
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
AZ = ROOT / "Vendor/azahar"
PIN = "987f18405073960622e1043bb44005989135c6e1"
SRC = "externals/open_source_archives/include/shared_font.app.romfs.h"
OUT = ROOT / "Native3DS/open_source_archives/include/shared_font.app.romfs.h"
CACHE = ROOT / "Build/shared_font_cache"
GEN_COMMIT = "f470e0c9"  # citra_system_archives, the generator of the embedded font
FONTS = {
    "Montserrat-Regular.otf": "16772fa219f7b40708b8d5779952505fb263c865d29bf8437c1c457b1bc2f7aa",
    "unifont-10.0.05.ttf": "a850db8a860ab6e01524a9da1740d157a4594efdba5c21d9cf3f3d277f10cd47",
}

# Empty cell -> the code it is missing. Cells follow Unicode order; each one sits
# between two present codes and only one of the candidates is JIS/CP1252.
MISSING = {
    94: 0x007E,    # ~
    198: 0x0107,   # ć (between Ć and Ċ)
    278: 0x0192,   # ƒ (CP1252, between ž and ǅ)
    372: 0x03CE,   # ώ
    438: 0x0451,   # ё
    724: 0x3093,   # ん
    814: 0x30F6,   # ヶ
    970: 0x4F01,   # 企
    1266: 0x5217,  # 列
    1419: 0x5384,  # 厄
    1508: 0x5451,  # 呑
    2121: 0x5C55,  # 展
    2364: 0x5F41,  # 彁
    2675: 0x624E,  # 扎
    3122: 0x6759,  # 杙
    4213: 0x7594,  # 疔
    6033: 0x8CED,  # 賭
    6317: 0x9091,  # 邑
    6679: 0x96EB,  # 雫
    7431: 0xFF5E,  # ～
    # 7337 (between U+E07D and U+FF01) is a Nintendo-specific icon: it stays empty.
}
# JIS table variants vs. CP932: same drawing, different code.
ALIASES = {0x301C: 0xFF5E, 0x2016: 0x2225, 0x2212: 0xFF0D, 0xFFE5: 0x00A5}


def lz11_decompress(d):
    assert d[0] == 0x11
    size, p, out = int.from_bytes(d[1:4], "little"), 4, bytearray()
    while len(out) < size:
        flags = d[p]; p += 1
        for i in range(8):
            if len(out) >= size:
                break
            if not flags & (0x80 >> i):
                out.append(d[p]); p += 1
                continue
            b = d[p]; ind = b >> 4
            if ind == 0:
                ln = ((b & 0xF) << 4 | d[p + 1] >> 4) + 0x11; disp = ((d[p + 1] & 0xF) << 8 | d[p + 2]) + 1; p += 3
            elif ind == 1:
                ln = ((b & 0xF) << 12 | d[p + 1] << 4 | d[p + 2] >> 4) + 0x111; disp = ((d[p + 2] & 0xF) << 8 | d[p + 3]) + 1; p += 4
            else:
                ln = ind + 1; disp = ((b & 0xF) << 8 | d[p + 1]) + 1; p += 2
            for _ in range(ln):
                out.append(out[-disp])
    return bytes(out)


def lz11_compress(d):
    """Greedy LZ11 with hash chains (4 KiB window). 4-byte header: < 16 MiB."""
    assert len(d) < 1 << 24
    out = bytearray([0x11]) + len(d).to_bytes(3, "little")
    heads, prev = {}, [0] * len(d)
    def insert(i):
        if i + 3 <= len(d):
            k = d[i:i + 3]; prev[i] = heads.get(k, -1); heads[k] = i
    i = 0
    while i < len(d):
        flag_pos = len(out); out.append(0); flags = 0
        for bit in range(8):
            if i >= len(d):
                break
            best_len = best_disp = 0
            if i + 3 <= len(d):
                j, tries = heads.get(d[i:i + 3], -1), 0
                maxlen = min(0x10110, len(d) - i)
                while j >= 0 and i - j <= 0x1000 and tries < 64:
                    n = 3
                    while n < maxlen and d[j + n] == d[i + n]:
                        n += 1
                    if n > best_len:
                        best_len, best_disp = n, i - j
                        if n == maxlen:
                            break
                    j = prev[j]; tries += 1
            if best_len >= 3:
                flags |= 0x80 >> bit
                disp = best_disp - 1
                if best_len <= 0x10:
                    out += bytes([(best_len - 1) << 4 | disp >> 8, disp & 0xFF])
                elif best_len <= 0x110:
                    n = best_len - 0x11
                    out += bytes([n >> 4, (n & 0xF) << 4 | disp >> 8, disp & 0xFF])
                else:
                    n = best_len - 0x111
                    out += bytes([0x10 | n >> 12, (n >> 4) & 0xFF, (n & 0xF) << 4 | disp >> 8, disp & 0xFF])
                for k in range(best_len):
                    insert(i + k)
                i += best_len
            else:
                insert(i); out.append(d[i]); i += 1
        out[flag_pos] = flags
    while len(out) % 4:
        out.append(0)
    return bytes(out)


def romfs_single_file(data):
    """Read the embedded level-3 RomFS (a single file) -> (header+metadata, name, data)."""
    h = struct.unpack("<10I", data[:40])
    fmo, fdo = h[7], h[9]
    _, _, doff, dsize, _, nlen = struct.unpack("<IIQQII", data[fmo:fmo + 32])
    name = data[fmo + 32:fmo + 32 + nlen].decode("utf-16le")
    return h, name, data[fdo + doff:fdo + doff + dsize]


def romfs_replace_file(data, new_file):
    h, _, _ = romfs_single_file(data)
    fmo, fdo = h[7], h[9]
    meta = bytearray(data[:fdo])
    struct.pack_into("<Q", meta, fmo + 16, len(new_file))
    return bytes(meta) + new_file


def parse_bcfnt(b):
    finf = struct.unpack_from("<4sIBBH3BBIIIBBBB", b, 0x14)
    tglp = struct.unpack_from("<4sIBBBBIHHHHHHI", b, finf[9] - 8)
    cmap_off = finf[11] - 8
    m, size, cb, ce, method, _, nxt = struct.unpack_from("<4sIHHHHI", b, cmap_off)
    assert m == b"CMAP" and method == 2 and nxt == 0, "expected a single scan-type CMAP"
    n = struct.unpack_from("<H", b, cmap_off + 20)[0]
    pairs = dict(struct.unpack_from("<HH", b, cmap_off + 22 + 4 * i) for i in range(n))
    assert cmap_off + size == len(b), "the CMAP must be the last block"
    return tglp, cmap_off, pairs


def sheet_pos(px, py, width):
    """Pixel -> index in the sheet (8x8 tiles in Z order, like the generator's bcfnt.py)."""
    tx, x = divmod(px, 8); ty, y = divmod(py, 8)
    return ((x & 1) + ((x >> 1) & 1) * 4 + ((x >> 2) & 1) * 16 + tx * 64
            + (y & 1) * 2 + ((y >> 1) & 1) * 8 + ((y >> 2) & 1) * 32 + ty * width * 8)


def fetch_fonts():
    CACHE.mkdir(parents=True, exist_ok=True)
    paths = {}
    for name, sha in FONTS.items():
        p = CACHE / name
        if not p.exists():
            url = f"https://raw.githubusercontent.com/B3n30/citra_system_archives/{GEN_COMMIT}/shared_font/{name}"
            p.write_bytes(urllib.request.urlopen(url).read())
        if hashlib.sha256(p.read_bytes()).hexdigest() != sha:
            sys.exit(f"{name}: sha256 mismatch, aborting")
        paths[name] = str(p)
    return paths


def build():
    src_h = subprocess.run(["git", "-C", str(AZ), "show", f"{PIN}:{SRC}"],
                           check=True, capture_output=True, text=True).stdout
    romfs = bytes(int(x, 16) for x in src_h[src_h.index("{") + 1:].split("}")[0].replace(",", " ").split())
    _, name, lz = romfs_single_file(romfs)
    assert name == "cbf_std.bcfnt.lz"
    b = bytearray(lz11_decompress(lz))
    tglp, cmap_off, pairs = parse_bcfnt(b)
    cell_w, sheet_size, fmt, cols, rows, sw, sh, data_off = tglp[2], tglp[6], tglp[8], tglp[9], tglp[10], tglp[11], tglp[12], tglp[13]
    assert (fmt, cols, rows, sw, sh) == (0x0B, 5, 1, 128, 32), "unexpected sheet layout"
    used = set(pairs.values())

    fonts = fetch_fonts()
    mont = ImageFont.truetype(fonts["Montserrat-Regular.otf"], 20)
    uni = ImageFont.truetype(fonts["unifont-10.0.05.ttf"], 22)
    for glyph, code in MISSING.items():
        assert glyph not in used and code not in pairs, f"cell {glyph} / U+{code:04X} already taken"
        # Same recipe as create_png.py: 25 px cell, y=1, Montserrat up to glyph 94.
        col = glyph % cols
        img = Image.new("RGBA", (sw, sh))
        ImageDraw.Draw(img).text((col * 25, 1), chr(code), "#FFF", font=mont if glyph <= 94 else uni)
        alpha = img.getchannel("A")
        base = data_off + (glyph // cols) * sheet_size
        for py in range(sh):
            for px in range(col * 25, min(col * 25 + cell_w + 1, sw)):
                a = alpha.getpixel((px, py)) // 0x11
                if a:
                    p = sheet_pos(px, py, sw)
                    b[base + (p >> 1)] |= a << ((p & 1) * 4)
        pairs[code] = glyph
    for alias, target in ALIASES.items():
        if alias not in pairs:
            pairs[alias] = pairs[target]

    entries = sorted(pairs.items())
    # Same as the original: code_begin/end = first/last code, no padding.
    cmap = bytearray(struct.pack("<4sIHHHHI", b"CMAP", 0, entries[0][0], entries[-1][0], 2, 0, 0))
    cmap += struct.pack("<H", len(entries)) + b"".join(struct.pack("<HH", c, g) for c, g in entries)
    struct.pack_into("<I", cmap, 4, len(cmap))
    b = b[:cmap_off] + cmap
    struct.pack_into("<I", b, 0x0C, len(b))  # total size in the CFNT header
    assert len(b) + 0x80 <= 0x332000, "does not fit in the shared font memory"

    new_romfs = romfs_replace_file(romfs, lz11_compress(bytes(b)))
    lines = ["// eDuo: open font from Azahar (citra_system_archives 0baa5f5) with the 20 lost glyphs",
             "// restored. Generated by scripts/shared_font/fix_open_shared_font.py.",
             "// License: GPLv2 (citra_system_archives); glyphs from Montserrat (SIL OFL 1.1) and",
             "// GNU Unifont 10.0.05 (GPLv2+ with font exception). See Native3DS/licenses.",
             "", "unsigned char SHARED_FONT_DATA[] = {"]
    for i in range(0, len(new_romfs), 12):
        lines.append("  " + ", ".join(f"0x{x:02x}" for x in new_romfs[i:i + 12]) + ",")
    lines[-1] = lines[-1].rstrip(",")
    lines += ["};", f"unsigned int SHARED_FONT_DATA_len = {len(new_romfs)};", ""]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines))
    print(f"ok: {OUT.relative_to(ROOT)} ({len(new_romfs)} bytes RomFS, BCFNT {len(b)} bytes, "
          f"{len(entries)} codes)")


if __name__ == "__main__":
    build()
