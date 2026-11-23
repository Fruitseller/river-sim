# Delta-Schüttung: Fracht der Inzision als Mündungsbarren-Baum

## Warum es den Pass gibt (Issue #174)

Die fluviale Erosion der Produktion ist detachment-begrenzt: `outletIncision` (Stream-Power) und `channelCarve` tragen Material ab, das danach nirgends mehr liegt, und die Tropfen laden ihre Fracht am Eintritt ins tiefe Wasser bzw. beim Verdunsten ab. Gemessen (`RiverDelta.swift`, `testDeltaBudgetDiagnostic`, Seed 1337, Jahr 20.000, größte Mündung): das Einzugsgebiet verliert über die Stream-Power-Inzision 7,9 Zellen·Höhe je 1000 Jahre, ins Meer davor kommt fluvial −0,1…+0,1. Ohne Fracht an der Küste gibt es keinen Ablagerungskörper und kein Delta (`docs/zielbild-measurements.md` § Delta).

## Fracht als Näherung

Fracht ist, was `outletIncision` und `channelCarve` in diesem Schritt abtragen (Höhensumme davor minus danach, `deltaHeightSum`), je Landzelle gemittelt, mal dem Einzugsgebiet der Mündung; davon bleibt `deltaTrapFraction` liegen. Mündungen sind Landzellen ohne See (`hf − h ≤ poolDepth`) mit Meeres-Empfänger ab `deltaMinCells` Einzugsgebiet.

Verworfen: die echte D8-Summe des Abtrags je Zelle bis zur Mündung (ein See hielt seinen Anteil fest). Sie kostete 1,3–1,5 ms je Schritt (eigen wie in der Braid-Schleife mitgeführt, `braidPass` 2,2 → 3,6 ms) bei einem Ziel von 0,5 ms für das ganze Delta. Verloren geht damit Relief und Klima des einzelnen Einzugsgebiets (ein steiles liefert so viel je Zelle wie ein flaches) und der Rückhalt in Seen; die Summe über alle Mündungen bleibt unter dem Abtrag der Insel. Gürtel und Tropfen zählen nicht mit: der Gürtel ist laterale Umlagerung, die Tropfen tragen ihre eigene Fracht.

`deltaHeightSum` summiert in festen 64 Blöcken mit je vier Teilsummen in fester Reihenfolge: unabhängig von der Kernzahl bit-gleich, und so vektorisiert der Compiler die Schleife. Derselbe Durchlauf sammelt die Mündungen je Block in Zellreihenfolge (dieselbe Liste wie sequenziell); als eigener sequenzieller Scan kostete die Suche 0,29 ms je Schritt.

## Ablagerung: Mündungsbarren

Ein Fluss, der ins Meer tritt, behält seinen Strahl einige Rinnenbreiten weit, verliert dann Tempo und legt eine Mündungsbarre ab; ist sie bis zum Wasserspiegel gewachsen, teilt sich der Strom um sie, und jeder Arm baut die nächste Barre (Wright 1977; Edmonds & Slingerland 2007, JGR 112, F02034). Die Sim rechnet Wasser im Meer nicht (Meer = Senke), deshalb steht diese Hydrodynamik als Ablage-Regel:

- Ein Baum aus Strahlen ab der Mündung, Rinnenbreite b aus dem Abfluss (dieselbe Kurve wie Band und Gürtel, `WaterRender.ribbonHalfWidthCells`).
- Barre `deltaBarDistanceWidths`·b voraus, Insel mit Radius `deltaBarRadiusWidths`·b quer und stromauf, `deltaBarElongation`-fach stromab gestreckt (Mündungsbarren sind tropfenförmig in Fließrichtung, die Barre reicht nicht in die Mündungsrinne zurück). Scheitel `deltaTopset` über dem Meer bis r, Fuß beim doppelten Radius gleich tief darunter. Umriss mit 2. und 3. Harmonischer gebrochen.
- Erst eine volle Barre gibt die Fracht nach Abflussanteil an ihre zwei Töchter weiter (Winkel ±`deltaBifurcationAngle`/2, Breite ∝ √Q), bis `deltaGenerations` oder bis eine Tochter schmaler als `deltaMinHalfWidth` würde; der Rest geht ins offene Meer. Der stärkere Ast läuft gerader. Bei Töchtern beginnt die Rinne am Ende der Elternrinne vor der Barre.
- Vor jeder Barre baut ein Strahl seine Uferwälle (eine Halbbreite neben der Rinne, Krone `deltaTopset`) von der Wurzel seewärts, die subaerische Deltaebene.
- Die Rinnen bleiben frei (Distributäre, Meerwasser zwischen den Inseln). Inseln und Wälle sind echtes Gelände, die Rinnen echtes Wasser; der Render malt beides nur ab (Ozean über `h ≤ sea`, Sand über `CoastMaterial`).

## Stabilität der Form über Schritte

- Richtung: Lauf (8 Zellen stromauf → Meereszelle) und Küstennormale (Meeresschwerpunkt im Fenster ±8) zu gleichen Teilen. Der Lauf allein springt mit der D8-Kette um 45°, und die Mündung selbst wandert je 1000 Jahre bei zwei Dritteln der großen Mündungen um 0–2 Zellen (Seed 1337, Jahr 10.000–20.000); jeder Schritt hätte einen anderen Baum gepflanzt.
- Flaches Delta-Land (bis zum doppelten Scheitel) zählt für die Richtung als Meer, und über die eigenen Inseln wächst der Baum weiter. Sonst drehte das wachsende Delta seinen eigenen Baum, und dieselbe Fracht in anderen Schritten gäbe eine andere Form (Wächter `testSameLoadInFewerStepsBuildsTheSameDelta`).
- Teilung, Winkel, Abstände und Umriss schwanken um `deltaJitter`. Das Rauschen (`deltaNoise`) ist reine Ganzzahl-Arithmetik (plattformgleich) und hängt am 8×8-Block der Mündung, an der Strahlnummer und einem Kanal: wandert die Mündung um ein, zwei Zellen, bleibt der Baum derselbe.
- Gefüllt wird bis zur Krone, auch über eigener Schüttung früherer Schritte, die schon Land ist; sonst stand eine halb gefüllte Zelle nach einem kleinen Schritt still, und dieselbe Fracht in kleineren Schritten legte weniger ab.
- dt: die Fracht ist die Änderung des Schritts (∝ dt), die Barren-Oberflächen sind geometrische Obergrenzen, die Füllreihenfolge ist fest; viele kleine Schritte laufen gegen dieselbe Form wie ein großer.

## Lagunen

Abgeschnürte Lagunen im Bereich des Baums verlanden zuerst (bis 0,3 Scheitel über das Meer), und eine abgeschnürte Rinne (`hf > sea`) verlandet wie der Rest. Sonst schlossen Barren und Wälle Meer ein, das Raster malte es als dunklen See neben dem Türkis des Meers (Seed 1337, Jahr 20.000: 160 Zellen an drei großen Mündungen).

## Sonstiges

- `visited` gehört dem Priority-Flood (er setzt es zu Schrittbeginn zurück und markiert am Ende jede Zelle), `pondSeen` der Pfützen-Verlandung; der Pass leiht beide nur und hinterlässt sie sauber.
- `sin(mθ + p)` über Mehrfachwinkel aus cos θ / sin θ statt `atan2` und `sin` je Zelle: gleiche Werte bis auf Rundung, ein Drittel der Kosten des Passes.
- Im Schritt steht der Pass nach dem fluvialen Block und vor Hangdiffusion und Wellen, die die frische Front im selben Schritt überarbeiten.

Betrifft: `Terrain.deltaDeposit`, `Terrain.deltaHeightSum`, `Terrain.deltaNoise`, `Terrain.DeltaJet`, `Terrain.deltaMouthCells`, `SimConfig.deltaTrapFraction` und die übrigen `delta*`-Parameter, `docs/zielbild-measurements.md`
