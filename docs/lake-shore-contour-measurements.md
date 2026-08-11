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

## Altarm-Enden

Zweite Sorge aus demselben Review: `lakeMask` ist von einem ODER
(`max(Kanal, pond)`) zu einem UND (`Kontur · Gate`) geworden. Das Altarm-Overlay
(`oxb` in `SimNode.waterFieldBytes`) setzt schon ab `pond > 0.003` ein, die neue
Farb-Kontur erst ab `pond ≥ 0.006` und voll ab 0.02 — die flachen Enden eines
Altarms müssten also blasser werden oder ganz verschwinden.

### Seed-Suche

Altarme brauchen Mäander-Cutoffs, und die sind stark seed-abhängig. Gezählt
wurden die Zellen mit `oxb > 0` (temporäre Sonde `SimNode.debugOxbowField()`):

| Seed | 10k | 20k | 30k |
|------|-----|-----|-----|
| 1337 | 1703 | 4292 | **6068** |
| 1    | 102 | 101 | 2 |
| 7    | 11 | 83 | 18 |
| 42   | 64 | 200 | 599 |

Nur Seed 1337 liefert Altarme mit nennenswerter Deckkraft (`oxb > 0.35`: 2635
Zellen bei 30k; bei den anderen Seeds **null**). Gemessen wurde deshalb bei
**Seed 1337, Jahr 30.000**, beschränkt auf die 6068 Zellen, die das Overlay
tatsächlich anfasst.

### Ergebnis

Vorab bestätigt: Höhen und Seespiegel sind zwischen `main` und Branch
**bitgleich** — das Abnahmekriterium „Sim-Physik bit-identisch" aus Issue #32
ist damit gemessen, nicht nur behauptet.

Verglichen wird das sichtbare Wasser `wet = max(riverMask, lakeMask)`, denn der
Fluss-Kanal malt an denselben Stellen mit.

| Zellen | `wet` main | `wet` Branch | Δ |
|---|---|---|---|
| alle 6068 Altarm-Zellen | 0,917 | 0,929 | +0,012 |
| davon `pond ≤ 0.03` (2245) | 0,789 | 0,807 | +0,018 |
| davon `pond ≤ 0.02` (1514) | 0,742 | 0,739 | −0,003 |

Verteilung über alle 6068 Zellen: **5792 praktisch unverändert** (|Δ| ≤ 0,25),
200 deutlich sichtbarer, 76 blasser. Ganz trockene Altarm-Zellen (`wet < 0.05`):
**271 in `main`, 174 im Branch** — der Branch zeigt also *mehr* Altarm, nicht
weniger.

Nach Wassersäule aufgeschlüsselt zeigt sich der vermutete Effekt nur in einem
schmalen Band und schwach:

| `pond` | 0–0.006 | 0.006–0.010 | 0.010–0.015 | 0.015–0.020 | 0.020–0.030 | > 0.030 |
|---|---|---|---|---|---|---|
| n | 462 | 166 | 339 | 547 | 731 | 3823 |
| Δ `wet` | −0,002 | +0,001 | **−0,054** | +0,027 | +0,062 | +0,007 |

### Deutung

Die Sorge war unbegründet, aus zwei Gründen:

1. Altarme liegen auf oder neben ehemaligen Läufen, also dort, wo der
   **Fluss-Kanal** ohnehin malt. `wet` nimmt das Maximum aus beiden — die
   Änderung an `lakeMask` wird zum größten Teil verdeckt.
2. 3823 der 6068 Zellen haben `pond > 0.03`, sind also echtes Wasser und
   liegen weit über der Kontur-Rampe.

Übrig bleibt eine leichte Abschwächung im Band `pond` 0,010–0,015 (−0,054 auf
339 Zellen), die von den Zugewinnen in den Nachbarbändern mehr als aufgewogen
wird. Kein Handlungsbedarf.
