# Hangdiffusion mit räumlich variablem kappa, dt- und auflösungsinvariant

Der Produktionspfad diffundiert über `hillslopeDiffusion` mit räumlich variablem kappa. Bodenkriechen braucht Boden: bodenbedeckte, sanfte, bewachsene Hänge runden voll aus, hoher, steiler, kahler Fels kriecht kaum. Dort bleiben spitze Gipfel und Grate stehen, als Ausnahme, nicht als Regel; die Landschaft altert ungleichmäßig statt uniform rund. Kahler-Fels-Faktor: nur über h > 0.42, aus Steilheit, Höhe und fehlendem Boden/Bewuchs, drosselt kappa auf bis zu 8 %.

Lithologie (Issue #12): harte Bänke kriechen langsamer (D = 1 − c·hard, Untergrenze 0.05). Ohne das gibt es keinen dauerhaften Hangknick, die Diffusion rundet die Kante der harten Bank weg, egal wie langsam der Fluss sie einschneidet (Wächter: `Lithology.testDiffusionContrastEffectIsMeasured`). Ohne Feld oder bei Kontrast 0 ist der Faktor exakt 1.0, bit-identisch.

Kanal-Schutz (Issue #108): im aktiven Kanal räumt die Strömung einkriechendes Material ab. Ohne Dämpfung schmiert die Diffusion die Rinnen zu, in denen die Flüsse laufen (gemeldet als "Wasser liegt ohne Taleinschnitt auf dem Hang"). Größe ist das D8-Einzugsgebiet in Zellen, Übergang per smoothstep. AUS (`channelDiffusionDamp ≥ 1`) oder ohne `area` fällt der Zweig weg; auch AN ist der Faktor unter der Schwelle exakt 1.0. Kalibrierung: `SimConfig.channelDiffusionDamp`.

Zeit und Auflösung: die Gesamtwirkung ist ∝ dt. Früher lief die Diffusion je "Pass" (`passes = max(1, dt/100)`), bei dt ≈ 0.2 je Frame war das ~100× zu viel Rundung und Rechenzeit. Heute: kappa je Jahr, sub-getaktet mit Teilschritt-kappa ≤ 0.2 (explizites Verfahren stabil), und kappa skaliert ∝ 1/dx² ∝ (n−1)², kalibriert auf n = 640.

Beide Teilpässe sind per-Zelle unabhängig (Pass 1 schreibt nur `scratch[k]`, Pass 2 nur `h/sed/rock[k]`) und laufen datenparallel auf Roh-Puffern, bit-identisch zur sequenziellen Schleife.

`diffusionPass` (uniformes kappa) läuft nur im Nicht-Droplet-Zweig (`hydraulicEnabled = false`), zusammen mit `transportLimited` der Grid-Pfad der isolierten Mäander-Kopplungstests.

Betrifft: `Terrain.hillslopeDiffusion`, `Terrain.diffusionPass`, `Terrain.step`, `SimConfig.hillDiffusion`, `SimConfig.lithDiffusionContrast`, `SimConfig.channelDiffusionDamp`
