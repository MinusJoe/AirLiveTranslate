#!/usr/bin/env python3
"""Render the blue sound-bar mark used in the app header."""
import json
import math
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]
SIZE = 1024


def main():
    rows = bytearray()
    background = bytes((24, 84, 212))
    bars = [(-6.5, 2, 10, (255, 255, 255)), (0, 0, 20, (255, 255, 255)), (6.5, -2, 13, (204, 217, 246))]
    angle = math.radians(13)
    cosine, sine = math.cos(angle), math.sin(angle)
    unit = SIZE / 34
    for y in range(SIZE):
        line = bytearray(background * SIZE)
        if abs(y - SIZE / 2) < 12 * unit:
            for x in range(int(6 * unit), int(28 * unit)):
                dx, dy = (x + .5 - SIZE/2) / unit, (y + .5 - SIZE/2) / unit
                u, v = dx*cosine + dy*sine, -dx*sine + dy*cosine
                for cx, cy, height, color in bars:
                    end = max(abs(v-cy) - (height/2 - 2), 0)
                    coverage = min(1, (2 - math.hypot(u-cx, end)) * unit + .5)
                    if coverage > 0:
                        line[x*3:x*3+3] = bytes(round(a + coverage*(b-a)) for a,b in zip(background,color))
                        break
        rows.append(0)
        rows.extend(line)
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
