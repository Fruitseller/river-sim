# Abklingende Hebung: geschlossene Form und exakte Integration

Die Hebung folgt `U(t) = U_floor + (U₀ − U_floor)·e^(−t/τ)` (`docs/research-terrain-aging.md` §3). Der Schritt integriert sie exakt (`upliftDecayAmount`: die Summe der e-Funktions-Differenzen teleskopiert) statt „Rate × dt" am Schrittanfang, das bei kleinem dt systematisch zu viel höbe. Viele Mini-Schritte und ein großer Sprung tragen dadurch exakt dieselbe Hebung ein.

Schneidet U(t) die Servo-Untergrenze mitten im Schritt, wäre `max(∫U dt, U_servo·dt)` schrittweiten-abhängig: der große Schritt liefe komplett auf der U-Kurve, kleine Schritte lägen hinten schon auf der Untergrenze. `upliftAmount` zieht das max unter das Integral und teilt am Schnittpunkt. Größenordnung des alten Fehlers im Testaufbau (Schnitt bei 1,5 τ = 60.000 Jahre, Sprung 40k → 80k): 0,09897 statt korrekt 0,10582 (−6,5 %).

Die Anzeige-Rate `upliftDecayRatePer100y()` und die integrierte Hebung beschreiben dieselbe Kurve: die mittlere Rate über einen Sprung liegt zwischen Anfangs- und Endrate. Ohne diese Kopplung zeigte die Diagnose etwas anderes, als die Sim einträgt. Die Rate startet bei U₀, fällt monoton gegen U_floor und liegt nach 4 τ innerhalb e⁻⁴ ≈ 1,8 % des Überschusses.

Betrifft: `Terrain.upliftDecayAmount`, `Terrain.upliftAmount`, `Terrain.upliftDecayRatePer100y`, `TerrainAging`, `TerrainAPITests`
