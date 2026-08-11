# Welt speichern und laden (Issue #8)

Stand: August 2026 · Format **Version 3** · Code: `SimCore/Sources/SimCore/WorldSnapshot.swift`,
Inventar (`TerrainState`) am Ende von `SimCore/Sources/SimCore/Terrain.swift`,
Wächter: `SimCore/Tests/SimCoreTests/WorldSnapshotTests.swift`.

## Die Invariante, an der alles hängt

Eine Welt ist gespeichert, wenn sie **bit-identisch weiterläuft**. Nicht „sieht
gleich aus": das System ist chaotisch (Tropfenpfade, Becken-Rollenwechsel,
Mäander-Cutoffs), ein einziges fehlendes Feld oder ein verlorenes ULP driftet
über wenige Schritte in eine sichtbar andere Landschaft. Der Wächter
`testRoundTripContinuesBitIdentically` vergleicht deshalb nach
`speichern → laden → n Schritte` **jedes** Feld bitweise gegen eine durchgehend
simulierte Welt. Gegenprobe zur Empfindlichkeit: setzt man in `Terrain.restore`
z. B. `dropsEmitted = 0` (der Zähler ist die laufende Nummer des nächsten
Tropfens und legt damit seinen Startpunkt fest), schlägt der Test in allen
Höhenfeldern fehl — genau so soll er sich verhalten.

Die **Mäander-Historie** hat einen eigenen Round-Trip
(`testMeanderHistorySurvivesRoundTrip`): im Produktionspfad entsteht bei
Testauflösung so schnell kein Cutoff (gemessen n=256, 800 Jahre: 60 Läufe,
0 Altarme), also läuft dieser Wächter auf der gepinnten Kopplungs-Config der
Mäander-Kerntests, bis mindestens zwei Altarme MIT Alter existieren — und prüft
dann Datei-Identität und Weiterlauf.

## Was eine Welt ist (Inventar)

`TerrainState` ist die eine Stelle, an der das steht. Aufnahmekriterium: alles,
was ein `step()` LIEST, bevor es es schreibt — plus alles, was Rendering und
Diagnose sofort nach dem Laden brauchen.

| Gruppe | Felder |
| --- | --- |
| Gelände | `h`, `rock`, `sed`, `upliftBase` |
| Klima | `rain`, `rainWeight` |
| Klima-Vertikale (#33) | `temperature`, `snow`, `ice` |
| Lithologie (#12) | `lithHardness`, `lithErodeK`, `lithBed`, `lithProvince` |
| Vegetation (#4/#7) | `veg`, `vegClass`, `riparian`, `heightBands` |
| Entwässerung | `hf`, `receiver`, `order`, `floodParent`, `area`, `areaMFD` |
| Seen/Wasserhaushalt (#11) | `waterLevel`, `lakeBalance`, `saltCrust`, `endorheicBasin`, `endorheicInflow`, `playaBed` |
| Fluss-Gedächtnis | `streamMap`, `streamRate`, `isChannel` |
| Mäander (#7) | Zentrumslinien (Knoten + Abfluss je Knoten), Altarme, Altarm-Alter |
| Störung/Regeneration (#26) | `disturb`, `regenPending`, `disturbActive` |
| Zähler | `years`, `seed`, `stepCount`, `flowStepCount` |

**Nicht** gespeichert werden reine Arbeitspuffer, die ihr Pass vor dem ersten
Lesen vollständig überschreibt (geprüft: `vegScratch`, `basinSeen`, `basinCells`,
`basinSlots`, `orderPos`, `visited`, `scratch`, `qs`, `trackBuf`, `pondSeen`,
`heap`, die Bin-Puffer des Mäander-Cutoff-Index) sowie alles, was rein aus Seed
oder Config folgt (`noise`-Permutationstabelle, `vegTypeFactor`, `mfdMinA`,
`mfdFlatCell`).

Bewusst großzügig aufgenommen sind die Felder, die `computeFlow` im nächsten
Schritt ohnehin neu ableitet (`hf`, `receiver`, `area`, `areaMFD`, `order`,
`floodParent`, `rain`, `rainWeight`, `lithHardness`, `lithErodeK`,
`temperature`, `endorheicBasin`, `endorheicInflow`, `playaBed`). Zwei Gründe:

1. Der erste gerenderte Frame nach dem Laden ist damit korrekt, ohne einen
   Sim-Schritt zu erzwingen (Flüsse, Farben, Diagnose).
2. „Geladener Zustand == gespeicherter Zustand" wird feldweise prüfbar statt nur
   „läuft gleich weiter". Ein Neu-Ableiten beim Laden wäre außerdem gefährlich:
   `computeFlow()` mit dt = 0 SNAPPT den Bilanz-Seespiegel abflussloser Becken
   auf seinen Zielstand (so startet die Generierung) — genau das darf beim Laden
   nicht passieren.

### Warum `ice` schon in Version 3 steht, obwohl es niemand schreibt

Das Format kennt bewusst keine Migration — jeder Versionssprung macht alle
vorhandenen Spielstände ungültig. Die Klima-Vertikale (#33) und der Eisfluss
(#35) sind ein Vorhaben in zwei Tickets; sie zwei Sprünge kosten zu lassen wäre
zweimal derselbe Preis für dieselbe Sache. Das vollständige Feldinventar der
Kryosphäre ist deshalb VOR dem ersten Sprung recherchiert worden
(`docs/research-climate-cryosphere.md` §6): Temperatur, Schnee, Eisdicke — mehr
braucht auch das gewählte Flux-Eismodell nicht, weil der Eisfluss je Schritt aus
`order` akkumuliert wird und damit Arbeitsspeicher ist.

In #33 ist `ice` konstant 0 und kostet dank Konstant-Kodierung 5 Byte je Welt.

### Warum `waterLevel` und `lakeBalance` echter Zustand sind

Beide folgen ihrem Ziel nur ratenbegrenzt (`lakeLevelResponseYears`,
`endorheicResponseYears`). Fehlten sie in der Datei, würden die Seespiegel nach
dem Laden über hunderte Jahre einschwingen oder im ersten Frame springen — das
ist Abnahmepunkt 5 und hat seinen eigenen Wächter
(`testWaterLevelIsImmediatelyCorrectAfterLoad`, prüft auch, dass der ABSTAND
`waterLevel − hf` erhalten bleibt: das ist das Gedächtnis).

## Kodierung

Eigenes Binärformat, Little-Endian, Zahlenfelder als Blocktransfer.

* **Bit-genau:** gespeichert wird das IEEE-754-Bitmuster jedes `Double`, keine
  Dezimaldarstellung. Determinismus verträgt keine Textkonversion.
* **Größe/Zeit:** eine Welt sind ~30 Felder à n² Werte (n = 832 → 692 224 Zellen,
  5,5 MB je `Double`-Feld). JSON oder XML-Plist bräuchten das Drei- bis Vierfache
  und einen Parser je Zahl; binäres Plist ist bit-genau, verpackt aber jedes
  Element als eigenes Objekt — bei 17 Mio. Zahlen unbrauchbar.
* **Konstante Felder** (überall derselbe Wert — der Normalfall für `disturb`,
  `regenPending`, `isChannel` … in einer unangetasteten Welt) stehen als EIN Wert
  in der Datei. Verlustfrei, nur weniger Bytes.

Die **Config** liegt dagegen als binäres Plist (Codable-synthetisiert) im
Container: sie ist klein, und die Synthese nimmt automatisch jede neue
Stellschraube aus `Config.swift` mit. Eine vergessene Stellschraube wäre ein
stiller Determinismus-Bruch — deshalb steht die Konformität `Codable, Equatable`
direkt an `SimConfig` (Swift synthetisiert nur in der Ursprungsdatei) und der
Wächter `testConfigSurvivesEncodingExactly` vergleicht die GANZE Config, nicht
einzelne Felder. `ErosionFilter.Params` braucht eine handgeschriebene Kodierung,
weil es Tupel führt (Tupel sind nicht `Codable`).

Dateigröße gemessen (`testConstantFieldsAreStoredCompactly` gibt den Wert aus):
n = 128 (16 384 Zellen) = 2 979 301 Byte, also **181,8 Byte je Zelle** → n = 832
ergibt **≈ 120 MB**. (Vor der Klima-Vertikalen, Version 2: 165,8 Byte/Zelle ≈
109 MB — `temperature` und `snow` kommen roh dazu, `ice` ist konstant 0 und
kostet 5 Byte.) Das ist der Preis der Vollständigkeit; Kompression wäre
möglich (zlib), würde aber eine System-Abhängigkeit ins reine Swift-Package
holen — bewusst nicht getan, in der ROADMAP notiert.

### Aufbau

```text
Kopf (28 Byte):
  [0..8)   Magic "RIVERSIM"
  [8..12)  u32 Formatversion
  [12..20) u64 Länge der Nutzdaten
  [20..28) u64 FNV-1a-64 der Nutzdaten
Nutzdaten:
  u32 Länge + Bytes   binäres Plist der SimConfig
  u32 seed · f64 years · u64 dropsEmitted · f64 dropCarry
  u32 flowStepCount · u8 disturbActive
  8 × f64             Höhenbänder
  u32 Feldzahl, je Feld:
    u32 Länge + Name · u8 Typ (0 f64 · 1 i32 · 2 u8 · 3 bool)
    u8 Kodierung (0 roh · 1 konstant) · u32 Elementzahl · Nutzdaten
  u32 Kanalzahl, je Kanal: u32 Knotenzahl · Knoten (f64 x, f64 z) · f64 Abfluss
  u32 Altarmzahl, je Altarm: u32 Knotenzahl · Knoten; danach f64 Alter je Altarm
```

Feldnamen reisen mit: Umbenennen oder Umsortieren im Inventar ist damit ein
erkennbarer Fehler und kein stiller Feldversatz.

## Versionierung und Ablehnung (Abnahmepunkt 2)

`WorldSnapshot.version` wird bei **jeder** Änderung an Inventar, Reihenfolge oder
Kodierung erhöht. Es gibt bewusst keine Aufwärts-Migration: eine Datei mit
abweichender Version wird abgelehnt (`SnapshotError.unsupportedVersion`), nicht
irgendwie interpretiert. Die Version wird **vor** der Prüfsumme geprüft, damit
eine alte Datei „andere Programmversion" meldet und nicht „defekt".

Weitere kontrollierte Ablehnungen, alle mit deutscher Meldung für den Dialog:

| Fall | Fehler |
| --- | --- |
| fremde/leere Datei | `badMagic` |
| abgebrochen geschrieben | `truncated` |
| gekipptes Bit | `checksumMismatch` (FNV-1a-64 über die Nutzdaten) |
| Config-Feld fehlt | `configDecodingFailed` |
| Feld umbenannt/vertauscht | `fieldNameMismatch` / `fieldCountMismatch` |
| Feldlänge passt nicht zu `n` | `fieldLengthMismatch` |

Geschrieben wird **atomar** (`Data.write(options: .atomic)` → temporäre Datei +
`rename`): ein Absturz mitten im Speichern lässt den vorherigen Spielstand
intakt.

## Config und Seed (Abnahmepunkt 4)

Beides reist mit; die **Datei-Config ist autoritativ**. Eine geladene Welt läuft
mit exakt der Config, mit der sie gespeichert wurde — auch wenn `SimConfig()`
seither andere Defaults hat.

*Begründung:* Feldlängen (`n`), Kalibrierung und Bit-Determinismus hängen
zusammen. Ein Merge aus Datei- und Programm-Config wäre eine dritte, nirgends
getestete Konfiguration — und würde die Abnahme-Invariante genau dann brechen,
wenn jemand eine Stellschraube gedreht hat. *Folge:* Änderungen an
`SimConfig()`-Defaults wirken nur auf NEUE Welten. Wer eine alte Welt mit neuer
Physik weiterlaufen lassen will, braucht eine bewusste Migration.

`Terrain` wird beim Laden deshalb ERSETZT (nicht überschrieben): `SimNode.terrain`
ist `var`, und der Konstruktor `Terrain(allocating:seed:)` legt nur Puffer an,
ohne zu generieren (der Snapshot bringt jedes Feld mit).

**Eine Grenze zieht das Frontend:** eine laufende Godot-Sitzung ist auf EINE
Geometrie festgelegt — Höhen-/Farb-/Wasser-Texturen und der Höhen-Cache haben
n × n Einträge; Mesh-Größe und -Tessellation, Kamera-Distanz, Wasserebene,
Pinsel-Ring und die Welt→Zelle-Umrechnung von Raycast und Werkzeugen
(`half`, `step`, `cell_area`) hängen an `world`. `Main.gd` prüft deshalb vor dem
Laden BEIDE Werte über `SimNode.worldFileGridSize()` und
`SimNode.worldFileWorldSize()` (lesen nur Kopf + Config, nicht die 100 MB
Felder) und lehnt eine abweichende Welt ab, BEVOR die laufende ersetzt ist.

`n` allein genügt nicht: bei gleicher Auflösung, aber anderer Weltgröße ändert
sich die Zellgröße (`world/(n−1)`), und die geladene Simulation würde in anderen
Weltkoordinaten laufen als Darstellung und Pinsel. Dass `n` und `world` in
diesem Projekt nur zusammen geändert werden, ist eine Konvention für den
QUELLCODE — die Datei kann jede Kombination mitbringen, weil ihre Config beim
Laden autoritativ ist.

*Ablehnen statt umbauen* ist bewusst gewählt: die abhängigen Render- und
Interaktionsstrukturen nach dem Laden vollständig neu aufzubauen wäre ein
zweiter, nur mit fremden Dateien überhaupt erreichbarer Aufbaupfad neben
`_setup_scene` — mehr Code und mehr Bruchfläche als der Fall wert ist. Die
Entscheidungslogik steckt in der reinen Funktion
`Main.gd._world_geometry_mismatch()` und wird im Godot-Smoke-Test ohne Szene
geprüft (passende Geometrie, abweichendes `n`, abweichendes `world`,
unlesbare Datei).

Der Sim-Kern selbst kann jede Geometrie laden
(`testDeviatingConfigAndSeedTravelWithTheWorld` speichert mit abweichendem `n`
UND `world` und lädt reproduzierbar).

## Bedienung

* Knopf **💾 Speichern** / Taste **F5** → `user://saves/welt.rsworld`
* Knopf **📂 Laden** / Taste **F9**; nach dem Laden ist die Sim **pausiert**.
* Fehler erscheinen als Dialog mit der wörtlichen Meldung aus SimCore.
* Ein fester Speicherplatz statt Dateidialog: das Spiel führt genau eine Welt.
  Mehrere Slots sind eine eigene UI-Frage (ROADMAP).

Der Godot-Smoke-Test (`game/tests/smoke.gd`) deckt die Brücke ab: Datei
entsteht, Zustand kommt zurück (Jahr + Höhensumme), eine Datei mit fremder
Formatversion wird abgelehnt, ohne die laufende Welt anzutasten.
