# Abflusslose Becken: Seespiegel aus dem Wasserhaushalt

Ein geschlossenes Becken wird nicht mehr wie im reinen Priority-Flood immer bis zur Sill gefüllt, sondern auf den Stand gedeckelt, den sein Wasserhaushalt trägt: Zufluss gegen Verdunstung über der Seefläche (Issue #11). Damit gibt es endorheische Becken, Playas und Salzseen; ein Becken mit genug Zufluss verhält sich exakt wie vorher (`testBasinsDrainToSea`, `testWellFedBasinIsUnchanged`).

Bilanz in `capEndorheicBasins`. Ein Becken ist eine 8er-Komponente mit `hf > h` und identischem `hf` (Priority-Flood füllt exakt flach, die Gleichheit ist exakt):

    Zufluss A_zu = max(area) über die Beckenzellen
    Bedarf  D(z) = κ · Σ_{h < z} cellArea · aridity(k)

Auf dem Vollstand zeigen alle Beckenzellen über `floodParent` zur Sill, die Akkumulation ist an der Auslasszelle maximal. Weil der Abfluss seit #10 niederschlagsgewichtet und aufs Regen-Landmittel normiert ist, ist κ das Verhältnis Seeverdunstung zu mittlerer Abflusshöhe, also das nötige Verhältnis Einzugsgebiet zu Seefläche (`SimConfig.endorheicEvapRatio`). Regen auf den See steckt schon in `A_zu`; der Bedarf ist Brutto-Verdunstung. Ohne Gewichtsfeld bilanziert der Pass rein geometrisch. `D(z)` ist eine monoton wachsende Treppenfunktion der Fläche; der Gleichgewichtsstand ist der höchste mit `D ≤ A_zu` und wird exakt gefunden, indem man die Beckenzellen nach (h, Index) sortiert und aufsummiert. `D(Sill) ≤ A_zu` heißt: kein Eingriff, keine Sortierung.

Reihenfolge in `floodAndRoute`: (1) `priorityFlood` liefert den Vollstand, (2) erstes `computeReceiversAndArea` misst darauf den Zufluss (bewusst unabhängig vom aktuellen Spiegel, sonst hinge der Zufluss am eigenen Ergebnis), (3) `capEndorheicBasins` deckelt, (4) nur wenn gedeckelt wurde, wird das Netz auf dem gedeckelten Spiegel neu bestimmt. Die Becken-Rollen werden vor der Zuflussmessung gelöscht: mit den Rollen des Vorschritts wären die Seeflächen schon terminal, die Akkumulation käme an der Auslasszelle nie an, und der Zufluss hinge an der Deckelung von gestern (Hysterese, die den Spiegel schrittweise weiter senken kann). `endorheicInflow` hält den so gemessenen Zufluss für Diagnose und Wächter.

Im fertigen Netz ist die Wasserfläche eines solchen Beckens eine terminale Senke: Empfänger −1, auch wenn die 8er-Nachbarschaft diagonal an einen tieferen Nachbarsee grenzt; kein MFD-Überlauf, keine Auslass-Inzision. Flache Bodenzellen im geschlossenen Becken haben keinen Überlauf, denn der `floodParent`-Rückfall zeigt zur Sill hinaus, wohin kein Wasser mehr kommt.

Ratenbegrenzung: übernommen wird ein exponentieller Schritt zum Ziel (`endorheicResponseYears`, über `relaxFraction` dt-invariant); `dtYears = 0` (Generierung, Breach, Spieler-Eingriff über `recomputeFlow`) übernimmt das Ziel sofort, alles andere an `computeFlow` ist dt-unabhängig. Der Zielstand springt, wenn Deposition die Sill hebt. Gedächtnis ist `lakeBalance` an der tiefsten Beckenzelle, der einzigen, die in jedem Stand zum Becken gehört, auch wenn es ganz trockenfällt. Trägt ein Becken den Vollstand, wird der Bilanzstand trotzdem auf der Sill mitgeführt, damit ein später kippendes Becken von dort absinkt statt von einem veralteten Wert.

`order` muss den gesenkten Spiegel mitziehen, weil die Akkumulation rückwärts durch `order` läuft und den Empfänger jeder Zelle früher darin erwartet. Repariert wird lokal: die Plätze des Beckens bleiben, die Zellen ziehen darin nach neuem hf um. Die Sortierung nach (h, Index) ist zugleich die nach dem neuen hf (= max(h, level)). Global bleibt `order` sortiert, weil außerhalb kein hf geändert wurde und eine fremde Zelle mit gleichem hf nie Empfänger einer jetzt höher liegenden Beckenzelle sein kann.

Determinismus: rein sequenziell, Becken in aufsteigendem Zellindex, Sortierung nach (h, Index).

Salzkruste `saltCrust` (EWMA mit `endorheicSaltYears`, dt-invariant) ist reines Render- und Vegetationssignal, keine Erosionsphysik; die Salzpfanne ist ein kahler Standort, sonst begrünt der flache, tiefe Beckenboden sofort. Ihre Zielmaske `playaBed` ist bewusst enger als `dryBed`: nur wo substanziell Wasser stand (Vollstand-Tiefe > `endorheicSaltMinDepth`). Der Priority-Flood flutet den ganzen flachen Boden, ein Millimeter-Saum ist keine Salzpfanne (n=256/Seed 1337: 9788 trockengefallene Zellen, nur ein Bruchteil über der Render-Seetiefe).

Betrifft: `Terrain.capEndorheicBasins`, `Terrain.floodAndRoute`, `Terrain.computeFlow`, `Terrain.computeReceiversAndArea`, `Terrain.lakeBalance`, `Terrain.endorheicInflow`, `Terrain.saltCrust`, `Terrain.playaBed`, `Terrain.updateSaltCrust`, `Terrain.updateVegetation`, `SimConfig.endorheicEvapRatio`
