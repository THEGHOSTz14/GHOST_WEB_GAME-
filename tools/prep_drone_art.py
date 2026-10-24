#!/usr/bin/env python3
"""Turn the supplied drone artwork into game sprites.

The source PNGs are flat RGB: the transparency checkerboard is baked into the
pixels, so it has to be keyed out before Godot can use them. The key is a
flood fill from the image border rather than a colour test, because the hull has
light grey highlights that are the same colour as the checker -- a naive
luminance key would punch holes in the drone.

Also measures where the four rotor hubs actually are, in the trimmed sprite's
0..1 space, so the prop anchors in scripts/Drone.gd come from the artwork
instead of from eyeballing it.

    python tools/prep_drone_art.py <body.png> <prop.png>
"""

import os
import sys
from collections import deque

import numpy as np
from PIL import Image, ImageFilter

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "assets", "drone")
BODY_SIZE = 384
PROP_SIZE = 256
# The two checker tones are near-white neutral greys.
CHECK_LOW, CHECK_HIGH, NEUTRAL = 222, 256, 14


def matte(rgb: np.ndarray) -> np.ndarray:
    """Alpha 0..255: background reached from the border is 0, everything else 255."""
    h, w, _ = rgb.shape
    lo = rgb.min(axis=2)
    hi = rgb.max(axis=2)
    candidate = (lo >= CHECK_LOW) & (hi < CHECK_HIGH) & ((hi - lo) <= NEUTRAL)
    outside = np.zeros((h, w), dtype=bool)
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            if candidate[y, x] and not outside[y, x]:
                outside[y, x] = True
                q.append((y, x))
    for y in range(h):
        for x in (0, w - 1):
            if candidate[y, x] and not outside[y, x]:
                outside[y, x] = True
                q.append((y, x))
    while q:
        y, x = q.popleft()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and candidate[ny, nx] and not outside[ny, nx]:
                outside[ny, nx] = True
                q.append((ny, nx))
    alpha = np.where(outside, 0, 255).astype(np.uint8)
    # One pixel of feather keeps the silhouette smooth when the sprite is scaled
    # down, without the halo a wide blur would leave.
    eroded = np.asarray(Image.fromarray(alpha).filter(ImageFilter.MinFilter(3)))
    return np.minimum(alpha, eroded)


def trim(rgba: np.ndarray) -> np.ndarray:
    a = rgba[:, :, 3]
    ys, xs = np.nonzero(a > 8)
    if len(ys) == 0:
        raise SystemExit("sprite ended up fully transparent")
    y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
    pad = 2
    y0 = max(0, y0 - pad)
    x0 = max(0, x0 - pad)
    y1 = min(rgba.shape[0] - 1, y1 + pad)
    x1 = min(rgba.shape[1] - 1, x1 + pad)
    return rgba[y0:y1 + 1, x0:x1 + 1]


def hubs(rgb: np.ndarray, alpha: np.ndarray) -> list:
    """Centroids of the orange rotor rings, one per quadrant, in 0..1 sprite space."""
    r = rgb[:, :, 0].astype(int)
    g = rgb[:, :, 1].astype(int)
    b = rgb[:, :, 2].astype(int)
    orange = (r > 150) & (g > 55) & (g < 175) & (b < 95) & (alpha > 8)
    ys, xs = np.nonzero(orange)
    if len(xs) == 0:
        return []
    h, w = alpha.shape
    cx, cy = w / 2.0, h / 2.0
    out = []
    for qx in (-1, 1):
        for qy in (-1, 1):
            keep = (np.sign(xs - cx) == qx) & (np.sign(ys - cy) == qy)
            if keep.sum() < 50:
                continue
            mx = float(xs[keep].mean()) / w
            my = float(ys[keep].mean()) / h
            spread = max(float(xs[keep].std()), float(ys[keep].std())) / max(w, h)
            out.append((round(mx, 3), round(my, 3), int(keep.sum()), round(spread, 3)))
    return sorted(out)


def save(src: str, name: str, size: int, report_hubs: bool) -> None:
    im = Image.open(src).convert("RGB")
    rgb = np.asarray(im)
    alpha = matte(rgb)
    rgba = np.dstack([rgb, alpha])
    rgba = trim(rgba)
    out = Image.fromarray(rgba, "RGBA")
    out.thumbnail((size, size), Image.LANCZOS)
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, name)
    out.save(path, optimize=True)
    print(f"{name}: {out.size[0]}x{out.size[1]}  "
          f"{os.path.getsize(path) / 1024:.0f} KB  "
          f"opaque {100.0 * (np.asarray(out)[:, :, 3] > 8).mean():.0f}%")
    if report_hubs:
        arr = np.asarray(out)
        print("  rotor hubs (u, v, pixels, ring spread):")
        for hx, hy, n, sp in hubs(arr[:, :, :3], arr[:, :, 3]):
            print(f"    ({hx}, {hy})  n={n}  spread={sp}")


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    save(sys.argv[1], "drone_body.png", BODY_SIZE, True)
    save(sys.argv[2], "drone_prop.png", PROP_SIZE, False)
    prop = np.asarray(Image.open(os.path.join(OUT_DIR, "drone_prop.png")))
    ys, xs = np.nonzero(prop[:, :, 3] > 8)
    print(f"  prop span: {100.0 * (xs.max() - xs.min()) / prop.shape[1]:.0f}% wide, "
          f"{100.0 * (ys.max() - ys.min()) / prop.shape[0]:.0f}% tall")
    return 0


if __name__ == "__main__":
    sys.exit(main())
