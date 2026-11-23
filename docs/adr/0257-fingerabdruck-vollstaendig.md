# Zustands-Fingerabdruck reagiert auf jedes Inventarfeld (#78)

`TerrainState.fingerprint()` muss auf jedes Feld des Inventars reagieren, sonst meldet `simperf --hash` bzw. `testDeterminism` „identisch", obwohl ein Refactor den Zustand verändert hat. Vor #78 wurden nur 8 handgepflegte Felder gehasht.

Der Wächter iteriert die Feldtabellen aus `WorldSnapshot` selbst, keine zweite Liste; ein neu aufgenommenes Feld ist automatisch geprüft (Störung um ein Mantissen-Bit; ein leeres Feld wird „angeschaltet", das sieht der Hasher über den Längen-Präfix). Für die nicht tabellierten Bestandteile (Skalar-Block, Höhenbänder, Mäander-Block) prüft `testEveryStoredPropertyIsAccountedFor`, dass jede gespeicherte Eigenschaft von `TerrainState` entweder tabelliert oder als Skalar-/Mäander-Bestandteil benannt ist; beide Gruppen gehen in `fingerprint()` und `encode()` ein. Sonst überlebte die #78-Lücke auf der untabellierten Hälfte.

`fingerprint()` hasht die Höhenbänder strukturell über `Mirror` unter der Annahme, dass alle gespeicherten Eigenschaften `Double` sind; ein anders typisiertes Band würde still übersprungen. Der Wächter prüft diese Annahme.

Betrifft: `TerrainState.fingerprint`, `WorldSnapshot.doubleFields`, `WorldSnapshot.encode`, `HeightBands`, `FingerprintTests`
