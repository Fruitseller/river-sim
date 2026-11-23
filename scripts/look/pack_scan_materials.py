#!/usr/bin/env python3
"""Packt die Scan-Materialien (#237) in zwei Textur-Arrays für Godot.

    python3 -I scripts/look/pack_scan_materials.py <quell-ordner> <ziel-ordner>

Die Quellsätze (CC0, ambientCG / Poly Haven) liegen NICHT im Repo; welcher Satz
welche Ebene wird, steht in LAYERS unten, Herkunft und SHA-256 der Quellen in
game/assets/materials/MANIFEST.md. Ergebnis (Ebenen senkrecht gestapelt, je
SIZE×SIZE, von Godot als Texture2DArray importiert):

  scan_albedo.png  RGB Albedo (sRGB), mittlere lineare Helligkeit je Ebene auf
                   ALBEDO_MEAN normiert und um DESATURATE entsättigt (den Ton
                   setzt der Shader); A Höhe, je Ebene auf 0 … 1 gestreckt.
  scan_normal.png  RG Normale (OpenGL), B Rauheit, A 255.

Normiert wird, damit der Shader Albedo / ALBEDO_MEAN als Detail um 1 lesen und
die Grundfarben behalten kann (Fels dunkelgrau seit #174 D).
"""
import hashlib
import sys
from pathlib import Path

import numpy as np
from PIL import Image

SIZE = 1024
ALBEDO_MEAN = 0.18
DESATURATE = 0.5

def _ph(n):
    return {"albedo": [f"{n}_diff_1k.png"], "normal": [f"{n}_nor_gl_1k.png"],
            "rough": [f"{n}_rough_1k.png"], "height": [f"{n}_disp_1k.png"]}


def _acg(n):
    return {"albedo": [f"{n}_1K-PNG_Color.png"], "normal": [f"{n}_1K-PNG_NormalGL.png"],
            "rough": [f"{n}_1K-PNG_Roughness.png"], "height": [f"{n}_1K-PNG_Displacement.png"]}


LAYERS = [
    ("rock_bedded", "polyhaven_dark_rock_02", _ph("dark_rock_02")),
    ("rock_jointed", "ambientcg_Rock030", _acg("Rock030")),
    ("scree", "ambientcg_Rocks006", _acg("Rocks006")),
    ("gravel", "polyhaven_ganges_river_pebbles", _ph("ganges_river_pebbles")),
    ("sand", "polyhaven_aerial_beach_02", _ph("aerial_beach_02")),
]


def srgb_to_lin(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def lin_to_srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


def find(folder: Path, patterns):
    for pat in patterns:
        hits = sorted(folder.glob(pat))
        if hits:
            return hits[0]
    raise SystemExit(f"{folder}: keine Datei zu {patterns}")


def load(path: Path, mode: str) -> np.ndarray:
    img = Image.open(path)
    if img.mode in ("I;16", "I;16B", "I"):
        arr = np.asarray(img, dtype=np.float64)
        arr = arr / (65535.0 if arr.max() > 255 else 255.0)
        img = Image.fromarray((arr * 255).astype(np.uint8))
    img = img.convert(mode).resize((SIZE, SIZE), Image.LANCZOS)
    return np.asarray(img, dtype=np.float64) / 255.0


def pack(src: Path, dst: Path):
    albedo_rows, normal_rows, used = [], [], []
    for name, folder, pats in LAYERS:
        d = src / folder
        f_alb = find(d, pats["albedo"])
        f_nor = find(d, pats["normal"])
        f_rgh = find(d, pats["rough"])
        f_hgt = find(d, pats["height"])
        used += [f_alb, f_nor, f_rgh, f_hgt]
        lin = srgb_to_lin(load(f_alb, "RGB"))
        lum = lin @ np.array([0.2126, 0.7152, 0.0722])
        lin = lin + (lum[..., None] - lin) * DESATURATE
        lin *= ALBEDO_MEAN / max(lum.mean(), 1e-4)
        hgt = load(f_hgt, "L")
        lo, hi = np.percentile(hgt, [1, 99])
        hgt = np.clip((hgt - lo) / max(hi - lo, 1e-4), 0, 1)
        alb = np.dstack([lin_to_srgb(lin), hgt])
        nor = load(f_nor, "RGB")
        rgh = load(f_rgh, "L")
        nrm = np.dstack([nor[..., 0], nor[..., 1], rgh, np.ones_like(rgh)])
        albedo_rows.append(alb)
        normal_rows.append(nrm)
        print(f"{name}: {folder} (Helligkeit vorher {lum.mean():.3f} linear)")
    dst.mkdir(parents=True, exist_ok=True)
    for fname, rows in (("scan_albedo.png", albedo_rows), ("scan_normal.png", normal_rows)):
        arr = (np.clip(np.vstack(rows), 0, 1) * 255 + 0.5).astype(np.uint8)
        Image.fromarray(arr, "RGBA").save(dst / fname, optimize=True)
        sha = hashlib.sha256((dst / fname).read_bytes()).hexdigest()
        print(f"{fname}: {(dst / fname).stat().st_size / 1e6:.1f} MB  sha256 {sha}")
    print("Quellen:")
    for f in used:
        print(f"  {hashlib.sha256(f.read_bytes()).hexdigest()}  {f.relative_to(src)}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    pack(Path(sys.argv[1]), Path(sys.argv[2]))
