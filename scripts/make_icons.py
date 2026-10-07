#!/usr/bin/env python3
"""Generate original 56x56 RGBA CSIF application icons, without image libraries.

The function pictogram and readable badge are both part of the icon: commands
sharing a family remain distinguishable without relying on colour or initials.
mkroot imports build_icons; the CLI writes the same assets to a chosen directory.
"""
import pathlib
import sys

import png2csif

SIZE = 56
INK = (211, 215, 207, 255)
CYAN = (115, 208, 255, 255)
GREEN = (159, 224, 167, 255)
GOLD = (255, 210, 128, 255)
PINK = (233, 171, 235, 255)

# Original five-column pixel lettering. Seven rows, most significant bit left.
FONT = {
    'A': (14, 17, 17, 31, 17, 17, 17), 'B': (30, 17, 17, 30, 17, 17, 30),
    'C': (14, 17, 16, 16, 16, 17, 14), 'D': (30, 17, 17, 17, 17, 17, 30),
    'E': (31, 16, 16, 30, 16, 16, 31), 'F': (31, 16, 16, 30, 16, 16, 16),
    'G': (14, 17, 16, 23, 17, 17, 15), 'H': (17, 17, 17, 31, 17, 17, 17),
    'I': (31, 4, 4, 4, 4, 4, 31), 'J': (7, 2, 2, 2, 18, 18, 12),
    'K': (17, 18, 20, 24, 20, 18, 17), 'L': (16, 16, 16, 16, 16, 16, 31),
    'M': (17, 27, 21, 21, 17, 17, 17), 'N': (17, 25, 21, 19, 17, 17, 17),
    'O': (14, 17, 17, 17, 17, 17, 14), 'P': (30, 17, 17, 30, 16, 16, 16),
    'Q': (14, 17, 17, 17, 21, 18, 13), 'R': (30, 17, 17, 30, 20, 18, 17),
    'S': (15, 16, 16, 14, 1, 1, 30), 'T': (31, 4, 4, 4, 4, 4, 4),
    'U': (17, 17, 17, 17, 17, 17, 14), 'V': (17, 17, 17, 17, 17, 10, 4),
    'W': (17, 17, 17, 21, 21, 21, 10), 'X': (17, 17, 10, 4, 10, 17, 17),
    'Y': (17, 17, 10, 4, 4, 4, 4), 'Z': (31, 1, 2, 4, 8, 16, 31),
    '0': (14, 17, 19, 21, 25, 17, 14), '1': (4, 12, 4, 4, 4, 4, 14),
    '2': (14, 17, 1, 2, 4, 8, 31), '3': (30, 1, 1, 14, 1, 1, 30),
    '4': (2, 6, 10, 18, 31, 2, 2), '5': (31, 16, 16, 30, 1, 1, 30),
    '6': (14, 16, 16, 30, 17, 17, 14), '7': (31, 1, 2, 4, 8, 8, 8),
    '8': (14, 17, 17, 14, 17, 17, 14), '9': (14, 17, 17, 15, 1, 1, 14),
    '+': (0, 4, 4, 31, 4, 4, 0), '-': (0, 0, 0, 31, 0, 0, 0),
}


class Canvas:
    def __init__(self):
        self.pixels = bytearray(SIZE * SIZE * 4)

    def rect(self, x, y, w, h, color=CYAN):
        row = bytes(color) * max(0, min(SIZE, x + w) - max(0, x))
        for yy in range(max(0, y), min(SIZE, y + h)):
            off = (yy * SIZE + max(0, x)) * 4
            self.pixels[off:off + len(row)] = row

    def line(self, x, y, ex, ey, color=CYAN):
        dx, dy = abs(ex - x), -abs(ey - y)
        sx, sy = (1 if x < ex else -1), (1 if y < ey else -1)
        err = dx + dy
        while True:
            self.rect(x, y, 2, 2, color)
            if (x, y) == (ex, ey):
                return
            twice = 2 * err
            if twice >= dy:
                err += dy
                x += sx
            if twice <= dx:
                err += dx
                y += sy

    def box(self, x, y, w, h, color=CYAN):
        self.rect(x, y, w, 2, color)
        self.rect(x, y + h - 2, w, 2, color)
        self.rect(x, y, 2, h, color)
        self.rect(x + w - 2, y, 2, h, color)

    def circle(self, x, y, radius, color=CYAN, filled=False):
        for yy in range(-radius, radius + 1):
            for xx in range(-radius, radius + 1):
                d = xx * xx + yy * yy
                if d <= radius * radius and (filled or d >= (radius - 2) ** 2):
                    self.rect(x + xx, y + yy, 1, 1, color)

    def text(self, label, x, y, color=INK):
        for i, ch in enumerate(label):
            for yy, bits in enumerate(FONT[ch]):
                for xx in range(5):
                    if bits & (16 >> xx):
                        self.rect(x + i * 12 + xx * 2, y + yy * 2, 2, 2, color)


def pictogram(c, kind):
    if kind == 'terminal':
        c.box(7, 4, 42, 29)
        c.rect(9, 10, 38, 2)
        c.line(14, 16, 20, 22, GREEN)
        c.line(20, 22, 14, 28, GREEN)
        c.rect(26, 27, 12, 2, GREEN)
    elif kind == 'file':
        c.line(17, 3, 32, 3)
        c.line(32, 3, 39, 10)
        c.line(39, 10, 39, 31)
        c.line(39, 31, 17, 31)
        c.line(17, 31, 17, 3)
        c.line(32, 3, 32, 10)
        c.line(32, 10, 39, 10)
        for y in (15, 21, 27):
            c.rect(23, y, 10, 2, INK)
    elif kind == 'folder':
        c.box(7, 10, 42, 23, GOLD)
        c.box(7, 4, 19, 8, GOLD)
        c.rect(12, 17, 30, 2, INK)
    elif kind == 'text':
        for y, width in ((7, 36), (15, 28), (23, 36), (31, 20)):
            c.rect(10, y, width, 2)
    elif kind == 'binary':
        c.text('01', 17, 8, GREEN)
        c.rect(10, 28, 36, 2, GREEN)
    elif kind == 'audio':
        c.line(25, 6, 25, 26, PINK)
        c.line(25, 6, 42, 3, PINK)
        c.line(42, 3, 42, 23, PINK)
        c.circle(20, 28, 5, PINK, True)
        c.circle(37, 25, 5, PINK, True)
    elif kind == 'record':
        c.box(23, 3, 10, 18, PINK)
        c.line(17, 14, 17, 22, PINK)
        c.line(17, 22, 28, 28, PINK)
        c.line(28, 28, 39, 22, PINK)
        c.line(39, 22, 39, 14, PINK)
        c.rect(27, 28, 2, 6, PINK)
        c.rect(21, 32, 14, 2, PINK)
    elif kind == 'network':
        c.box(21, 3, 14, 9, GREEN)
        c.line(28, 12, 28, 20, GREEN)
        c.line(10, 20, 45, 20, GREEN)
        for x in (8, 23, 38):
            c.line(x + 5, 20, x + 5, 25, GREEN)
            c.box(x, 25, 11, 8, GREEN)
    elif kind == 'monitor':
        c.box(7, 3, 42, 26)
        for x, height in ((14, 7), (23, 17), (32, 12), (41, 21)):
            c.rect(x, 27 - height, 4, height, GREEN)
        c.rect(27, 29, 2, 4)
        c.rect(20, 32, 16, 2)
    elif kind == 'search':
        c.circle(23, 15, 11, GOLD)
        c.line(31, 23, 43, 33, GOLD)
        c.rect(18, 14, 10, 2, INK)
    elif kind == 'tool':
        c.circle(20, 12, 8, GOLD)
        c.circle(20, 12, 3, GOLD)
        for x, y, w, h in ((18, 1, 4, 4), (18, 21, 4, 4), (9, 10, 4, 4), (29, 10, 4, 4)):
            c.rect(x, y, w, h, GOLD)
        c.line(28, 20, 40, 32, GOLD)
        c.circle(41, 32, 3, GOLD)
    elif kind == 'power':
        c.circle(28, 19, 14, GOLD)
        c.rect(24, 3, 8, 14, (0, 0, 0, 0))
        c.rect(27, 2, 2, 18, GOLD)
    elif kind == 'clock':
        c.circle(28, 18, 15, GOLD)
        c.line(28, 7, 28, 18, GOLD)
        c.line(28, 18, 37, 23, GOLD)
    elif kind == 'edit':
        c.line(14, 28, 35, 7, GOLD)
        c.line(35, 7, 41, 13, GOLD)
        c.line(41, 13, 20, 34, GOLD)
        c.line(20, 34, 14, 34, GOLD)
        c.line(14, 34, 14, 28, GOLD)
        c.line(31, 11, 37, 17, GOLD)
    elif kind == 'compare':
        c.box(7, 4, 17, 29)
        c.box(32, 4, 17, 29, GREEN)
        c.line(19, 16, 36, 16, GOLD)
        c.line(36, 16, 32, 12, GOLD)
        c.line(36, 16, 32, 20, GOLD)
        c.line(36, 24, 19, 24, GOLD)
        c.line(19, 24, 23, 20, GOLD)
        c.line(19, 24, 23, 28, GOLD)
    elif kind == 'scissors':
        c.circle(16, 26, 6, GOLD)
        c.circle(38, 26, 6, GOLD)
        c.line(20, 22, 39, 4, GOLD)
        c.line(34, 22, 15, 4, GOLD)
    elif kind == 'copy':
        c.box(9, 3, 25, 23)
        c.box(21, 12, 25, 23, GREEN)
    elif kind == 'move':
        c.box(7, 5, 17, 26)
        c.line(27, 18, 48, 18, GOLD)
        c.line(48, 18, 40, 10, GOLD)
        c.line(48, 18, 40, 26, GOLD)
    elif kind == 'trash':
        c.line(16, 10, 18, 33, GOLD)
        c.line(18, 33, 37, 33, GOLD)
        c.line(37, 33, 39, 10, GOLD)
        c.rect(12, 7, 33, 2, GOLD)
        c.box(22, 2, 13, 7, GOLD)
        c.rect(24, 14, 2, 15, GOLD)
        c.rect(31, 14, 2, 15, GOLD)
    elif kind == 'keyboard':
        c.box(5, 7, 46, 25)
        for y in (12, 19):
            for x in range(10, 46, 7):
                c.rect(x, y, 4, 3, INK)
        c.rect(17, 26, 23, 3, INK)
    elif kind == 'grid':
        for y in (3, 20):
            for x in (8, 23, 38):
                c.box(x, y, 10, 12)
    elif kind == 'stack':
        for x, y in ((8, 3), (15, 10), (22, 17)):
            c.box(x, y, 26, 16)
    elif kind == 'link':
        c.box(7, 9, 22, 17, GREEN)
        c.box(27, 16, 22, 17, GREEN)
        c.line(19, 20, 37, 20, GOLD)
    else:
        raise ValueError('unknown icon symbol: ' + kind)


def build_icons(catalog):
    seen = set()
    with open(catalog, encoding='utf-8') as source:
        for number, line in enumerate(source, 1):
            if line.startswith('#') or not line.strip():
                continue
            fields = line.rstrip('\n').split('\t')
            if len(fields) != 4:
                raise ValueError(f'{catalog}:{number}: expected name, symbol, badge and description')
            name, symbol, badge, description = fields
            if not name or name.strip() != name or '/' in name or name in seen:
                raise ValueError(f'{catalog}:{number}: invalid or repeated application name')
            if not 1 <= len(badge) <= 4 or any(ch not in FONT for ch in badge) or not description:
                raise ValueError(f'{catalog}:{number}: invalid badge or missing description')
            seen.add(name)
            canvas = Canvas()
            pictogram(canvas, symbol)
            canvas.text(badge, (SIZE - (len(badge) * 12 - 2)) // 2, 38)
            png2csif.PIXELS = canvas.pixels
            yield name, png2csif.build_csif(SIZE, SIZE, 4, 1)


def main():
    if len(sys.argv) != 2:
        sys.exit('usage: make_icons.py OUT_DIRECTORY')
    out = pathlib.Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    catalog = pathlib.Path(__file__).resolve().parent.parent / 'assets' / 'apps.tsv'
    count = 0
    for name, data in build_icons(catalog):
        (out / (name + '.csif')).write_bytes(data)
        count += 1
    print(f'icons: {count} original RGBA/QOI images written to {out}')


if __name__ == '__main__':
    main()
