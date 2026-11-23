# Störung nach Pinselstrich: Budget-Feld und bit-identischer Schnell-Ausstieg

Der Störungsgrad `disturb` (0..1, Issue #26) wird von `applyDelta`, dem gemeinsamen Trichter aller Pinsel, aufgebaut und in `regenerateDisturbed` exponentiell abgebaut. Solange er > 0 ist, gilt die Zelle als Baustelle: kein Bewuchsstandort, Mikrorelief wächst hinein, Mäanderzustand der alten Landschaft fällt weg. Im Vegetationsziel drückt er den Wert gegen 0 und klingt aus, sichtbare Sukzession statt sofortiger Waldtapete.

Die noch ausstehende Geländeänderung (Setzung/Rebound des bewegten Materials plus Mikrorelief) steht in einem Budget-Feld `regenPending` und wird mit derselben Zeitkonstante wie `disturb` abgearbeitet, statt den Effekt je Schritt neu auszurechnen. So teleskopiert die Summe über beliebige Schrittweiten exakt.

Ohne je gesetzten Störungsgrad (`disturbActive == false`) wird der ganze Regenerationspfad übersprungen; normale Alterung rechnet bit-identisch zum Stand vor #26 (Wächter `testUntouchedAgingIsBitIdentical`). Auch in der Vegetation ist das Feld außerhalb von Eingriffen exakt 0 und der Faktor exakt 1.0.

Betrifft: `Terrain.disturb`, `Terrain.regenPending`, `Terrain.disturbActive`, `Terrain.regenerateDisturbed`, `Terrain.applyDelta`, `Terrain.updateVegetation`
