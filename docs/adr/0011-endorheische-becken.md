# Abflusslose Becken: Seespiegel aus dem Wasserhaushalt

Im reinen Priority-Flood füllt sich jedes geschlossene Becken bis zur Sill, es gibt keine endorheischen Becken, Playas oder Salzseen. Seit Issue #11 deckelt `capEndorheicBasins` den Spiegel auf den Stand, den der Wasserhaushalt des Beckens trägt: Zufluss gegen Verdunstung über der Seefläche. Ein Becken mit genug Zufluss verhält sich exakt wie vorher (`testBasinsDrainToSea`, `testWellFedBasinIsUnchanged`).

Bilanz: Zufluss `A_zu` ist das Maximum von `area` über die Beckenzellen, der Bedarf `D(z) = κ · Σ_{h < z} cellArea · aridity(k)`. Weil der Abfluss niederschlagsgewichtet und aufs Regen-Landmittel normiert ist (ADR 0009), ist κ (`SimConfig.endorheicEvapRatio`) das nötige Verhältnis Einzugsgebiet zu Seefläche. `D(z)` ist eine monoton wachsende Treppenfunktion; der Gleichgewichtsstand ist der höchste mit `D ≤ A_zu` und wird exakt gefunden, indem man die Beckenzellen nach (h, Index) sortiert und aufsummiert.

Zufluss auf dem Vollstand, Rollen vorher gelöscht: in `floodAndRoute` misst die Akkumulation den Zufluss auf dem Priority-Flood-Vollstand, bevor gedeckelt wird, also unabhängig vom aktuellen Spiegel; sonst hinge der Zufluss am eigenen Ergebnis. Die Becken-Rollen des Vorschritts werden vor dieser Messung gelöscht: mit ihnen wären die Seeflächen schon terminal, die Akkumulation käme an der Auslasszelle nie an, und der Zufluss hinge an der Deckelung von gestern. Das wäre eine Hysterese, die den Spiegel schrittweise weiter senken kann. Nur wenn gedeckelt wurde, wird das Netz auf dem gedeckelten Spiegel neu bestimmt; dort ist die Wasserfläche eine terminale Senke ohne MFD-Überlauf und ohne Auslass-Inzision.

Ratenbegrenzung: übernommen wird ein exponentieller Schritt zum Ziel (`endorheicResponseYears`, über `relaxFraction` dt-invariant); `dtYears = 0` (Generierung, Breach, Spieler-Eingriff) übernimmt das Ziel sofort. Der Zielstand springt, wenn Deposition die Sill hebt. Gedächtnis ist `lakeBalance` an der tiefsten Beckenzelle, der einzigen, die in jedem Stand zum Becken gehört. Trägt ein Becken den Vollstand, wird der Bilanzstand trotzdem auf der Sill mitgeführt, damit ein später kippendes Becken von dort absinkt statt von einem veralteten Wert.

`order` zieht den gesenkten Spiegel lokal mit: die Plätze des Beckens bleiben, die Zellen ziehen darin nach neuem hf um; die Sortierung nach (h, Index) ist zugleich die nach dem neuen hf. Rein sequenziell, Becken in aufsteigendem Zellindex, damit deterministisch.

Die Salzkruste `saltCrust` ist reines Render- und Vegetationssignal, keine Erosionsphysik. Ihre Zielmaske `playaBed` ist bewusst enger als `dryBed`, nur wo substanziell Wasser stand: der Priority-Flood flutet den ganzen flachen Boden (n = 256, Seed 1337: 9788 trockengefallene Zellen, nur ein Bruchteil über der Render-Seetiefe), und ein Millimeter-Saum ist keine Salzpfanne.

Verworfen:
- Füllen bis zur Sill für jedes Becken (reiner Priority-Flood): keine endorheischen Becken.
- Zufluss auf dem aktuellen, gedeckelten Spiegel messen oder mit den Rollen des Vorschritts: der Zufluss hinge an der eigenen Deckelung, Hysterese.

Betrifft: `Terrain.capEndorheicBasins`, `Terrain.floodAndRoute`, `Terrain.computeReceiversAndArea`, `Terrain.lakeBalance`, `Terrain.endorheicInflow`, `Terrain.saltCrust`, `Terrain.playaBed`, `Terrain.updateSaltCrust`, `SimConfig.endorheicEvapRatio`, `SimConfig.endorheicResponseYears`
