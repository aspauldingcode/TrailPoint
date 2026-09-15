#!/usr/bin/env python3
"""Build TrailPoint's Icon Composer package, flattened preview, and .icns.

The glyph is the same stacked `cursorarrow` trail used by PointerTrailIcon
in Main.swift: four pointers stepping up-right at opacities 0.20, 0.38,
0.60, and 1.00. Icon Composer layers stay flat white so Liquid Glass can
recolor them; the icns is a single full-bleed square for macOS 13–15.
"""

from __future__ import annotations

import json
import struct
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
ICON_DIR = ROOT / "AppIcon.icon"
ASSETS = ICON_DIR / "Assets"
CANVAS = 1024
SUPERSAMPLE = 4

# PointerTrailIcon in Main.swift: four `cursorarrow` copies at 19 pt.
# Offsets are SwiftUI points (+y down), matching the options-panel artwork.
TRAIL = [
    {"name": "Trail 4", "file": "Trail-4.svg", "dx": -9.0, "dy": 4.0, "opacity": 0.20},
    {"name": "Trail 3", "file": "Trail-3.svg", "dx": -5.0, "dy": 2.0, "opacity": 0.38},
    {"name": "Trail 2", "file": "Trail-2.svg", "dx": -1.0, "dy": 0.0, "opacity": 0.60},
    {"name": "Pointer", "file": "Pointer.svg", "dx": 3.0, "dy": -2.0, "opacity": 1.00},
]

# Outer silhouette of the macOS default pointer (daviddarnes/mac-cursors
# `default.svg`), translated so the hot spot/tip is (0, 0) with +y down.
# SF Symbol `cursorarrow` is this same filled pointer.
CURSOR_PATH = [
    (0.000, 0.000),
    (0.000, 16.015),
    (3.316, 12.794),
    (6.137, 18.066),
    (8.000, 17.063),
    (9.615, 16.224),
    (7.047, 11.408),
    (11.379, 11.408),
]

# Path units ≈ SwiftUI points of the 19 pt symbol. 20 px/pt keeps the
# four-cursor group inside the Icon Composer safe area with quiet margins.
PT = 20.0


def cursor_points(origin: tuple[float, float], scale: float) -> list[tuple[float, float]]:
    ox, oy = origin
    return [(ox + x * scale, oy + y * scale) for x, y in CURSOR_PATH]


def trail_origins(scale: float) -> list[tuple[float, float]]:
    tips = [(layer["dx"] * scale, layer["dy"] * scale) for layer in TRAIL]
    xs, ys = [], []
    for tip in tips:
        for x, y in cursor_points(tip, scale):
            xs.append(x)
            ys.append(y)
    cx = (min(xs) + max(xs)) / 2
    cy = (min(ys) + max(ys)) / 2
    dx, dy = CANVAS / 2 - cx, CANVAS / 2 - cy
    return [(tip[0] + dx, tip[1] + dy) for tip in tips]


def svg_path(points: list[tuple[float, float]]) -> str:
    commands = [f"M {points[0][0]:.3f} {points[0][1]:.3f}"]
    commands.extend(f"L {x:.3f} {y:.3f}" for x, y in points[1:])
    commands.append("Z")
    return " ".join(commands)


def write_svg(path: Path, points: list[tuple[float, float]]) -> None:
    d = svg_path(points)
    path.write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" '
        f'viewBox="0 0 {CANVAS} {CANVAS}">\n'
        f'  <path fill="#FFFFFF" fill-rule="nonzero" d="{d}"/>\n'
        "</svg>\n",
        encoding="utf-8",
    )


def icon_document() -> dict:
    layers = []
    for item in TRAIL:
        fill = [
            {"value": {"solid": "extended-gray:1.00000,1.00000"}},
            {"appearance": "dark", "value": {"solid": "extended-gray:1.00000,1.00000"}},
            {"appearance": "tinted", "value": {"solid": "extended-gray:1.00000,1.00000"}},
        ]
        layer = {
            "fill-specializations": fill,
            "glass": True,
            "hidden": False,
            "image-name": item["file"],
            "name": item["name"],
        }
        if item["opacity"] < 1:
            layer["opacity"] = item["opacity"]
        layers.append(layer)
    return {
        "fill-specializations": [
            {
                "value": {
                    "automatic-gradient": "extended-srgb:0.47059,0.54118,0.62745,1.00000"
                }
            },
            {
                "appearance": "dark",
                "value": {
                    "automatic-gradient": "extended-srgb:0.17647,0.21176,0.25882,1.00000"
                },
            },
        ],
        "groups": [
            {
                "blur-material": 0.18,
                "layers": layers,
                "lighting": "individual",
                "name": "Pointer Trail",
                "shadow": {"kind": "neutral", "opacity": 0.32},
                "specular": True,
                "translucency": {"enabled": True, "value": 0.14},
            }
        ],
        "supported-platforms": {"squares": ["macOS"]},
    }


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def gradient_fill(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        t = y / max(1, size - 1)
        color = tuple(int(lerp(c0, c1, t)) for c0, c1 in zip(top, bottom))
        for x in range(size):
            px[x, y] = color
    return img.convert("RGBA")


def draw_trail(size: int, fill: tuple[int, int, int], scale: float, origins: list[tuple[float, float]]) -> Image.Image:
    factor = size / CANVAS
    big = size * SUPERSAMPLE
    layer = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    for origin, item in zip(origins, TRAIL):
        pts = [
            (x * factor * SUPERSAMPLE, y * factor * SUPERSAMPLE)
            for x, y in cursor_points(origin, scale)
        ]
        alpha = int(round(255 * item["opacity"]))
        draw.polygon(pts, fill=(*fill, alpha))
    return layer.resize((size, size), Image.Resampling.LANCZOS)


def squircle_mask(size: int) -> Image.Image:
    """Continuous-corner squircle close to the macOS app-icon mask."""
    big = size * SUPERSAMPLE
    mask = Image.new("L", (big, big), 0)
    draw = ImageDraw.Draw(mask)
    radius = int(round(0.223 * big))
    draw.rounded_rectangle((0, 0, big - 1, big - 1), radius=radius, fill=255)
    return mask.resize((size, size), Image.Resampling.LANCZOS)


def compose(size: int, light: bool, mask_squircle: bool, origins: list[tuple[float, float]], scale: float) -> Image.Image:
    if light:
        top, bottom = (148, 168, 192), (108, 128, 152)
        glyph = (255, 255, 255)
    else:
        top, bottom = (58, 68, 80), (32, 40, 52)
        glyph = (255, 255, 255)
    base = gradient_fill(size, top, bottom)
    trail = draw_trail(size, glyph, scale, origins)
    icon = Image.alpha_composite(base, trail)
    if mask_squircle:
        icon.putalpha(squircle_mask(size))
    return icon


def png_bytes(image: Image.Image) -> bytes:
    from io import BytesIO

    buffer = BytesIO()
    image.save(buffer, format="PNG", optimize=True)
    return buffer.getvalue()


def write_icns(path: Path, master: Image.Image) -> None:
    # PNG-based icon types used by modern macOS.
    specs = {
        b"icp4": 16,
        b"icp5": 32,
        b"icp6": 64,
        b"ic07": 128,
        b"ic08": 256,
        b"ic09": 512,
        b"ic10": 1024,
        b"ic11": 32,
        b"ic12": 64,
        b"ic13": 256,
        b"ic14": 512,
    }
    chunks = []
    for ostype, size in specs.items():
        data = png_bytes(master.resize((size, size), Image.Resampling.LANCZOS))
        chunks.append(ostype + struct.pack(">I", 8 + len(data)) + data)
    body = b"".join(chunks)
    path.write_bytes(b"icns" + struct.pack(">I", 8 + len(body)) + body)


def main() -> None:
    ASSETS.mkdir(parents=True, exist_ok=True)
    origins = trail_origins(PT)
    for origin, item in zip(origins, TRAIL):
        write_svg(ASSETS / item["file"], cursor_points(origin, PT))

    document = icon_document()
    (ICON_DIR / "icon.json").write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")

    media = ROOT / "Media"
    media.mkdir(exist_ok=True)
    preview = compose(CANVAS, light=True, mask_squircle=True, origins=origins, scale=PT)
    preview.save(media / "AppIcon.png", "PNG", optimize=True)
    compose(CANVAS, light=False, mask_squircle=True, origins=origins, scale=PT).save(
        media / "AppIcon-dark.png", "PNG", optimize=True
    )

    fullbleed = compose(CANVAS, light=True, mask_squircle=False, origins=origins, scale=PT)
    write_icns(ROOT / "AppIcon.icns", fullbleed)
    print(f"Wrote {ICON_DIR}")
    print(f"Wrote {ROOT / 'AppIcon.icns'} ({(ROOT / 'AppIcon.icns').stat().st_size} bytes)")
    print(f"Wrote {media / 'AppIcon.png'}")


if __name__ == "__main__":
    main()
