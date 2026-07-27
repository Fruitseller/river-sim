# River-Baseline: objektive Messung (Seed 1337, Default-SimConfig, n = 640)

Headless gemessen mit einem temporären XCTest (`RiverBaseline`, nach der Messung
wieder entfernt). Reine Messung — **keine** Produktionsänderung. Zweck: einen
objektiven Nullpunkt festhalten, damit spätere Änderungen belegbar besser werden.
Alle Zahlen aus einem Release-Lauf (`swift test -c release`), Kanal-Definition wie
im Renderer (`SimNode.waterFieldBytes`): Landzelle mit `area / cellArea >= 30`.

## A) Drainage-Churn — „Flüsse springen mit hoher Geschwindigkeit"

Aus dem eingeschwungenen 20k-Jahr-Zustand: Empfänger-Netz snapshotten, **einen**
Schritt der Größe dt machen, `churn = 1 − receiverAgreement` messen (Anteil der
Landzellen, deren Abfluss-Nachbar sich geändert hat).

| dt (Jahre) | Churn (Anteil Landzellen mit geändertem Empfänger) |
|-----------:|:--------------------------------------------------:|
|         10 | 0.2725 |
|         50 | 0.2725 |
|        100 | 0.2725 |
|        240 | 0.2725 |
|       1000 | 0.2725 |

**Interpretation:** Der Churn ist über **alle** Schrittgrößen bis auf vier
Nachkommastellen identisch (0.2725). Das ist der Smoking-Gun für Framerate-
Kopplung: ein Schritt wirft ~27 % des Kanalnetzes um — **egal ob 10 oder 1000
Jahre vergehen**. Die Umverteilung ist also nicht proportional zur Zeit, sondern
ein fixer Sprung pro `computeFlow`. Im Echtzeit-Zeitraffer (viele winzige dt pro
Sekunde) heißt das: das Netz wird bei jedem Frame um denselben ~27 %-Betrag
durchgeschüttelt → sichtbares „Springen mit hoher Geschwindigkeit". Ursache ist
strukturell (D8-steilster-Abstieg entscheidet in flachen/gleich-steilen Zonen bei
minimaler Höhenänderung neu), nicht die Menge der Erosion.

## B) Kanal-Karten-Dynamik — „keine sichtbare Dynamik / keine Arme"

Lauf 20k → 120k in 1000-Jahr-Schritten. Kanalzellen-Zahl über die Zeit und
Jaccard-Ähnlichkeit der Kanal-Menge zum jeweils vorigen Snapshot (hoch = statische
Flüsse). `churn` = Empfänger-Änderung zum vorigen Snapshot.

| Jahr   | #Kanalzellen | Jaccard (vs. vorher) | Churn (vs. vorher) |
|-------:|-------------:|:--------------------:|:------------------:|
|  20000 |        33906 |          –           |         –          |
|  30000 |        33184 |        0.3747        |       0.2733       |
|  40000 |        32441 |        0.3764        |       0.2684       |
|  50000 |        32236 |        0.3798        |       0.2653       |
|  60000 |        32314 |        0.3811        |       0.2637       |
|  70000 |        31797 |        0.3851        |       0.2624       |
|  80000 |        33069 |        0.3833        |       0.2602       |
|  90000 |        32747 |        0.3822        |       0.2615       |
| 100000 |        31745 |        0.3837        |       0.2622       |
| 110000 |        31819 |        0.3971        |       0.2580       |
| 120000 |        29726 |        0.4668        |       0.2038       |

- Kanalzahl über den Lauf: min = 29726, max = 33906, erste = 33906, letzte = 29726
- Jaccard aufeinanderfolgender 1000-Jahr-Snapshots: Mittel = 0.3865, min = 0.3715, max = 0.4668

**Interpretation:** Zwei gegenläufige, gleich unbefriedigende Signale. Die
**Gesamtstruktur ist statisch**: die Kanalzellen-Zahl bleibt über 100k Jahre nahezu
konstant (~33k → ~30k, −12 %, kein Wachsen/Verzweigen, keine neuen Arme). Die
Kanäle **entwickeln sich nicht**, sie zittern nur. Zugleich ist die Jaccard-
Ähnlichkeit pro 1000 Jahre niedrig (~0.39), d. h. von einem Snapshot zum nächsten
sind nur ~39 % der Kanalzellen dieselben — passend zum Churn in (A): das Netz
flackert von Schritt zu Schritt an denselben Stellen hin und her, ohne dass echte
neue Läufe/Arme entstehen oder wandern. Ergebnis genau wie beklagt: viel
Pixel-Rauschen, aber keine sichtbare Fluss-**Dynamik**.

## C) Braiding mit D8 unmöglich — strukturelle Bestätigung

| Kennzahl | Wert |
|----------|-----:|
| Kanalzellen (bei 20k) | 33906 |
| Split-Zellen (Ausgangsgrad > 1, mögliche Braid-Quelle) | **0** |
| Konfluenzen (Eingangsgrad ≥ 2, normale Baum-Zuflüsse) | 1911 |
| max. Eingangsgrad | 4 |
| Empfänger-Ketten-Schleifen / Zyklen | **0** |

**Interpretation:** Bestätigt strukturell. Bei Single-Flow-D8 hat jede Landzelle
**genau einen** `receiver` → der Ausgangsgrad ist überall ≤ 1, es gibt 0 Split-
Zellen und 0 Zyklen. Das Kanalnetz ist ein reiner Wald (Baum): Zuflüsse dürfen
zusammenlaufen (1911 Konfluenzen, max. 4 Zuflüsse pro Zelle — normal), aber ein
Lauf kann sich **nie** in zwei Arme teilen, die sich später wieder vereinen.
Verflechtung/Anabranching (Braided River, Deltas mit Nebenarmen) ist mit diesem
Abfluss-Modell prinzipiell nicht darstellbar — dafür bräuchte es Multiple-Flow-
Direction bzw. eine explizite Nebenarm-Repräsentation.
