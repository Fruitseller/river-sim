# Korridor-Querschnitte längs zusammen gerechnet, Band trägt denselben Deckel

Die Querschnitte EINES Bands entstehen nicht je Stützpunkt allein, sondern längs zusammen (`CorridorSections`, Gremium, Befund 2). Je Stützpunkt allein entstanden Splitter, Falten und Querwände:

- Die Ufersuche sprang von Stützpunkt zu Stützpunkt um bis zu 2,5 Zellen (spitze helle Dreiecke über Wiese und Wasser). Die gefundene Kante wird längs geglättet: Median gegen einzelne Sprünge, dann Kastenmittel (`edgeMedianRadius`, `edgeMeanRadius`).
- Im Innenbogen reichte die Böschung über den Krümmungsradius hinaus, die Querschnitte überschlugen sich (90°-Kerben, Falten). Die Reichweite der Innenseite ist am Radius gedeckelt (`innerReachShare` 0,85).
- An den Bandenden fiel das Profil abrupt auf null (stumpfe, rechteckige Enden, Dämme am Zusammenfluss). Es läuft über `endRampSamples` aus. Dieser Auslauf rampt nur Ufer und Bett: die Wasser-Halbbreite im Profil des Bands rechnet ohne ihn. Mit ihm lief auch das Wasser jedes Bands an beiden Enden auf null aus, an einem Zubringer genau dort, wo das Raster sein Wasser schon für das Band zurückgenommen hat (Review #247).

Korridor nur unter fließenden Fluss-Bändern auf Land. Über Wasser (See, Meer, Mündungs-Kette) liegt das Band flach auf dem Spiegel; dorthin läuft der Korridor über `corridorRampSamples` Stützpunkte Abstand zum nächsten Wasser-Stützpunkt weich aus (`corridorPresence`). Ein Minimum-Filter (`erodeAndSmooth`) dafür löschte kurze Bänder an Seen ganz (Render-Testwelt: 48 von 672 Vertices).

Nur jeder `sampleStride`-te Stützpunkt (2) und der letzte bekommt einen Querschnitt: die Band-Stützpunkte liegen ~0,5 Zellen auseinander, das Profil braucht nur ~1 Zelle. Das halbiert Mesh und Upload (gemessen bis 29 ms je Band-Bau im Hauptthread bei jedem Stützpunkt).

Das Band trägt denselben Deckel wie das Korridor-Mesh, an den Zwischenpunkten linear nach Bogenlänge interpoliert (`meshLids`). In der Deckel-Tiefe liegen Band und Ufer nur Millimeter auseinander; ein Band mit dem eigenen Deckel eines Zwischenpunkts lag je zweitem Quad hinter dem Korridor (Querstreifen ohne Wasser, Gremium, Befund 2). Das Bett unter Wasser schreibt seitdem zusätzlich keine Tiefe mehr (`corridor_wet.gdshader`).

Den VOLLEN Deckel trägt das Band, sobald der Korridor-Anteil `lidPresence` (= `WaterRender.ribbonVisibleLo`) erreicht; darunter ist der Korridor schmaler als sichtbar, der Deckel-Anteil steigt linear. Ein anteiliger Deckel (früher `presence ×`) lag im Auslauf vor Tümpeln einer Kaskade tiefer, das Bett gewann dort den Tiefentest gegen das Wasser (Querbalken, Gremium, Befund 2). Ohne Korridor (über Wasser, Mündung, Meer) bleibt JEDE Kante auf ihrer eigenen Höhe (Review Neon Nr. 9): mit dem Maximum beider Kanten hob die tiefere Kante ihre Tiefe an (Review #240).

Betrifft: `CorridorSections` (`build`, `smoothEdges`, `endRamp`, `innerReachShare`, `endRampSamples`, `lidPresence`), `CorridorBandBuilder.sampleStride`, `CorridorBandBuilder.meshLids`, `RiverRibbonRenderer.corridorPresence`, `RiverRibbonRenderer.corridorRampSamples`, `RiverRibbonRenderer.emitRibbon`, `RibbonMesh.profile`, `game/shaders/corridor_wet.gdshader`
