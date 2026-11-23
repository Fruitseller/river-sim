# Tropfen schreiben das Bett über den Funnel-Kern, mit stärkerer Sperre

Seit Issue #96 schreibt die Tropfenschleife Erosion und Ablagerung über den Bett-Funnel-Kern (`Terrain.Bed.erode`/`deposit`, Regel: erst Sediment, dann Fels), dieselbe Regel wie beim Terrain. Bis #96 stand das Gate in der Schleife ausgeschrieben.

Die Sperr-Maske des Tropfenpfads ist stärker als die des Terrains: `bedLocked` ist Eis ∪ Gürtelbett (`Terrain.beltDropletGate`), nicht nur die Gletscher-Maske. Bis #187 hieß der Parameter `underIce`. Auf gesperrten Zellen rührt der Tropfen das Bett nicht an: unter einem Gletscher gibt es keinen fluvialen Abtrag, und Schutt auf einer Eisoberfläche ist kein Sediment im Bett. `Bed.deposit` liefert dort 0, der nicht abgelegte Rest bleibt in Suspension und erreicht das Bett erst hinter der Sperre, physisch der Sander am Gletschertor.

Zweiter Dämpfer `depositDamp` (#108, aus dem D8-Abfluss in `Terrain.buildDepositDamp`): die dendritische Verallgemeinerung der Kanalmaske; wo viel abfließt, trägt der Fluss seine Fracht weiter. Wirksam ist der STÄRKERE der beiden Dämpfer (Minimum), nicht ihr Produkt: das Produkt liefe auf Mäanderbetten (hoher Abfluss und Maske) gegen 0, und 0 ist als instabil belegt (`channelDepositDamp`). `erodibility` (#12, `Terrain.lithErodeK`) skaliert nur den Fels-Anteil des Abtrags, Sediment erodiert unverändert. Für alle optionalen Felder gilt: leeres Array = Verhalten wie ohne (bit-identisch).

Betrifft: `Hydraulic.erode`, `Terrain.Bed`, `Terrain.beltDropletGate`, `Terrain.buildDepositDamp`, `HydraulicParams.channelDepositDamp`
