# Ein Bett-Funnel für alle Bett-Schreiber, mit Gletscher-Gate

Die Bett-Regel (erst Sediment, dann Fels abtragen; `h = rock + sed` halten) und das Gletscher-Gate stehen genau einmal, in `Terrain.Bed.erode(_:_:)` bzw. `Terrain.Bed.deposit(_:_:)` (Issues #81, #96). Jede Bett-Schreibung der Simulation läuft darüber, damit ein künftiger Bett-Pass Regel und Gate nicht vergessen kann. Wer die Regel ändert, ändert genau diese Stelle (Wächter: `SimCoreTests/BedFunnel.swift`).

## Gletscher-Gate (Issue #35)

Unter dem Eis gehört das Tal dem Gletscher: kein fluvialer Abtrag, keine fluviale Ablage, sonst carvt dasselbe Tal ein zweites Mal, mit fluvialem statt glazialem Querschnitt. Gesperrte Zellen liefern Rückgabe 0. Bei leerer Maske (kein Eis oder `iceEnabled = false`) ist `bed.locked` `nil`, der Zweig fällt weg, alles rechnet bit-identisch zum Stand vor #35.

Seit #96 steht das Eis-Gate nicht mehr in der Gate-Kette der Auslass-Inzision. Eis-Zellen laufen dort durch die Kette, bekommen ein normales Gate, die serielle Schleife rechnet ihre Formel, und der Funnel verwirft den Abtrag. Das Ergebnis ist bit-identisch (nur Formel-Arbeit mehr auf vergletscherten Zellen).

Die Sperrmaske ist beim Terrain-Funnel `underIce`. Die Tropfenschleife (`Hydraulic.erode`) schreibt über dieselbe Regel mit einer strengeren Maske aus Eis UND Gürtelbett (`beltDropletGate`, Issues #174/#187), weil ihr Radial-Pinsel das Bett wandernder Mäanderläufe nicht aufreißen darf.

## Aufrufer und Ausnahmen

Über den Funnel schreiben: Mäander-Bett-Carve und laterale Ufer, Altarm-Pfropf und -Verlandung, Braid-Fracht, Auen-Aggradation, `channelCarve`, der Testpfad `transportLimited`, die Auslass-Inzision (Ziel-Fassung) und der Pinsel samt Nachzug (`applyDelta`/`applyRegenDelta`). Der Pinsel ist bewusst KEINE Ausnahme: ein Hieb auf vergletschertem Grund bleibt wirkungslos, und am Eis-Sicht-Modell ändert sich nichts, bis die Zunge schmilzt.

Zwei begründete Ausnahmen laufen bewusst auch auf vergletscherten Zellen und schreiben selbst: Hangdiffusion (`hillslopeDiffusion`, `diffusionPass`) und Brandung (`wavePass`). Beides ist kein fluvialer Abtrag: das Bodenkriechen trägt die Höhenänderung der Nachbarn auch auf die Eiszelle, und ein Abschalten am Gate ließe den Trog mit unbehandelten Kanten zurück (`docs/glacier-measurements.md` §I.1); dieselbe Begründung trägt die Brandung an der Fjordküste. Das Eis selbst schreibt sein Bett über ein eigenes Erosionsgesetz (`updateIce`, Flux-Modell `E = K·q^m·S`) und ist kein Funnel-Kandidat.

Nicht abgelegte Fracht auf gesperrten Zellen: beim Terrain-Funnel gilt sie als exportiert (Masse-Erhaltung ist hier keine Invariante); `transportLimited` reicht sie talwärts weiter, die Tropfen führen sie in Suspension weiter. Das entscheidet der Aufrufer.

## Ziel-Fassung `erodeCellTo`

Relaxations-Pässe rechnen eine eigene gerundete Zielhöhe, die Auslass-Inzision `hNew = (h + f·hr)/(1+f)`. Der naive Weg `h −= (h − hNew)` ist nicht bit-gleich zu `hNew`: der Rundtrip `h − fl(h − hNew)` weicht im aggressiven Regime (Schritt trägt mehr als die halbe Höhe ab, große Becken-Auslässe) in der Mehrheit der Fälle um 1 ulp ab. Die Ziel-Fassung setzt deshalb die Zielhöhe EXAKT und zieht die Zerlegung über `a = h − target`, bit-identisch zur Ausschreibung vor #96. Der Wächter prüft sie auf exakte Zielhöhe, nicht auf Parität mit der Betrags-Fassung.

Die Fels-Hebung `raiseRockCell` ist die dritte Bett-Bewegung, die der Pinsel braucht (`sculpt`/`roughen` heben Fels, `applyRegenDelta` trägt Regeneration als Fels ein): Gestein, keine Zerlegung, dasselbe Gate.

## Die `Bed`-Sicht und Exklusivität

`Bed` ist die Roh-Puffer-Sicht auf `h`/`sed`/`rock` plus Sperrmaske. Grund: `meanderStamp`, `braidPass` und die Altarm-Pässe laufen über 692k Zellen bzw. 30k Knoten und adressierten die Felder vor Perf-Runde 3 über die Klassen-Property, weil ein Roh-Zeiger mit dem Funnel kollidiert wäre; das kostete gemessen ~4,5 % des Schritts allein in der Swift-Laufzeit (`swift_beginAccess`/`AccessSet::insert`, `docs/perf-measurements.md`). Mit der Sicht öffnet ein Pass die Felder einmal.

Solange `withBed` offen ist, darf derselbe Pass `h`/`sed`/`rock`/`underIce` nicht über die Klassen-Property anfassen, auch nicht lesend (`bilinearH`), und auch nicht die Zwei-Argument-Adapter `erodeCell(_:_:)`/`depositCell(_:_:)`, die die Sicht selbst öffnen. Der Compiler meldet das nicht, die Laufzeit bricht gemessen mit "Fatal access conflict detected" ab, auch im `-O`-Build. Wer eine Sicht offen hat, ruft die Drei-Argument-Fassung; `meanderStamp` ruft deshalb `Terrain.bilinear` direkt auf dem Zeiger. Reine Lesezugriffe (`underIce` neben dem Funnel) schließen sich nicht aus.

Die Zwei-Argument-Adapter enthalten keine Regel (bis #81 war das eine zweite, von Hand synchron gehaltene Ausschreibung). Aufrufer sind nur `transportLimited` (Testpfad) und die geparkte `floodplainAggradation`, die in gegenläufigen Zweigen von `step()` liegen; kein Produktionspass, das Öffnen je Aufruf kostet nichts (`docs/perf-measurements.md` §K). Beabsichtigter Unterschied: die Bed-Fassung schreibt über Roh-Zeiger, ein `k` außerhalb des Feldes trifft keine Bereichsprüfung mehr; beide Aufrufer beziehen `k` aus `order` bzw. eigenen Schleifengrenzen.

Abweichung vom Grundsatz: `fillShallowPonds` schreibt `h`/`sed` direkt und prüft das Eis selbst (s. Issue zur Pfützen-Verlandung).

## Testfenster

`setBedForTests` setzt Bett und Eismaske direkt, damit der Funnel-Wächter synthetische Randfälle trifft (Zellen ohne Sediment, knapp zu wenig, Eis auf einem Teil). Abgeleitete Felder (`hf`, `area`, `receiver`, `order`, `isChannel`, `ice`/`snow` …) werden NICHT nachgezogen; Tests, die einen Pass aufrufen, bauen ihren Zustand über eigene Läufe oder `restore(_:)` auf. Der Gletscher-Wächter des Grid-Pfads (`Glacier.testNoFluvialErosionUnderIceOnTheGridPath`) ruft `transportLimited` einzeln über `transportLimitedForTests`, weil ein Zwei-Arm-Vergleich über `step()` wegen des mitlaufenden `diffusionPass` (festes kappa) das Bodenkriechen statt des Gates messen würde (§I.1).

Betrifft: `Terrain.Bed`, `Terrain.withBed`, `Terrain.erodeCell`, `Terrain.depositCell`, `Terrain.erodeCellTo`, `Terrain.raiseRockCell`, `Terrain.applyDelta`, `Terrain.outletIncision`, `Terrain.meanderStamp`, `Terrain.setBedForTests`, `Terrain.transportLimitedForTests`, `SimCoreTests/BedFunnel.swift`
