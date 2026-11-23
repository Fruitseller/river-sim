# Pinsel-Werkzeuge und Nachzug nach einem Eingriff

## Feste Nachzug-Reihenfolge beim Besitzer (Issue #93)

`recomputeFlowAfterEdit` zieht nach einem Geländeeingriff alles nach, was unmittelbar an der Höhe hängt. Die Reihenfolge stand bis #93 in der GDExtension, also bei einem Aufrufer statt beim Besitzer:

1. `computeFlow`: Entwässerung neu, damit Flüsse dem Strich folgen.
2. `snapWaterLevel`: der Darstellungs-Seespiegel snappt mit; Spieler-Feedback soll instantan sein, nur die Sim-Dynamik (Plug/Breach am Auslass) ist träge.
3. `updateClimate(dt: 0)`: die Temperatur hängt an der Höhe und muss im selben Frame mitwandern. `dt = 0` lässt die Schnee-BILANZ exakt unverändert (e⁰ = 1); sie ist Zustand und hängt an der Sim-Zeit, nicht am Pinsel.
4. `updateHeightBands`: ein Strich verschiebt die Landhöhen-Verteilung, die Färbung liest die Bänder im selben Frame.

Kein Zeitschritt, `years` bleibt stehen. Ein fünfter Pass kommt hierher, nicht zum Aufrufer (Wächter: `SimCoreTests/TerrainAPITests.swift`).

## Werkzeuge

- `sculpt` koppelt in die Tektonik: angehobene Zonen werden Hebungszonen (`upliftBase`), damit Eingriffe langfristig erhalten bleiben statt wegzuerodieren. Gekoppelt wird nur, wo der Hieb das Bett tatsächlich bewegt hat; unter Eis bleibt er wirkungslos (Issue #96, s. Bett-Funnel).
- `flatten`: die Zielhöhe sampelt der Aufrufer beim Strich-Beginn, nicht das Terrain je Aufruf.
- `roughen` nutzt das terrain-eigene Noise-Feld: wiederholte Striche vertiefen dasselbe Muster.
- `pickaxe` ist bewusst OHNE Tektonik-Kopplung: nach dem Hieb übernimmt die Natur, ein gekaperter Fluss hält sich die Rinne per Erosion offen, übertiefte Löcher füllen sich mit Sediment. Der Radius ist auf wenige Zellen gedeckelt (`pickaxeMaxCells`), unabhängig vom Pinsel-Slider: mit dessen Standardbreite (~64 Zellen) riss der "spitze Hieb" in unter einer Sekunde einen Krater bis unters Meer.

Betrifft: `Terrain.recomputeFlowAfterEdit`, `Terrain.sculpt`, `Terrain.flatten`, `Terrain.roughen`, `Terrain.pickaxe`, `Terrain.pickaxeMaxCells`, `SimCoreTests/TerrainAPITests.swift`
