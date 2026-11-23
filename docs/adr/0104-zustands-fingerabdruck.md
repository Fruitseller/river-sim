# Zustands-Fingerabdruck über das komplette Inventar

`TerrainState.fingerprint()` (Issue #78, öffentlich als `Terrain.fingerprint()` für `simperf --hash`) läuft über dieselben Inventartabellen wie das Speicherformat (`doubleFields`/`int32Fields`/`uint8Fields`/`boolFields`) plus den dort nicht tabellierten Skalar- und Mäander-Block in der Reihenfolge von `encode()`. Ein neues Feld ist damit automatisch erfasst, sobald es ins Inventar kommt; `FingerprintTests` prüft die Abdeckung tabellen-getrieben, und die Tests iterieren dieselben Tabellen statt eine zweite Feldliste zu führen.

- Jedes Array geht mit Längen-Präfix ein, damit „Feld leer" (abgeschaltete Physik) und „Feld verschoben" nicht kollidieren; dieselbe Rolle wie die Feld-Header im Speicherformat.
- Die Höhenbänder werden strukturell über `Mirror` (gespeicherte Eigenschaften in Deklarationsreihenfolge) gemischt statt über eine Hand-Liste, die ein Band doppelt führen oder vergessen könnte. Die Annahme „alle als Double gespeichert" sichert `FingerprintTests.testEveryStoredPropertyIsAccountedFor`.
- Empfindlich auf jedes ulp (Roh-Bitmuster). Der Wert ist maschinen-spezifisch (System-libm): Vergleiche gelten nur auf derselben Maschine, ein Erwartungswert gehört nicht ins Repo.

Betrifft: `TerrainState.fingerprint`, `Terrain.fingerprint`, `WorldSnapshot.doubleFields`, `StateHasher`, `FingerprintTests`
