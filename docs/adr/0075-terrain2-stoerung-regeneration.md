# Störung und Regeneration nach Geländeeingriffen (Issue #26)

## Buchung im gemeinsamen Trichter

`registerDisturbance` bucht jede Höhenänderung eines Pinsels als Störung der Zelle: sie nimmt sofort den Zustand weg, der an der alten Topografie hing, und legt ein Regenerations-Budget an. Gebucht wird in `applyDelta`, dem gemeinsamen Trichter aller Pinsel (Anheben, Absenken, Glätten, Einebnen, Aufrauen, Spitzhacke), weil die Doktrin "ein Geländeeingriff stört den gekoppelten Zustand" für jedes Werkzeug gilt. Gebucht wird nur, wenn der Funnel die Zelle bewegt hat oder nichts zu bewegen war (`dh == 0`); eine Störung ohne Bett-Änderung wäre ein Budget ohne Gegenstück.

Zurückgesetzt wird anteilig, nicht hart: ein zaghafter Strich lichtet den Wald, ein Bagger-Zug räumt ihn ab. Übrig bleibt vom alten Zustand (`veg`, `streamRate`) genau der Anteil `1 − Störungsgrad`; die Quotienten-Form `(1 − d_neu)/(1 − d_alt)` teleskopiert über beliebig viele Striche. `vegClass` und das Kronendach (Waldmaske, Issue #152) folgen aus `veg`. Mäanderlinien und Altarme werden erst im nächsten Schritt gesäubert (`regenerateDisturbed`), weil das ein Sweep über Linien ist.

Das Budget hat zwei Anteile:
- Setzung/Rebound `−dh·disturbanceSettle`: ein Teil des bewegten Materials kommt zurück. Frische Auffüllung setzt sich (differentielle Kompaktion, über begrabenen Hochlagen weniger als über begrabenen Tälern), entlastetes Gelände hebt sich. Dieser Anteil bringt die Entwässerung wieder in Gang: begrabene Täler werden wieder Tiefenlinien. Er ist strukturtreu, nicht global; das Werkzeug bleibt wirksam, nur nicht steril.
- Mikro-Relief `raw·disturbanceReliefAmp·fBm`: Symmetriebruch für Flächen, die schon vorher eben waren. Nur der Zuwachs, der den Störungsgrad wirklich hebt, legt Relief nach; sonst summierten 200 Striche auf derselben Zelle das 200-fache Rauschen. Das fBm ist ortsfest (terrain-eigener Seed: derselbe Fleck bekommt dieselbe Rille) und gegen das Aufrau-Werkzeug um 137/91 versetzt, damit beide nicht dasselbe Muster prägen.

Beide Anteile werden über das Abklingfenster verteilt; der Sofort-Effekt des Werkzeugs bleibt exakt wie gezogen (Wächter `testFlattenIsExactlyFlatImmediately`).

## Regenerations-Pass

`regenerateDisturbed` wirkt räumlich auf `disturb > 0` und zeitlich auf `disturbanceRecoveryYears`:
1. Gelände: je Schritt der Anteil `1 − e^(−dt/τ)` des offenen Budgets. Die Summe teleskopiert exakt zum Ergebnis eines Sprungs (Wächter `testRegenerationIsFramerateIndependent`), und die exakt flache Platte bekommt den Gradienten, den `outletIncision` (überspringt gefällelose Zellen) und die Tropfen (enden bei verschwindendem Gradienten) brauchen.
2. Mäander- und Altarm-Zustand stark gestörter Zellen fällt weg (`dropDisturbedMeanderState`): eine Zentrumslinie ist die Geschichte eines Betts, das es unter dem neuen Gelände nicht mehr gibt. `migrateMeander` sät aus der aktuellen Entwässerung neu; solange die Baustelle offen ist, wird je Schritt frisch getrasst.
3. Vegetation: das Ziel wird in `updateVegetation` mit `1 − disturbanceVegSuppress·disturb` skaliert, dort, weil es ein Ziel-Effekt ist.
Dazu setzt `fillShallowPonds` aus, solange die Baustelle offen ist.

Bewusst kein globaler Servo-Eingriff: die Alterung aus Issue #13 bleibt unangetastet (`reliefServoPer100y`).

Ausgeklungen (< 1 % Reststörung ≈ 4.6 τ) schaltet der Pfad ab. Der Budget-Rest wird dabei vollständig eingetragen statt verworfen, damit die eingetragene Geländeänderung exakt das gebuchte Budget ist, egal wann die Abschaltung in einen Schritt fällt.

`applyRegenDelta` bucht keine neue Störung (sonst hielte sich der Pfad selbst am Leben) und hat nicht den Werkzeug-Deckel bei 1.4. Es schreibt über den Bett-Funnel (`raiseRockCell`/`erodeCell`): auf vergletschertem Grund verstreicht das Budget, ohne das Bett unter dem Eis zu verstellen.

Im Schritt läuft `regenerateDisturbed` vor `computeFlow`, damit die Entwässerung das neue Gelände sieht; ohne Störung ist es ein reiner Boolean-Test.

Betrifft: `Terrain.registerDisturbance`, `Terrain.applyDelta`, `Terrain.regenerateDisturbed`, `Terrain.applyRegenDelta`, `Terrain.dropDisturbedMeanderState`, `SimConfig.disturbance*`, `SimCoreTests/FlattenRegeneration.swift`
