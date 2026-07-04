#!/usr/bin/env python3
"""Generate PlushBuddy app icons without external image dependencies."""

from __future__ import annotations

import json
import math
import struct
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ANDROID_RES = ROOT / "apps/android/flutter_app/android/app/src/main/res"
IOS_ICONSET = ROOT / "apps/android/flutter_app/ios/Runner/Assets.xcassets/AppIcon.appiconset"
WEB_ICONS = ROOT / "apps/android/flutter_app/web/icons"
STATION_WEB_ICONS = ROOT / "apps/station/macstation_host/assets/flutter_web/icons"


def hex_rgba(value: str, alpha: int = 255) -> tuple[int, int, int, int]:
    value = value.lstrip("#")
    return (int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16), alpha)


PINK = hex_rgba("#ff8bd1")
PURPLE = hex_rgba("#8b5cf6")
SKY = hex_rgba("#38bdf8")
CREAM = hex_rgba("#fff5d6")
INK = hex_rgba("#281a38")
WHITE = hex_rgba("#ffffff")


def mix(a: tuple[int, int, int, int], b: tuple[int, int, int, int], t: float) -> tuple[int, int, int, int]:
    return tuple(round(a[i] * (1 - t) + b[i] * t) for i in range(4))


def blend(dst: tuple[int, int, int, int], src: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
    sa = src[3] / 255.0
    da = dst[3] / 255.0
    out_a = sa + da * (1 - sa)
    if out_a <= 0:
        return (0, 0, 0, 0)
    out = []
    for i in range(3):
        out.append(round((src[i] * sa + dst[i] * da * (1 - sa)) / out_a))
    out.append(round(out_a * 255))
    return tuple(out)


def rounded_rect_contains(x: float, y: float, left: float, top: float, right: float, bottom: float, radius: float) -> bool:
    if x < left or x > right or y < top or y > bottom:
        return False
    cx = min(max(x, left + radius), right - radius)
    cy = min(max(y, top + radius), bottom - radius)
    return (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2


def ellipse_contains(x: float, y: float, cx: float, cy: float, rx: float, ry: float) -> bool:
    return ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1


def star_contains(x: float, y: float, cx: float, cy: float, radius: float) -> bool:
    return abs(x - cx) + abs(y - cy) <= radius or (
        abs(x - cx) <= radius * 0.28 and abs(y - cy) <= radius * 1.25
    ) or (
        abs(y - cy) <= radius * 0.28 and abs(x - cx) <= radius * 1.25
    )


def smile_contains(x: float, y: float, s: int) -> bool:
    cx = s * 0.50
    cy = s * 0.69
    width = s * 0.22
    target_y = cy + s * 0.07 * (1 - ((x - cx) / (width / 2)) ** 2)
    return abs(x - cx) <= width / 2 and abs(y - target_y) <= max(1.2, s * 0.013)


def pixel_color(x: float, y: float, s: int, margin: float) -> tuple[int, int, int, int]:
    base = hex_rgba("#fffbf2")
    left = s * margin
    top = s * margin
    right = s * (1 - margin)
    bottom = s * (1 - margin)
    radius = s * 0.24
    if rounded_rect_contains(x, y, left, top, right, bottom, radius):
        t = min(1, max(0, (x + y - left - top) / ((right - left) + (bottom - top))))
        color = mix(PINK, PURPLE, min(1, t * 1.45))
        if t > 0.58:
            color = mix(PURPLE, SKY, (t - 0.58) / 0.42)
        base = blend(base, color)

    cx = s * 0.50
    cy = s * 0.52
    if ellipse_contains(x, y, cx - s * 0.18, cy - s * 0.18, s * 0.095, s * 0.095):
        base = blend(base, CREAM)
    if ellipse_contains(x, y, cx + s * 0.18, cy - s * 0.18, s * 0.095, s * 0.095):
        base = blend(base, CREAM)
    if ellipse_contains(x, y, cx, cy, s * 0.265, s * 0.245):
        base = blend(base, CREAM)
    if ellipse_contains(x, y, cx, cy + s * 0.11, s * 0.16, s * 0.095):
        base = blend(base, (255, 255, 255, 245))
    if ellipse_contains(x, y, cx - s * 0.115, cy - s * 0.035, s * 0.030, s * 0.030):
        base = blend(base, INK)
    if ellipse_contains(x, y, cx + s * 0.115, cy - s * 0.035, s * 0.030, s * 0.030):
        base = blend(base, INK)
    if ellipse_contains(x, y, cx, cy + s * 0.075, s * 0.055, s * 0.040):
        base = blend(base, INK)
    if smile_contains(x, y, s):
        base = blend(base, INK)

    bx = s * 0.68
    by = s * 0.69
    if ellipse_contains(x, y, bx, by, s * 0.135, s * 0.135):
        base = blend(base, WHITE)
    if ellipse_contains(x, y, bx, by, s * 0.100, s * 0.100):
        base = blend(base, SKY)
    if star_contains(x, y, bx, by, s * 0.060):
        base = blend(base, WHITE)
    return base


def render(size: int, maskable: bool = False) -> list[tuple[int, int, int, int]]:
    scale = 3 if size <= 192 else 1
    hi = size * scale
    margin = 0.10 if maskable else 0.06
    pixels: list[tuple[int, int, int, int]] = []
    for y in range(size):
        for x in range(size):
            accum = [0, 0, 0, 0]
            for sy in range(scale):
                for sx in range(scale):
                    color = pixel_color(x * scale + sx + 0.5, y * scale + sy + 0.5, hi, margin)
                    for i in range(4):
                        accum[i] += color[i]
            pixels.append(tuple(round(v / (scale * scale)) for v in accum))
    return pixels


def write_png(path: Path, size: int, pixels: list[tuple[int, int, int, int]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    raw = bytearray()
    for y in range(size):
        raw.append(0)
        for x in range(size):
            raw.extend(pixels[y * size + x][:3])

    def chunk(name: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + name
            + data
            + struct.pack(">I", zlib.crc32(name + data) & 0xFFFFFFFF)
        )

    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )
    path.write_bytes(png)


_render_cache: dict[tuple[int, bool], list[tuple[int, int, int, int]]] = {}


def generate(path: Path, size: int, maskable: bool = False) -> None:
    cache_key = (size, maskable)
    if cache_key not in _render_cache:
        _render_cache[cache_key] = render(size, maskable=maskable)
    write_png(path, size, _render_cache[cache_key])


def main() -> None:
    for density, size in {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }.items():
        generate(ANDROID_RES / density / "ic_launcher.png", size)

    generate(WEB_ICONS / "Icon-192.png", 192)
    generate(WEB_ICONS / "Icon-512.png", 512)
    generate(WEB_ICONS / "Icon-maskable-192.png", 192, maskable=True)
    generate(WEB_ICONS / "Icon-maskable-512.png", 512, maskable=True)
    generate(STATION_WEB_ICONS / "Icon-192.png", 192)
    generate(STATION_WEB_ICONS / "Icon-512.png", 512)
    generate(STATION_WEB_ICONS / "Icon-maskable-192.png", 192, maskable=True)
    generate(STATION_WEB_ICONS / "Icon-maskable-512.png", 512, maskable=True)

    contents = json.loads((IOS_ICONSET / "Contents.json").read_text())
    for image in contents["images"]:
        filename = image.get("filename")
        if not filename:
            continue
        logical = float(image["size"].split("x")[0])
        scale = int(image["scale"].replace("x", ""))
        generate(IOS_ICONSET / filename, round(logical * scale))


if __name__ == "__main__":
    main()
