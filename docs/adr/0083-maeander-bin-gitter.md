# Flache Bin-Gitter und eigene Arrays statt Dictionary und Pfad-Zugriff im Mäander-Kern

Die Nachbarsuchen des Mäander-Kerns (Hals-Cutoff, Gürtel-Cutoffs, Zubringer-Anschluss) laufen über flache Bin-Gitter mit verketteten Listen (`binHead`/`binNext`) statt Dictionary-of-Arrays. Das Dictionary allokierte je Kanal und Schritt und war mit ~5 % des Sim-Schritts (n=832) der Mäander-Hotspot (`meanderSpatialCutoffIndex`, Produktion); im Gürtel trug es je Lauf und Teilschritt den Großteil der Kosten. Die Puffer werden wiederverwendet (Review #187: vorher je Aufruf, also je Lauf und Teilschritt, neu allokiert); zurückgesetzt werden nur die belegten Bins (`binTouched`). Die Reihenfolge der Listen ist unverändert.

Ergebnis-Gleichheit zur Vollsuche: nur Knoten aus eigenen und benachbarten Zellen können einen Hals bilden; das erhält das früheste (i, j). Bin-Koordinaten werden ins Gitter GEKLEMMT (Knoten können während der Migration kurz aus der Welt driften); Klemmen ist monoton, Paare mit dist < neck bleiben in benachbarten Bins, und der exakte dist-Filter macht das Ergebnis identisch zur Dictionary-Variante (Wächter `testSpatialCutoffIndexMatchesReferenceOrder`). Die Gitterweite wird vor der Konversion auf 4096 begrenzt (Int-Überlauf und Speicher-Explosion bei winzigem `meanderNeckDist`).

`RiverChannel.refreshDischarge` hält die Knotenschleife beim Lauf selbst, damit sie auf den eigenen, eindeutig referenzierten Arrays läuft; über `terrain.meander.channels[ci]…` kostete jeder Knoten COW- und Exklusivitätsprüfungen (Issue #43).

Betrifft: `MeanderState.applyCutoffs`, `MeanderState.applyBeltCutoffs`, `MeanderState.attachTributaries`, `RiverChannel.refreshDischarge`, `SimConfig.meanderSpatialCutoffIndex`
