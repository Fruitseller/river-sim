# Glaziale Erosion über eine Schleifspur statt lokal

Die lokale Flux-Rate ist im Thalweg am größten und gräbt dort eine Kerbe; das Querprofil wird V-iger statt U-iger (gemessen ohne Ausstrich 1.447 gegen 1.352 im eisfreien Referenzarm, also die falsche Richtung; `docs/research-climate-cryosphere.md` §4.3 sagt es voraus, `docs/glacier-measurements.md` §D misst es). Ein Gletscher schleift über seine ganze Breite. Die Rate wird deshalb über ein Quadrat von `iceErodeSwathRadius` Zellen gemittelt, mit gleichen Gewichten und auf die volle Fenstergröße normiert. Liebl et al. 2023 lösen dasselbe Problem im OpenLEM mit derselben Maßnahme („artificially expanded erosion swath").

Die Rate entsteht in Pass 1 auf der Dicke vor dem Transport (q = Eisdicke × Oberflächengefälle als Gleit-Proxy) und steht im Scratch. Pass 2 sammelt (Gather statt Scatter), damit er weiter nur den eigenen Index schreibt und parallel bit-identisch bleibt; bei gleichen Gewichten ist das dieselbe Gesamtmenge. Die Mittelung läuft separabel: erst eine Kastensumme je Zeile (ein Thread je Zeile, feste Reihenfolge), dann senkrecht in Pass 2. Bei Radius 4 sind das 18 statt 81 Lesezugriffe je Zelle.

Exponent 0,5 (Standard) wird als Wurzel gerechnet: `pow` war der größte Einzelposten des Passes (Messprotokoll §M), das Ergebnis weicht höchstens 1 ulp ab.

Der Erosionsdeckel ist eine Rate: ein Teilschritt nimmt höchstens ein Viertel der lokalen Oberflächenabfälle mit. Im kalibrierten Lauf bindet er nicht; er hält den Trog davon ab, sich in einem Teilschritt unter seine Nachbarn zu graben, wo sich sonst das Eis staut.

Betrifft: `Terrain.iceFlowSubStep`, `Terrain.iceEro`, `Terrain.iceEroH`, `SimConfig.iceErodeSwathRadius`
