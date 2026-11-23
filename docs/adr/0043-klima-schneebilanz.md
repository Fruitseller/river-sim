# Klima-Vertikale: Temperatur aus der Höhe, Schnee als exakt gelöste Bilanz

`updateClimate` (Issue #33) rechnet je Zelle:

    T   = T₀ − Γ·max(0, h − sea)                 (Meer trägt überall T₀)
    f_s = clamp((T_regen − T)/(T_regen − T_frost), 0, 1)
    a   = c_akk · rain · f_s                     Akkumulation
    μ   = 1/τ₀ + c_schmelz · max(0, T)           Ablations-Ratenkonstante
    S   ← S* + (S − S*)·e^(−μ·dt),  S* = a/μ     exakte Lösung von Ṡ = a − μS

`temperature` ist eine reine Ableitung aus der Höhe, liegt aber im Zustandsinventar (wie `rain`/`hf`: der erste Frame nach dem Laden soll stimmen). Es gibt keinen vertikalen Meter-Maßstab; die Kopplung Höhe → Temperatur ist bei `SimConfig.climateLapseRate` hergeleitet. `snow` ist echter Bilanzzustand als Schneewasser-Äquivalent in abstrakten Einheiten, SWE 1.0 ≙ voll ausgebildete Dauerschneedecke (`SimConfig.snowAccumPerYear`). Konsumenten: Schneedeckung (`snowCover`) und die Rückrechnung der Schneegrenze in `updateHeightBands`. Kein Erosionspass, bewusste Scope-Grenze (`SimConfig.climateEnabled`).

dt-Invarianz: N Schritte à dt liefern denselben Faktor wie einer à N·dt, weil `S*` je Schritt fest ist und `e^(−μdt)^N = e^(−μNdt)`. Die klassische degree-day-Form mit `max(0, …)` wäre das schon für dt > 0 nicht (`SimConfig.snowMeltPerKYear`). `dt = 0` (Sculpt-Pfad, `recomputeFlow`) zieht nur die Temperatur nach; die Bilanz wird übersprungen statt mit e⁰ = 1 gerechnet, weil `target + (S − target)·1` in Fließkomma nicht garantiert auf `S` zurückrundet und ein zeitloser Schritt die persistierte Bilanz nicht um ein ULP verschieben darf.

Operator-Splitting: `T` liest die finalen Höhen des Schritts, `rain` das Feld vom Schrittanfang; die Feuchte ändert sich über Jahrhunderte nicht sprunghaft. Je Zelle unabhängig, parallel bit-identisch.

Schnell-Ausstieg: eine schneefreie Zelle ohne Zufuhr (Ziel 0, Vorrat 0) ergibt exakt 0, das `exp` wird übersprungen, bit-identisch. Das trägt die große Mehrheit der Zellen (Meer und alles Land unter der Regen/Schnee-Grenze, bei Produktionswerten h < 0.458); bei n=832 fällt der Pass von 3.12 ms auf unter 1 ms (`docs/climate-snow-measurements.md` §7).

Aus heißt leer: ohne `cfg.climateEnabled` werden `temperature`, `snow` und `ice` geleert, kein Konsument findet ein Feld, alle rechnen mit dem Rückfall von vor #33 (dasselbe Muster wie Lithologie und Regen-Gewichtung).

Betrifft: `Terrain.updateClimate`, `Terrain.temperature`, `Terrain.snow`, `SimConfig.climateEnabled`, `SimConfig.climateLapseRate`, `SimConfig.snowMeltPerKYear`
