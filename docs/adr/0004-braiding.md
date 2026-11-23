# Braiding über super-linearen Transport auf der MFD-Partition

Verflechtung als zelluläres Bänke-Bauen (Murray & Paola 1994). Die Zutat, die dem MFD-Fundament fehlt, ist SUPER-LINEARER Transport: Kapazität je MFD-Route qcᵢ = Kb·Q·Sᵢ·fᵢ^m mit m ≈ 2,5. Die Super-Linearität liegt auf der lateralen PARTITION fᵢ, nicht auf Q·S (das übers Netz 3 Dekaden spannt): ein Faden trägt mehr als zwei halbe (2·0,5^m ≈ 0,35), Fäden scouren sich ein und ziehen mehr Wasser, unterversorgte Zellen lagern ab → Mittelbänke, um die sich der Lauf teilt und wiedervereint. m > 1 ist die Bänke-bauende Instabilität.

- `braidCapacity` Kb 5,0e-6: weniger Kapazität lässt überlastete Reaches Bänke ablagern (n = 256: Insel-Summe 9 gegen 4 ohne Pass).
- `braidDispersion` 2,0: dispersiver MFD-Exponent auf FLACHEN großen subaerischen Läufen (Quinn 1995: Exponent abflussabhängig, `Terrain.mfdLocalExponent`). Hänge konvergieren mit `mfdExponent` 4 (Look), Braid-Plains spreizen mit 2,0, damit Fäden sich um Bänke teilen, ohne als Sheet-Flow zu zerlaufen. 1,3 zerlief.
- `renderMinCells` 320 liegt bewusst über dem Physik-Gate `braidMinCells` 120 (Nutzer: „zu viele Flüsse“): Braiding wirkt ab 120 weiter, sichtbar sind nur substanzielle Flüsse. Auf der größeren Karte (damals 832) qualifizierten sich sonst absolut mehr Läufe über dieselbe Schwelle.

Betrifft: `SimConfig.braidingEnabled`, `SimConfig.braidExponent`, `SimConfig.braidCapacity`, `SimConfig.braidDispersion`, `SimConfig.braidMinCells`, `SimConfig.renderMinCells`, `Terrain.braidPass`
