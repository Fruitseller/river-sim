# Pre-Erosion mit dem runevision-Erosionsfilter bei der Generierung

Das Terrain startet mit fertig erodiertem Look, statt ihn über zehntausende Sim-Jahre einzucarven: der nicht simulierte Erosionsfilter nach Rune Skovbo Johansen („Fast and Gorgeous Erosion Filter", https://blog.runevision.com/2026/03/fast-and-gorgeous-erosion-filter.html, Shadertoy wXcfWn, Referenz-GLSL in `docs/references/runevision-erosion/`) wird EINMAL bei der Generierung angewendet. Er carvt verzweigte Rinnen und Grate („stacked faded gullies"), jeder Punkt ist unabhängig auswertbar, daher parallel und deterministisch. Droplets, Stream-Power und Mäander arbeiten danach normal auf dem vor-erodierten Feld weiter. Der Code ist eine Portierung (Phacelle Noise + Filter, MPL-2.0, s. `NOTICE`); Parameterwerte stehen gegen das GLSL-Original.

Anwendung (`ErosionFilter.apply`): p-Koordinaten sind UV ∈ [0,1] plus Seed-Offset (jeder Seed andere Rinnen); Steigungen numerisch (zentrale Differenzen) aus dem UNVERÄNDERTEN Eingangsfeld. Nur Land: unterhalb `sea` faden die Rinnen aus, Küste und Meeresboden bleiben unberührt. `heightOffset` (x: −1..1, y: 0..1 Ersetzung durch −fadeTarget) senkt das Feld ∝ magnitude, damit Rinnen netto carven statt Grate aufzuschütten.

Bedeutung der Tupel-Parameter (der Typ trägt keine Namen):
- `rounding`: (Grat-Rundung, Kerben-Rundung, Multiplikator Eingangsfeld, Multiplikator je Oktave)
- `onset`: (Eingangsfeld, je Oktave, RidgeMap-Eingang, RidgeMap je Oktave)
- `assumedSlope`: (angenommene Steigung, Anteil 0..1 der Ersetzung)
Skalare: `strength` Gesamtstärke (× `scale` = Höhen-Offset Oktave 0), `gullyWeight` 0 = nur Peak-Schärfung, 1 = volle Rinnen, `detail` klein: feine Rinnen nur an steilen Hängen, `scale` horizontale Skala der größten Rinnen (p-Einheiten), `cellScale` Phacelle-Zellgröße relativ zur Streifenbreite.

Betrifft: `ErosionFilter`, `ErosionFilter.apply`, `ErosionFilter.evaluate`, `ErosionFilter.Params`, `SimConfig.preErodeParams`, `NOTICE`
