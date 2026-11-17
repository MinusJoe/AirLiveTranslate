#!/usr/bin/env python3
"""Draw the simple original waveform icon without third-party packages."""
import json
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]
SIZE = 1024


def capsule(x, y, cx, cy, width, height):
    radius = width / 2
    straight = max(0, height / 2 - radius)
    dy = max(abs(y - cy) - straight, 0)
    return (x - cx) ** 2 + dy ** 2 <= radius ** 2


def main():
    rows = bytearray()
    bars = [(320, 180), (416, 340), (512, 500), (608, 340), (704, 180)]
    for y in range(SIZE):
        rows.append(0)
        for x in range(SIZE):
            blend = (x + y) / (2 * SIZE)
            rgb = (int(12 + 10 * blend), int(26 + 24 * blend), int(48 + 25 * blend))
            if any(capsule(x, y, cx, 512, 54, height) for cx, height in bars):
                rgb = (122, 239, 216) if x < 512 else (233, 245, 255)
            rows.extend(rgb)
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', SIZE, SIZE, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(bytes(rows), 9)) + chunk(b'IEND', b'')
    assets = ROOT / 'Resources/Assets.xcassets'
    icon = assets / 'AppIcon.appiconset'
    icon.mkdir(parents=True, exist_ok=True)
    (assets / 'Contents.json').write_text(json.dumps({'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')
    (icon / 'AppIcon.png').write_bytes(png)
    (icon / 'Contents.json').write_text(json.dumps({'images': [{'filename': 'AppIcon.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}], 'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')
    print('Generated opaque 1024x1024 AppIcon.png')


if __name__ == '__main__':
    main()
