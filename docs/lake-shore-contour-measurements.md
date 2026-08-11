# Seeufer als Konturen — Messreihe zum Ufer-Saum (Issue #32)

Die Umstellung der Uferlinie auf eine Per-Pixel-Kontur (`pond_at` in
`terrain.gdshader`) ändert die Bedeutung des **G-Kanals** des Wasserfelds: vorher
eine Tiefen-Rampe (`min(1, (hf − h − 0.03) / 0.10)`, einmal geblurt), jetzt ein
Sichtbarkeits-**Gate** (Komponenten-Fade, 1.0 über der ganzen Fläche, ZWEIMAL
geblurt).

Der Ufer-Saum (`shore` in `terrain.gdshader`) liest denselben Kanal weiter mit
`smoothstep(0.09, 0.16, max(stream, ·))` — mit Schwellen, die aus der Rampen-Zeit
stammen. Diese Messung klärt, was das um Seen tatsächlich bewirkt.

Messwerkzeug war ein temporäres `SceneTree`-Skript (`game/tests/_shore_dump.gd`),
das Höhen (`heights()`), Seespiegel (`filled()`) und Wasserfeld
(`waterFieldBytes(1.0)`) in eine Datei kippt; ausgewertet offline, indem beide
Shader-Fassungen exakt nachgerechnet wurden. Das Skript ist nach der Messung
wieder entfernt — die Werte stehen hier und im Shader-Kommentar.

## Aufbau

- Seed 1337, Jahr 20.000, `n = 832`, Produktions-Config.
- **Seezellen**: `waterLevel − h > 0.03` und `waterLevel ≥ sea`.
- **Saumband**: bis 6 Zellen um Seezellen, die Seezellen selbst ausgenommen und
  Zellen mit nennenswerter Fluss-Intensität (`stream ≥ 0.16`) ebenfalls — sonst
  misst man die Flussufer mit, die von der Änderung gar nicht betroffen sind.
- Verglichen wird `shore = smoothstep(0.09, 0.16, max(stream, g)) · (1 − wet)`,
  wobei `wet` je Fassung aus ihrer eigenen `lakeMask` kommt:
  - `main`: `max(smoothstep(0.16, 0.36, g), smoothstep(0.015, 0.05, pond))`
  - Branch: `smoothstep(0.006, 0.02, pond) · smoothstep(0.04, 0.35, g)`
- Die Abdunklung im Bild ist `shore · 0.22`.

## Ergebnis

Beide Fassungen sehen dieselben 52.925 Seezellen (die Sim ist unverändert).

| | Saumband-Zellen | `shore > 0.5` | Σ `shore` | Ø Abdunklung im Band | max |
|---|---|---|---|---|---|
| `main`  | 10.266 | 116 | 131,6 | 0,28 % | 21,42 % |
| Branch  | 10.239 | 476 | 622,9 | 1,34 % | 22,00 % |

Mittleres `shore` nach Abstand vom Seerand (in Zellen):

| Abstand | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|
| `main`  | 0,02 | 0,01 | 0,01 | 0,02 | 0,01 | 0,01 |
| Branch  | 0,03 | **0,27** | 0,02 | 0,02 | 0,01 | 0,01 |

(Die Saumband-Größe unterscheidet sich um 27 Zellen, weil der Branch den
Fluss-Kanal mit dem Komponenten-Fade skaliert und damit ein paar Zellen anders
über die `stream ≥ 0.16`-Ausschlussgrenze fallen.)

## Deutung

Die naheliegende Vermutung — „der Saum um Seen wird breiter und durchgehend
voll" — ist **falsch**. Gemessen passiert etwas anderes:

1. In `main` fiel der Saum um Seen praktisch **aus**. Die Tiefen-Rampe ist am
   Ufer definitionsgemäß ≈ 0, also blieb `max(stream, g)` dort unter der
   Schwelle 0.09. Der Kommentar im Shader verspricht „Flüsse und Seen bekommen
   ein Ufer statt einer harten Farbkante" — eingelöst wurde das nur für Flüsse.
2. Der Branch lässt den Saum um Seen **überhaupt erst entstehen**, und zwar als
   dünnen Ring auf dem **2. Zellring** vom Seerand (0,27 statt 0,01) — genau die
   Reichweite des zweiten Blur-Durchgangs des Gates.
3. Die Größenordnung bleibt klein: 476 von 10.239 Bandzellen (4,6 %) über
   `shore > 0.5`, mittlere Abdunklung im ganzen Band 1,34 % statt 0,28 %.

Damit ist die Schwelle 0.09/0.16 **nicht** nachkalibrierungs-bedürftig: sie
liefert am Gate erstmals das Verhalten, das dieser Block ohnehin beschreibt. Was
fehlte, war nicht die Kalibrierung, sondern die Notiz, dass der Kanal seine
Bedeutung gewechselt hat — die steht jetzt im Shader.
