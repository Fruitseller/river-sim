# Kopplung Mäandergürtel ↔ D8-Entwässerung: Takt in Jahren, Avulsion als Rate

`Terrain.coupleBeltToDrainage` (#187) koppelt die Gürtel-Läufe an das frische D8-Netz. Messreihe und Befunde: `docs/zielbild-measurements.md` § Gürtel und Entwässerung: Avulsion (#187).

Takt: Die erste Prüfung liegt bei Jahr 0, die folgenden höchstens einen kleinen Aufruf hinter der gemeinsamen 1000-Jahr-Marke (`meanderBeltCouplingYears`), der Rest wird übertragen. Ein Abzählen bis zum Schrittende würde dt 100 um 900 Jahre gegen dt 1000 verschieben. Ein Pinselstrich darf das Wieder-Trassieren nicht bis zum nächsten Termin verzögern: Der Schritt koppelt nach dem Verwerfen gestörter Linien noch im selben Aufruf neu.

Verhalten:
- Avulsion: Ein abgekoppeltes Stück wird durch den D8-Weg ersetzt, das verlassene Gerinne wird Altarm, der Abfluss kommt aus dem D8-Netz statt aus dem geerbten Wert. Der gekoppelte Oberlauf bleibt, wo er war (bis auf das Neu-Abtasten an der Ecke vor dem Absprung). „Im Tal" heißt innerhalb der Kopplungs-Reichweite: halbe Gürtelbreite plus `meanderBeltCouplingSlackCells`.
- Avulsion ist ein Ereignis mit Rate 1/τ (`meanderBeltAvulsionYears`), kein Auslöser: Eine Abkopplung, die nur einen kurzen Schritt besteht, springt bei großem τ nicht; die Linie behält ihren Umweg, der Abfluss kommt trotzdem aus D8.
- Eine Linie ohne D8-Wasser darunter verschwindet, der Fluss bekommt seine Linie aus dem D8-Netz, auch nach einem Pinselstrich, der die alte Linie löscht (Review #187).
- Bankalter je Teilschritt (Review #187): Nach einem 1000-Jahr-Schritt tragen neue Bänke ihr Alter am Schrittende (0 … 1000), verteilt wie nach zehn 100-Jahr-Schritten. Vorher lagen gemessen alle 9971 neuen Bankzellen bei exakt 0.

Wächter-Aufbau: `testDeterminism` (n = 96) hat keinen wandernden Lauf und bewacht den Gürtel nicht. Die Gürtel-Wächter laufen deshalb auf n = 128 mit `meanderBeltMinCells = 100` (wie `WorldSnapshotTests`). Die Schrittweiten-Unabhängigkeit wird über sechs Seeds und gemeinsame Stützstellen geprüft, weil einzelne Realisierungen auf dem groben Gitter mit der System-libm streuen; die Ersetzungszahl muss Jahre zählen, das Sinuositäts-Mittel darf nicht auseinanderlaufen. Der Produktionslauf über alle drei Takte (15/100/1000) mit den Abnahmepunkten 9–13 bewacht auch Änderungen der Produktions-Kalibrierung, bleibt aber wegen der neun 20k-Welten hinter `RS_MEASURE`.

Betrifft: `Terrain.coupleBeltToDrainage`, `SimConfig.meanderBeltCouplingYears`, `SimConfig.meanderBeltAvulsionYears`, `SimConfig.meanderBeltCouplingSlackCells`, `BeltCouplingTests`
