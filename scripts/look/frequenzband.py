#!/usr/bin/env python3
"""Detailgehalt von Aufnahmen gegen das Vorbild, in Ortsfrequenz-Bändern.

    scripts/look/frequenzband.py <ordner> [<ordner> ...]

Jeder Ordner ist ein Aufnahme-Satz aus `scripts/look/shots.sh` (diorama.jpg,
tal.jpg, nah.jpg); sein Name ist die Zeilenbeschriftung. Die Vorbilder liegen
in docs/references/zielbild/ (anderer Ort: `LOOK_REFS=<ordner>`).

Ausgabe je Aufnahme und Satz: Energie in vier Bändern (Zyklen je Bildbreite),
relativ zum Vorbild, dazu Mikrokontrast und Farbenzahl. Das mittlere Band
(32 bis 128) ist die „Knete“: im Bericht zu PR #232 hatte das Spiel dort
doppelt so viel Energie wie das Vorbild, weil der Talboden überall
gleichmäßig bucklig war statt ruhig. Eine grobe Messung an JPEGs, kein Gate.

Braucht numpy und Pillow.
"""
import os
import sys

import numpy as np
from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REFS = os.environ.get("LOOK_REFS", os.path.join(ROOT, "docs", "references", "zielbild"))
SHOTS = [("diorama", "d-insel-diorama-schoen.jpg"), ("tal", "e-tal-kueste-schoen.jpg"),
         ("nah", "f-nah-flussschleife-schoen.jpg")]
W, H = 1600, 976
BANDS = [(8, 32), (32, 128), (128, 400), (400, 800)]


def load(path):
    im = Image.open(path).convert("RGB").resize((W, H), Image.LANCZOS)
    return np.asarray(im, dtype=np.float64) / 255


def lum(a):
    return 0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2]


def bands(g):
    """Energie je Band (Zyklen je Bildbreite), Hann-Fenster."""
    w = np.outer(np.hanning(H), np.hanning(W))
    p = np.abs(np.fft.fftshift(np.fft.fft2((g - g.mean()) * w))) ** 2
    yy, xx = np.indices(p.shape)
    r = np.hypot((yy - H / 2) * W / H, xx - W / 2)
    return np.array([p[(r >= lo) & (r < hi)].sum() for lo, hi in BANDS])


def highpass(g, radius):
    im = Image.fromarray((g * 255).astype(np.uint8))
    blur = np.asarray(im.filter(ImageFilter.GaussianBlur(radius)), dtype=np.float64) / 255
    return (g - blur).std()


def colors(a):
    q = (a * 15.999).astype(int)
    _, counts = np.unique(q[..., 0] * 256 + q[..., 1] * 16 + q[..., 2], return_counts=True)
    share = counts / counts.sum()
    return len(counts), -(share * np.log2(share)).sum()


def measure(path):
    a = load(path)
    g = lum(a)
    return bands(g), highpass(g, 2), highpass(g, 8), colors(a)


def main():
    sets = sys.argv[1:]
    if not sets:
        sys.exit(__doc__)
    head = " | ".join("%d-%d" % b for b in BANDS)
    print("Aufnahme | Stand | Energie %s (rel. zum Vorbild) | Mikrokontrast 2 px | 8 px"
          " | Farben (4096) | Farbentropie bit" % head)
    for name, ref in SHOTS:
        ref_bands, *ref_rest = measure(os.path.join(REFS, ref))
        rows = []
        for folder in sets:
            path = os.path.join(folder, name + ".jpg")
            if os.path.exists(path):
                rows.append((os.path.basename(os.path.normpath(folder)),) + measure(path))
        rows.append(("Vorbild", ref_bands, *ref_rest))
        for tag, b, h2, h8, (count, entropy) in rows:
            rel = " | ".join("%.2f" % v for v in b / ref_bands)
            print(f"{name} | {tag} | {rel} | {h2:.4f} | {h8:.4f} | {count} | {entropy:.2f}")


if __name__ == "__main__":
    main()
