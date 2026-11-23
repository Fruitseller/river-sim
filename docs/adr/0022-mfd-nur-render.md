# Multi-Flow-Drainage speist nur Render und Braiding, nie die Erosion

Freeman (1991)/Holmgren (1994): der Abfluss wird STETIG an alle tieferen Nachbarn verteilt (fᵢ = Sᵢᵖ/ΣSⱼᵖ) statt komplett an den steilsten (D8-argmax). Das erlaubt Aufspalten um Mittelbänke mit Wiedervereinigung (mit D8 unmöglich) und stetiges Gleiten des Laufs statt Springen (D8 würfelt gemessen ~27 % der Empfänger je Flow-Update neu). MFD speist NUR `areaMFD` (Wasserfeld); die Inzision bleibt bewusst Single-Flow, damit der kalibrierte Terrain-Look und die implizite FastScape-Stabilität unangetastet bleiben.

Exponent p = 4: p → ∞ ist D8, p = 1,1 maximal dispersiv (Braiding-Regime), p ≈ 4 hält den dendritischen Look. Auf flachen großen Läufen gilt stattdessen `braidDispersion` (`Terrain.mfdLocalExponent`).

Aktualisierungstakt: ohne Braiding darf das reine Render-MFD seltener aktualisiert werden. Mit Braiding bleibt es immer frisch, weil es dort ein physikalisches Feld ist. Der Core-Default bleibt 1.

Betrifft: `SimConfig.mfdExponent`, `SimConfig.mfdUpdateInterval`, `Terrain.areaMFD`, `Terrain.mfdLocalExponent`
