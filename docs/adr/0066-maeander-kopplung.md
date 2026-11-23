# Mäander-Kopplung ins Höhenfeld (Linien-Stempel und Altarme)

`migrateMeander` frischt den Abfluss entlang der Lagrange-Läufe aus dem aktuellen Einzugsgebiet auf und migriert sie einen Zeitschritt. Die Mobilität kommt aus der lokalen Steigung: steile Oberläufe bleiben gerade, nur Flachland wandert. Degenerierte Läufe fallen weg; ist keiner mehr da, wird aus der Entwässerung neu gesät. Die Ufer-Kohäsion liest das mittlere Auwald-`veg` im Ufer-Streifen (±`meanderBankWidth`), gemittelt über ALLE Streifen-Zellen (Auwald-fremde zählen 0): eine einzelne Auwald-Zelle bremst kaum, ein voll bewachsener Streifen deutlich.

`meanderStamp` stempelt die Läufe ins Höhenfeld:
1. Bett-Carve: senkt die überstrichenen Zellen Richtung stromab-Höhe, selbstverstärkend mit D8 (das nächste `computeFlow` routet durchs Bett); gedeckelt auf einen Anteil des lokalen Gefälles (`stepCapFraction`).
2. Laterale Ufer-Verschiebung: Prallhang erodieren, Gleithang ablagern, massenerhaltend; der Prallhang fällt nie unter den Innenhang.
3. `isChannel`-Maske für die Reconciliation mit `transportLimited` und die Dämpfung der Tropfen-Deposition.

Ausnahmen:
- Unter stehendem Wasser (See, geflutete Ebene, `hf − h > 0.02`) kein Carve und keine Kanal-Maske: dort fließt nichts, und die Maske würde die Droplet-Deposition dämpfen. Der Kanal grub sonst über Jahrtausende dunkle Rinnen in Seeböden, die nie verlanden (gemessen: hf − h > 0.16 nach 24k Jahren, "dunkle Stellen").
- Unter dem Eis (Issue #35) ebenso wenig, und zwar VOR der Maske: der Funnel gatet zwar den Carve, aber ein Kanal unter einer Zunge ist kein Kanal. `isChannel` dämpft die Tropfen-Deposition und `veg = 0` reißt die Ufer-Vegetation weg; beides hat auf vergletscherten Zellen nichts zu suchen.

Ufer-Kill: das überstrichene Bett setzt `veg` hart auf 0 (absorbierend, dt-frei). Regrünung kommt per Sukzession von den Nachbarn, sobald der Lauf weiterwandert.

Altarme: `plugOxbows` verkorkt frisch abgeschnürte Schleifen an den Enden mit Sediment, sodass D8 nicht mehr hindurchroutet und die eingetiefte Schleife über den bestehenden `hf > h`-Mechanismus zum Altarm-See wird. `fillOxbows` hebt die Altarm-Betten mit der Zeitkonstante `oxbowFillYears` Richtung Uferrand an; vollständig verlandete Altarme fallen aus der Liste. Mit `byAge` (Mäandergürtel) verlandet ein Altarm im Schritt seiner Entstehung nur über sein Alter, weil er in einem Teilschritt entsteht.

Betrifft: `Terrain.migrateMeander`, `Terrain.riparianVeg`, `Terrain.meanderStamp`, `Terrain.plugOxbows`, `Terrain.fillOxbows`, `Terrain.isChannel`, `SimConfig.meanderBankWidth`, `SimConfig.oxbowFillYears`
