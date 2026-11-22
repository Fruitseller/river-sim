# Look E: Fluss als Korridor (Issue #239), Phase 1

Stand 2026-11-21, Zweig `look-e-corridor` auf `origin/main` (0783abf).

## Was gebaut ist

- **Querprofil je Lauf** (`SimCore/Sources/SimRender/RiverCorridor.swift`,
  `CorridorProfile`): 11 Spalten, Fuß und Uferkante auf dem Gelände, Böschung,
  Uferlinie, Bett, Thalweg. Tiefe aus der Wasserbreite, an Furten (Riffel aus
  `RibbonMesh.flows`) flacher. Im Bogen asymmetrisch: Prallhang schmal und
  steil, Gleithang breit und flach mit Kiesbank, Thalweg zum Prallhang.
- **Korridor-Mesh** (`RibbonMesh.corridor`, Frame `corridor_*`), gebaut in
  `emitRibbon` aus derselben Breite und Wasserfläche wie das Band. Nur für
  fließende Flussbänder an Land; zu Seen und Meer läuft es über vier
  Stützpunkte aus.
- **Gelände ersetzt, nicht abgesenkt.** Korridor und Band setzen im
  Vertex-Shader die Tiefe ihres Sehstrahls auf einem Deckel (höchste
  Geländehöhe im Querschnitt, gekappt auf Wasserspiegel + 0,12, dazu + 0,02),
  `game/shaders/corridor_common.gdshaderinc`.
  Das Bett gewinnt so gegen das Gelände darüber, Hügel davor verdecken es
  weiter. Der Deckel liegt höchstens 0,12 über dem sichtbaren Wasserspiegel
  (`lidMaxAboveWater`): in Schluchten stieg er sonst mit der Felswand, und
  Band und Böschung hingen vor dem Grat davor in der Luft
  (`schlucht-deckel.jpg`). Ufer, die höher reichen, enden unter dem Deckel,
  die Wand zeigt das Gelände selbst. Mit der Kappung ist auch die Reichweite
  des Deckelpunkts bei flachem Blick halbiert (`CORRIDOR_LID_REACH` 6 → 3):
  sie gehört zur Kappung; bei sehr flachem Blick verliert das Bett damit
  früher gegen Gelände knapp davor. Licht und Schatten am Deckelpunkt (`LIGHT_VERTEX`). Die Naht liegt
  auf dem Umriss des Meshes, nicht auf dem Zellgitter.
- **Wasser**: Körperfarbe im Korridor nach Beer-Lambert aus der Profiltiefe
  (kein Tiefenpuffer). Das Band zeichnet darüber nur die Oberfläche:
  Spiegelung, Kräuselung als Flowmap aus der Band-Tangente in zwei versetzten
  Phasen, Schaum aus `RibbonMesh.flows`, Sonnenglitzern.
- **Totale**: das Wasser wächst mit dem Kameraabstand auf mindestens 5
  Bildpunkte (höchstens 3,5-fach), Ufer behalten ihre Breite.
- **Naht zu #238**: die sichtbare Geländehöhe am Ufer fragt der Korridor nur
  über `BankSurface`. Der Fuß bleibt innerhalb der Schutzmaske
  (`maxReachCells`), wo Strang D null Abweichung zusagt. Wächter auf der
  Testwelt: `outsideMask = 0`.

## Wächter

`SimCoreTests/RiverCorridorTests.swift`: Bett unter beiden Uferkanten, Wasser
nie über dem Ufer, kein Korridor über dem Deckel, Deckel höchstens
`lidMaxAboveWater` über dem Wasser (Schlucht), Gelände im nassen Teil höchstens
in 1 % der nassen Vertices über dem Deckel (Schluchtwand, wie auf `main`;
bewusst lockerer als 1 % der Querschnitte, Linux misst 0,37 %), Flussmitte
(Thalweg) höchstens in 0,2 % der Querschnitte (macOS 0, Linux 1 von 1416), Fuß
auf dem Gelände (oder unter der Wand) und in der Schutzmaske, Band ohne Korridor
mit unverschobener Tiefe. `tests/river_ribbons.gd`: Korridor-Puffer vollständig und stimmig.
Bestehende Band-Wächter, alle Godot-Vertragstests und die SimCore-Suite
(677 Tests) grün. `simperf --hash` 95cf93ca1b40985c, `SimCore/Sources/SimCore`
unverändert.

## Bildzeit

`scripts/timelapse-timing.sh`, interleaved alt/neu, 4 Runden je Stand,
Flusstal-Bühne im Zeitraffer, `balanced`, maximiert auf dem eingebauten
Bildschirm 3456×2104, Median über die Runden:

| Kamera | vorher Mittel / p95 | nachher Mittel / p95 |
| --- | --- | --- |
| `nah` (17,10; 16; 0; 0,55) | 19,00 / 20,57 ms | 20,03 / 22,24 ms |
| `detail` (Standard) | 18,59 / 20,25 ms | 19,59 / 21,93 ms |

Verworfen: die Deckel-Tiefe als `DEPTH` im Fragment-Shader. Sie schaltete
Early-Z für Band und Korridor ab und kostete gemessen +8,4 ms Mittel in `nah`
(p95 37,7 ms, über dem Budget von 33,3 ms). Im Vertex-Shader als
`POSITION.z` sind es +1,0 ms.

## Verworfen unterwegs

- Gelände-Vertices im Korridor absenken: jedes abgesenkte Vertex zieht seine
  Dreiecke bis eine Zelle außerhalb mit, die Uferkante läge im Zickzack auf
  dem Zellgitter.
- Ufer deckend aus der Makrofarbe malen: die Makrofarbe ist nicht das fertig
  schattierte Gelände und las sich als graue Straße neben dem Fluss. Über
  Wasser deckt der Korridor jetzt nur Prallhang-Wand, Kies und nassen Saum,
  sonst scheint das Gelände durch.
- Nasser Saum als Höhe über Wasser (3,5 cm): auf flacher Aue deckte er die
  ganze Böschung.
- Erodieren der Korridor-Präsenz an Wasser: löschte kurze Bänder an Seen
  (Testwelt 48 von 672 Vertices mit Korridor).

## Offen

- Phase 2 (#238 nicht gemergt): mit der Zusage aus #238 braucht die Naht
  nichts weiter. Verdichtet D die Kacheln am Fluss über eine Zelle hinaus,
  muss `BankSurface` dort die feinere Fläche lesen.
- Auf flacher Aue liegt das Wasser des Bands oft höher als das Gelände an der
  Uferkante (Testwelt n = 384: 34 % der Uferkanten). Die Kante steht dann als
  kleiner Uferwall darüber, der Fuß liegt auf dem Gelände.
- Am Übergang zu Kaskaden und Seen endet der Korridor mit sichtbarer Kante,
  wo das Band ohne ihn weiterläuft.
- Das Glitzern ist schwach, die Sonne steht für die festen Kameras selten im
  Spiegelwinkel.
