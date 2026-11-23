# Auslass-Inzision als reine Flächen-Stream-Power, stromab nach stromauf

Die fluviale Makro-Inzision der Produktion (`outletIncision`) ist reine Flächen-Stream-Power: der Abtrag konzentriert sich auf Zellen mit großem Einzugsgebiet (Täler, Auslässe) und lässt Grate in Ruhe. So entsteht ein dendritisches statt eines verrauschten Talnetzes, und ein Becken-Auslass, der das ganze Becken sammelt, tieft sich zügig ein, bis der See zum Meer entwässert.

Die Zellen werden stromab nach stromauf abgearbeitet (`order` = aufsteigende Füllhöhe). Der Empfänger ist damit schon aktualisiert, wenn seine Zuflusszelle drankommt, und die Inzision propagiert sill-erhaltend flussaufwärts. Die Reihenfolge ist Teil des Verfahrens, nicht beliebig.

Vegetation bremst den Abtrag klassen-gewichtet wie `vegDamp`. Weil kein Bett-Feld in diesen Faktor eingeht, steht er vor dem Pass fest und wird vorab in `incisionKErode` berechnet.

Lithologie (Issue #12): diese Rate ist die fluviale Makro-Rate der Produktion, hier entstehen die lithologischen Knickpunkte. Ohne Gesteinsfeld läuft der Pass mit einem 1-Element-Dummy und dem Faktor exakt 1.0, die Arithmetik bleibt damit bit-identisch zum Stand ohne Lithologie.

Betrifft: `Terrain.outletIncision`, `Terrain.incisionKErode`, `Terrain.lithErodeK`, `Terrain.order`
