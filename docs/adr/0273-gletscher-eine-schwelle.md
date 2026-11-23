# Eine Schwelle für Eisfluss, Abrasion und fluviales Gate

Unterhalb `iceMinThickness` fließt kein Eis und schleift keines; das ist dieselbe Grenze, ab der `underIce` die fluvialen Pässe wieder zulässt. Ohne diese Kopplung arbeiteten am dünnen Saum beide Erosionsgesetze gleichzeitig am selben Bett (PR-Review zu #35: `iceFlowSubStep` gatete den Ausstrom an `ice > 0` und die Abrasion an `i0 > 0`, die fluvialen Gates erst über der Schwelle; `docs/glacier-measurements.md` §K).

Geprüft als Äquivalenz zweier Arme über einen Schritt aus demselben Zustand: eine Schwelle über der größten Eisdicke muss dasselbe liefern wie „Transport-Deckel 0 + `iceErodeK = 0`". Der Vergleichsarm setzt `iceFlowMoveFraction` auf 0, nicht `iceFlowK`: Letzteres ändert über `totalK` die Zahl der Teilschritte, die Bilanz relaxierte dann in anderen Häppchen und wäre nur in exakter Arithmetik bit-gleich. Fluviale Raten (`hydraulicPerYear`, `outletErode`) stehen auf 0, damit nur das Eis `h` bewegt.

Die Bilanz (Zufuhr, Schmelze, Moräne) läuft in beiden Armen weiter, denn ein Schneefeld muss über die Schwelle wachsen können. Die Zusicherung ist „kein Transport, keine Abrasion", nicht „Eis eingefroren". Der Test prüft außerdem, dass der dünne Saum in Produktion nicht leer ist, und als Gegenprobe, dass mit der Produktions-Schwelle Transport und Abrasion im selben Zustand sehr wohl wirken.

Betrifft: `testThinIceNeitherFlowsNorGrinds`, `SimConfig.iceMinThickness`, `Terrain.iceFlowSubStep`
