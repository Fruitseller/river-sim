# Sichtbares Wasser reißt entlang großer D8-Läufe nicht ab

Befund des Eigners 2026-10-18: „der Fluss fließt durchgehend weiter, aber man sieht das Wasser nicht durchgehend", dazu Zubringer, die als Keil vor dem Hauptlauf endeten („Flüsse kreuzen sich unnatürlich"). Messreihe: `docs/zielbild-measurements.md` § Durchgehende Flüsse.

Regeln:
- Verlässt der D8-Lauf ein Band und kehrt nicht zu ihm zurück, ist er bis ins Meer Wasser. Vorher malte dort niemand: das Abfluss-Vertrauen schweigt unter dem dreifachen Referenz-Abfluss, und die Kette hat unter dem Band keine Quelle.
- Kehrt der D8-Lauf zum selben Band zurück, ist er die Abkürzung über die Bank: dort malt das Band den Fluss, das Raster nicht.
- Ein Lauf, der vor dem Band eines größeren endet, folgt seinem D8-Empfänger bis in dieses Band; ohne Band in Reichweite läuft er aus.

Der Wächter läuft auf einer Kunstwelt (V-Tal, Gefälle nach Osten) statt auf einer gealterten Welt: welche Abzweige eine gealterte Welt trägt, hängt an der System-libm, und auf dem Linux-Runner trugen die Testwelten keinen, der Wächter prüfte dort nichts. Die Messung `endsBeforeBand` nimmt Reichweite und Deckung als Literale (= `ribbonJoinSearchCells`/`ribbonJoinCoverage`), damit sie auch auf dem Stand vor dem Fix läuft.

Betrifft: `WaterRender.departure*`, `WaterRender.ribbonJoinSearchCells`, `WaterRender.ribbonJoinCoverage`, `WaterFieldRenderer`, `RiverContinuity`, `RiverContinuityTests`
