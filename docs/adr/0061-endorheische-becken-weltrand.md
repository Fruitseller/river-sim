# Basisniveau Meer nur am Weltrand, keine Inzision in abflusslosen Becken

Die Auslass-Inzision braucht für jede Landzelle einen Bezugspegel. Eine Landzelle ohne Empfänger ist entweder Weltrand (Priority-Flood-Seed) oder trockengefallener Boden eines geschlossenen Beckens; beide Fälle werden verschieden behandelt.

Am Weltrand verlässt das Wasser die Welt, dort gilt ein virtuelles Basisniveau MEER (`hr = sea`, Distanz eine Zellgröße; Gate-Wert 2). Ohne das wirkt der Rand als unerodierbarer Pegel, und Becken, die über den Rand entwässern, können sich nie tiefer ausschneiden. Gemessen: ein See blieb 28 Breach-Runden lang bei exakt 2656 Zellen stehen.

Im abflusslosen Becken (Issue #11) gilt dieses Basisniveau ausdrücklich NICHT: es würde den Beckenboden Richtung Meeresspiegel ausgraben. Die Seefläche (`endorheicBasin == .water`) hat keinen Auslass und bekommt deshalb keine Inzision, ebenso der trockengefallene Beckenboden ohne Empfänger. Die Sill braucht keinen Sonderfall: sie sammelt den Beckenabfluss nicht mehr ein (terminale Senke), ihr A^m ist winzig, die Inzision versandet von selbst. So hört ein endorheisches Becken auf, sich selbst zu entwässern.

Das `minA > 0` vor dem Flächen-Gate ist kein zusätzliches Kriterium: es spart im Produktionsfall (`minAreaCells = 0`) nur den Zugriff ins große `area`-Feld, weil `area` nie negativ ist.

Betrifft: `Terrain.outletIncision` (Gate-Kette, `incisionGate`), `Terrain.endorheicBasin`, `Terrain.floodParent`
