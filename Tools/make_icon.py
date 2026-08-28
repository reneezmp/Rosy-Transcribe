#!/usr/bin/env python3
"""Generates the Rosy Transcribe app icon.

No image library is used, and none is needed. Every shape is a signed
distance function, so a pixel's coverage is read straight off the distance
to the nearest edge -- which gives exact anti-aliasing at any size from one
sample per pixel, and keeps the whole thing to zlib and struct.

Run from the repository root:

    python3 Tools/make_icon.py

It rewrites RosyTranscribe/Assets.xcassets/AppIcon.appiconset in place.
"""

import json
import os
import struct
import zlib
from math import hypot

OUT = os.path.join("RosyTranscribe", "Assets.xcassets", "AppIcon.appiconset")

# Rose gold, light at the top-left falling to a deeper rose at the bottom-right.
TOP = (0xF9, 0xD5, 0xC9)
BOTTOM = (0xB9, 0x72, 0x76)
MIC = (0xFF, 0xFA, 0xF7)

# Fractions of the canvas. The artwork is inset so the rounded square sits
# where macOS expects it in the Dock rather than filling the tile edge to edge.
INSET = 0.055
CORNER = 0.2237          # Apple's continuous-corner ratio, near enough


def rounded_rect(px, py, cx, cy, hw, hh, r):
    qx = abs(px - cx) - (hw - r)
    qy = abs(py - cy) - (hh - r)
    return hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - r


def capsule(px, py, cx, cy, hw, hh):
    return rounded_rect(px, py, cx, cy, hw, hh, hw)


def lower_arc(px, py, cx, cy, radius, half_thickness):
    """The U-shaped bracket under the microphone, with round ends."""
    if py >= cy:
        return abs(hypot(px - cx, py - cy) - radius) - half_thickness
    left = hypot(px - (cx - radius), py - cy)
    right = hypot(px - (cx + radius), py - cy)
    return min(left, right) - half_thickness


def coverage(distance):
    """Signed distance in pixels to a 0..1 alpha across one pixel of edge."""
    return min(max(0.5 - distance, 0.0), 1.0)


def render(size):
    s = float(size)
    inset = INSET * s
    half = (s - 2 * inset) / 2.0
    cx = cy = s / 2.0
    corner = CORNER * (half * 2)

    # Microphone geometry, in fractions of the rounded square's side.
    side = half * 2
    mx = cx
    top = inset
    body_cy = top + 0.40 * side
    body_hw = 0.093 * side
    body_hh = 0.150 * side
    arc_cy = top + 0.435 * side
    arc_r = 0.215 * side
    arc_t = 0.038 * side
    stem_top = arc_cy + arc_r
    stem_bottom = top + 0.775 * side
    base_hw = 0.105 * side
    base_hh = 0.020 * side

    rows = []
    for y in range(size):
        py = y + 0.5
        row = bytearray()
        row.append(0)  # PNG filter: none
        for x in range(size):
            px = x + 0.5

            alpha = coverage(rounded_rect(px, py, cx, cy, half, half, corner))
            if alpha <= 0.0:
                row += b"\x00\x00\x00\x00"
                continue

            # Diagonal gradient across the tile.
            t = ((px - inset) + (py - inset)) / (2.0 * side)
            t = min(max(t, 0.0), 1.0)
            r = TOP[0] + (BOTTOM[0] - TOP[0]) * t
            g = TOP[1] + (BOTTOM[1] - TOP[1]) * t
            b = TOP[2] + (BOTTOM[2] - TOP[2]) * t

            d = capsule(px, py, mx, body_cy, body_hw, body_hh)
            d = min(d, lower_arc(px, py, mx, arc_cy, arc_r, arc_t / 2))
            d = min(d, rounded_rect(px, py, mx, (stem_top + stem_bottom) / 2,
                                    arc_t / 2, (stem_bottom - stem_top) / 2, arc_t / 2))
            d = min(d, rounded_rect(px, py, mx, stem_bottom + base_hh,
                                    base_hw, base_hh, base_hh))

            m = coverage(d)
            if m > 0.0:
                r += (MIC[0] - r) * m
                g += (MIC[1] - g) * m
                b += (MIC[2] - b) * m

            row += bytes((int(r + 0.5), int(g + 0.5), int(b + 0.5), int(alpha * 255 + 0.5)))
        rows.append(bytes(row))
    return b"".join(rows)


def write_png(path, size, raw):
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)  # 8-bit RGBA
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", header)
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


# (point size, scale) -> the ten entries macOS asks for.
ENTRIES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
           (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]


def main():
    os.makedirs(OUT, exist_ok=True)
    cache = {}
    images = []

    for point, scale in ENTRIES:
        pixels = point * scale
        if pixels not in cache:
            cache[pixels] = render(pixels)
            print("rendered %dx%d" % (pixels, pixels))
        name = "icon_%dx%d%s.png" % (point, point, "@2x" if scale == 2 else "")
        write_png(os.path.join(OUT, name), pixels, cache[pixels])
        images.append({"idiom": "mac", "size": "%dx%d" % (point, point),
                       "scale": "%dx" % scale, "filename": name})

    with open(os.path.join(OUT, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")

    parent = os.path.dirname(OUT)
    with open(os.path.join(parent, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")

    print("wrote %d PNGs to %s" % (len(ENTRIES), OUT))


if __name__ == "__main__":
    main()
