#!/usr/bin/env python3
"""Kontaktbogen vorher | nachher | Vorbild je Aufnahme, als JPG.

    scripts/look/kontaktbogen.py <vorher-ordner> <nachher-ordner> <ausgabe-ordner>

Die Ordner sind Aufnahme-Sätze aus `scripts/look/shots.sh`. Je Aufnahme
entsteht `kontaktbogen-<name>.jpg` (drei Bilder nebeneinander, je 1200 px
breit, das Vorbild auf dieselbe Höhe beschnitten). Braucht Pillow.
"""
import os
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REFS = os.environ.get("LOOK_REFS", os.path.join(ROOT, "docs", "references", "zielbild"))
SHOTS = [("diorama", "d-insel-diorama-schoen.jpg"), ("tal", "e-tal-kueste-schoen.jpg"),
         ("nah", "f-nah-flussschleife-schoen.jpg")]
WIDTH = 1200


def fit(path, height=None):
    im = Image.open(path).convert("RGB")
    im = im.resize((WIDTH, round(im.height * WIDTH / im.width)), Image.LANCZOS)
    if height is not None and im.height != height:
        if im.height > height:
            top = (im.height - height) // 2
            im = im.crop((0, top, WIDTH, top + height))
        else:
            canvas = Image.new("RGB", (WIDTH, height))
            canvas.paste(im, (0, (height - im.height) // 2))
            im = canvas
    return im


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    before, after, out = sys.argv[1:]
    os.makedirs(out, exist_ok=True)
    for name, ref in SHOTS:
        a = fit(os.path.join(before, name + ".jpg"))
        b = fit(os.path.join(after, name + ".jpg"), a.height)
        c = fit(os.path.join(REFS, ref), a.height)
        sheet = Image.new("RGB", (WIDTH * 3 + 16, a.height + 28), (16, 18, 22))
        draw = ImageDraw.Draw(sheet)
        for i, (im, label) in enumerate(((a, "vorher"), (b, "nachher"), (c, "Vorbild"))):
            sheet.paste(im, (i * (WIDTH + 8), 28))
            draw.text((i * (WIDTH + 8) + 8, 8), label, fill=(230, 230, 230))
        path = os.path.join(out, "kontaktbogen-%s.jpg" % name)
        sheet.save(path, quality=86)
        print(path)


if __name__ == "__main__":
    main()
