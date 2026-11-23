# Welt-Speicherformat: eigenes Binärformat, Datei-Config autoritativ, keine Migration

Das Weltformat (Issue #8) schreibt den vollständigen Sim-Zustand (`TerrainState`, Inventar in `Terrain.swift`) plus Seed und Config in eine versionierte Datei.

## Warum ein eigenes Binärformat

Der Zustand besteht aus ~30 Feldern à n² `Double` (n = 832: 692.224 Zellen, 5,5 MB je Feld; eine Welt ≈ 120 MB, gemessen 182 Byte/Zelle, vor den Kryo-Feldern aus #33 109 MB / 166 Byte). Zwei Anforderungen bestimmen die Kodierung:

1. Bit-Genauigkeit: ein geladener Zustand muss bit-identisch weiterlaufen; ein verlorenes ULP divergiert über das chaotische System messbar (dieselbe Erfahrung wie bei `powFast`). Gespeichert wird das IEEE-754-Bitmuster.
2. Größe und Zeit: JSON braucht ~3× so viele Bytes und einen Parser je Zahl (120 MB → ~380 MB Text), Plist-XML ebenso; binäres Plist wäre bit-genau, verpackt aber jedes Element als eigenes Objekt (für 17 Mio. Zahlen unbrauchbar).

Deshalb roher Block-Transfer der Zahlenfelder (`memcpy`-Tempo, Little-Endian) in einem selbstbeschreibenden Container. Little-Endian ist Teil des Formats; elementweises Byte-Swapping wäre bei 17 Mio. Werten die Laufzeit. Alle Zielplattformen (x86_64, arm64) sind LE; auf Big-Endian bricht der Zugriff kontrolliert ab (`unsupportedHostByteOrder`). Ein Feld mit lauter gleichen Elementen wird als `constant` mit einem Element geschrieben; das ist der Normalfall für abschaltbare oder ruhende Physik (`disturb`, `regenPending`, `isChannel` …) und spart je Feld 5,5 MB ohne Rundung. Gleichheit dabei über das Bitmuster: ein `Double`-Vergleich würde −0,0 und 0,0 verschmelzen und NaN nie gleich finden.

Die Config ist klein und ändert ihre Felder häufig; sie liegt als binäres Plist (Codable-synthetisiert, `Double` exakt 8 Byte) im Container. `SimConfig`, `HydraulicParams` und `HeightBands` sind Codable-synthetisiert (Konformität bei der Typdeklaration, weil Swift die Synthese nur in der Ursprungsdatei erzeugt): jede neue Stellschraube reist automatisch mit, eine vergessene wäre ein stiller Determinismus-Bruch. `Equatable` ist der Wächter: der Round-Trip-Test vergleicht die ganze Config. Eine fehlende Stellschraube in einer alten Datei ist ein harter Dekodier-Fehler statt eines stillen Defaults. Einzige Ausnahme ist `ErosionFilter.Params` (Tupel, handgeschrieben; Wächter `WorldSnapshotTests.testEveryPreErosionParameterIsSerialisedAndCompared`).

## Aufbau

```text
Kopf (28 Byte, ungeprüft lesbar, für die Versionsprüfung ohne Vollladen):
  [0..8)   Magic "RIVERSIM" (ASCII)
  [8..12)  u32 Formatversion
  [12..20) u64 Länge der Nutzdaten
  [20..28) u64 FNV-1a-64 der Nutzdaten
Nutzdaten:
  u32 Länge + Bytes  binäres Plist der SimConfig
  u32 seed · f64 years · u64 dropsEmitted · f64 dropCarry
  f64 beltCouplingCarry · u32 flowStepCount · u8 disturbActive
  8 × f64            Höhenbänder (Issue #4)
  u32 Feldzahl, je Feld:
    u32 Länge + Name (ASCII) · u8 Typ (0 f64 · 1 i32 · 2 u8 · 3 bool)
    u8 Kodierung (0 roh · 1 konstant) · u32 Elementzahl · Nutzdaten
  u32 Kanalzahl, je Kanal: u32 Knotenzahl · Knoten (f64 x, f64 z) · f64 Abfluss
  u32 Altarmzahl, je Altarm: u32 Knotenzahl · Knoten; danach f64 Alter je Altarm
```

Länge und Prüfsumme im Kopf lassen eine abgebrochene Speicherung (Absturz, volle Platte) beim Laden auffallen. Prüfreihenfolge beim Lesen: erst die Marke, dann die Länge (eine fremde, womöglich winzige Datei heißt „keine river-sim-Welt", nicht „unvollständig"); die Version VOR der Prüfsumme (eine Datei aus einer anderen Version heißt „falsche Version", nicht „defekt"). Feldnamen reisen mit: Umbenennen oder Umsortieren im Inventar ist ein erkennbarer Fehler statt eines stillen Feldversatzes; die Reihenfolge der Inventartabellen ist die Dateireihenfolge. Die Prüfsumme ist FNV-1a 64 bit, bewusst keine Krypto-Hash (Datenintegrität, nicht Manipulation), über denselben Byte-Mixer wie der Zustands-Fingerabdruck.

Längen aus der Datei gehen nie direkt in `reserveCapacity`: eine gefälschte Knotenzahl würde Gigabytes anfordern, bevor der Längen-Check greift. Obergrenze ist, was im Rest der Datei stehen kann. Geschrieben wird atomar (temporäre Datei plus `rename`), damit ein Absturz den vorigen Spielstand intakt lässt.

## Config-Abweichung (Abnahmepunkt 4)

Die Datei-Config ist autoritativ: eine geladene Welt läuft mit exakt der Config, mit der sie gespeichert wurde, auch wenn der Programm-Default sich geändert hat. Feldlängen (`n`), Kalibrierung und Bit-Determinismus hängen zusammen; ein Mischen aus Datei- und Programm-Config wäre eine dritte, nirgends getestete Konfiguration. Alte Welt mit neuer Physik braucht eine bewusste Migration, keinen stillen Merge. Folge: Änderungen an `SimConfig()`-Defaults wirken nur auf neue Welten.

## Versionen

Bei jeder Änderung an Inventar, Reihenfolge oder Kodierung wird die Version um 1 erhöht; alte Dateien werden abgelehnt, es gibt bewusst keine Aufwärts-Migration. Auch wenn neue Config-Schlüssel eine alte Datei ohnehin undekodierbar machen, wird erhöht, damit der Nutzer die klare Versions-Meldung statt eines Plist-Fehlers sieht.

- 3 (#33): Kryo-Felder `temperature`, `snow` und `ice` gemeinsam, auch `ice`, das erst #35 beschreibt. Weil es keine Migration gibt, wäre jeder weitere Sprung eine zweite Runde ungültiger Spielstände; das vollständige Inventar der Klima-Vertikalen steht in `docs/research-climate-cryosphere.md` §6 und ist mit diesem Sprung abgeschlossen.
- 4 (#108): Kanal-Hebel `channelFlowMinCells`/`FullCells`, `channelDiffusionDamp`, `flowDepositDamp`, `puddleFillSkipsFlowCells`.
- 5 (#174): `rangeLandform`.
- 6 (#174, Paket B): Feld `barAge` und die Stellschrauben des Mäandergürtels.
- 7 (#187): Kopplung Gürtel ↔ Entwässerung (`meanderBeltCoupling` …).
- 8 (#174): `iceFirnTemp`.
- 9 (#174, Delta): `deltaTrapFraction` ff.
- 10 (#174): Restzeit des festen Gürtel-Kopplungstakts, Schalter für die geteilte Profil-Relaxation.
- 11 (#174, Gletscher): Lawinen-Abgang des Firns (`iceAvalancheSlopeLo` ff.).
- 12 (#187): `meanderBeltSillCutDepths`.

Betrifft: `WorldSnapshot`, `WorldSnapshot.version`, `WorldSnapshot.encode`, `WorldSnapshot.decode`, `WorldSnapshot.write`, `TerrainState`, `ErosionFilter.Params` (Codable-Extension)
