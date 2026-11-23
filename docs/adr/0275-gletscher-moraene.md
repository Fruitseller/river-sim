# Moränen-Wächter: Differenz über einen Schritt aus demselben Zustand

Der Ausschmelz-Schutt muss im Zehrgebiet landen, nicht unter dem Nährgebiet, und als Sediment aufliegen. Gemessen wird als Differenz zweier Arme über EINEN Schritt aus demselben Zustand (der zweite Arm wird über das Zustands-Inventar aus dem ersten gefüllt, im Moränen-Arm `iceErodeK = 0`). Zwei getrennt gelaufene Arme sind nach 30k Jahren überall auseinander, die Differenz misst dann Chaos statt Moräne (gemessen: Summe über das Nährgebiet 1.02 statt 0).

Die Klassifikation Nähr-/Zehrgebiet liest die Temperatur VOR dem Schritt: `updateClimate` läuft am Schrittende auf den finalen Höhen, eine Zelle kann zwischen Moränen-Ablage und Messung über die 0-°C-Grenze wandern (gemessen 1.1e-4 „Schutt im Nährgebiet", der im Zehrgebiet lag).

Schichtbuchhaltung `h == rock + sed` müssen beide Eingriffe respektieren: Abrasion nimmt erst Sediment, dann Fels; die Moräne legt Sediment auf. Das Budget Moräne zu Abtrag misst `testMoraineBudgetDiagnostic` mit drei Armen (nichts / nur Abtrag / nur Moräne) aus demselben Zustand (`docs/glacier-measurements.md` §F).

Betrifft: `testMoraineBuildsAtTheTongue`, `testLayersStayConsistent`, `testMoraineBudgetDiagnostic`
