#!/usr/bin/env python3
"""Flimmern der Feinstruktur in Zeitraffer-Videos (#238).

    scripts/look/flimmern.py <video> [<video> ...]

Je Video: Änderung von Bild zu Bild, getrennt nach Feinstruktur (Bild minus
Weichzeichnung, Radius 4 px bei 1728 px Breite) und Grobform (die
Weichzeichnung). Flimmert die Verfeinerung, steigt die Fein-Zahl, während die
Grobform gleich bleibt: die Sim ändert das Gelände in beiden Videos gleich.
Gemessen wird in der Bildmitte (ohne Bedienleiste).
Zahlen in 1/255 Helligkeit: Mittel und p99 über alle Bildpunkte und Bilder,
dazu der Anteil der Bildpunkte, die sich von Bild zu Bild um mehr als 8/255
ändern. Die Aufnahmen haben verschiedene Bildraten (die Aufnahme bremst das
Spiel je nach Stand verschieden); verglichen wird deshalb auf einem
gemeinsamen Takt von 12 Bildern je Sekunde (ffmpeg wählt das jeweils nächste
Bild). Videos aus scripts/look/zeitraffer-video.sh. Braucht ffmpeg, numpy,
Pillow.
"""
import subprocess
import sys

import numpy as np
from PIL import Image, ImageFilter

W, H = 1728, 1052
RATE = 12
BOX = (0.12, 0.16, 0.88, 0.86)


def frames(path, skip=0, step=1):
    cmd = ["ffmpeg", "-loglevel", "error", "-i", path, "-vf", f"fps={RATE},scale={W}:{H}",
           "-f", "rawvideo", "-pix_fmt", "gray", "-"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    index = 0
    while True:
        raw = proc.stdout.read(W * H)
        if len(raw) < W * H:
            break
        if index >= skip and (index - skip) % step == 0:
            yield np.frombuffer(raw, dtype=np.uint8).reshape(H, W)
        index += 1
    proc.wait()


def split(gray):
    x0, y0, x1, y1 = int(BOX[0] * W), int(BOX[1] * H), int(BOX[2] * W), int(BOX[3] * H)
    blur = np.asarray(Image.fromarray(gray).filter(ImageFilter.GaussianBlur(4)), dtype=np.float32)
    fine = gray.astype(np.float32) - blur
    return fine[y0:y1, x0:x1], blur[y0:y1, x0:x1]


def measure(path):
    prev = None
    fine_d, coarse_d, fine_level = [], [], []
    for gray in frames(path):
        fine, coarse = split(gray)
        if prev is not None:
            fine_d.append(np.abs(fine - prev[0]))
            coarse_d.append(np.abs(coarse - prev[1]))
        fine_level.append(np.abs(fine).mean())
        prev = (fine, coarse)
    fd = np.stack(fine_d)
    cd = np.stack(coarse_d)
    return {
        "bilder": len(fine_level),
        "fein_niveau": float(np.mean(fine_level)),
        "fein_mittel": float(fd.mean()), "fein_p99": float(np.percentile(fd, 99)),
        "fein_ueber8": float((fd > 8).mean()),
        "grob_mittel": float(cd.mean()), "grob_p99": float(np.percentile(cd, 99)),
    }


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    print("Video | Bilder | Feinstruktur Niveau | Änderung fein Mittel | fein p99"
          " | fein > 8/255 | Änderung grob Mittel | grob p99")
    for path in sys.argv[1:]:
        m = measure(path)
        print(f"{path} | {m['bilder']} | {m['fein_niveau']:.2f} | {m['fein_mittel']:.3f}"
              f" | {m['fein_p99']:.2f} | {m['fein_ueber8'] * 100:.3f} % | {m['grob_mittel']:.3f}"
              f" | {m['grob_p99']:.2f}")


if __name__ == "__main__":
    main()
