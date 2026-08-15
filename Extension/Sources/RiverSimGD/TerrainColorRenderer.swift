import Foundation
import SwiftGodot
import SimCore

/// Biom-/Höhen-Färbung des Geländes als RGBA8-Puffer (Issue #53 aus `SimNode`
/// ausgelagert) — direkt als Farb-Textur hochladbar, kein GDScript-Loop nötig.
///
/// Zustandslos: die Färbung ist eine reine Funktion der Sim-Felder. Die
/// FORMELN dahinter (Standort-Eignung, Schnee-/Eis-Deckung, Höhenbänder) stehen
/// bewusst im Sim-Kern — hier stehen nur die Farben und ihre Reihenfolge, sonst
/// zeigte die Färbung etwas anderes als die Sim rechnet.
enum TerrainColorRenderer {

    /// Biom-/Höhen-Färbung (aus dem Prototyp) als RGBA8-Byte-Buffer (n*n*4).
    static func bytes(_ terrain: Terrain) -> PackedByteArray {
        let n = terrain.cfg.n
        let sea = terrain.cfg.sea
        let h = terrain.h, rain = terrain.rain, veg = terrain.veg
        let salt = terrain.saltCrust
        // Lithologie (Issue #12): Gesteinshärte je Zelle (−1 weich … +1 hart) für
        // eine DEZENTE Färbung der Schichten. Nur `lithologyEnabled = false` lässt
        // das Feld leer — dann greift der 1-Element-Dummy und die Farben sind exakt
        // die von vorher. Der MESS-Referenzarm (`lithContrast = 0`) hat das Feld
        // dagegen gefüllt: dort ist die Physik uniform, die Bänder werden aber
        // trotzdem gemalt. Das ist gewollt — so lässt sich die Färbung gegen ein
        // Terrain vergleichen, das die Härte nicht gespürt hat.
        let lith = terrain.lithHardness.count == n * n ? terrain.lithHardness : [0.0]
        let lithOn = lith.count == n * n
        // Schneedecke (Issue #33): die Färbung liest jetzt das FELD je Zelle statt
        // eines Höhenbands — nur so wird das Luv/Lee-Signal der Akkumulation
        // sichtbar (dieselbe Orographie, die `rain` verteilt). Ohne Klima ist das
        // Feld leer, der 1-Element-Dummy greift und die Färbung fällt exakt auf
        // `bands.snowAmount(h)` von vor #33 zurück.
        let snow = terrain.snow.count == n * n ? terrain.snow : [0.0]
        let snowOn = snow.count == n * n
        let snowRef = terrain.cfg.snowCoverRef
        // Gletschereis (Issue #35): eigenes Feld, eigene Farbe. Ohne Klima oder
        // mit `iceEnabled = false` ist es leer bzw. konstant 0 → der Zweig fällt
        // weg und es bleibt beim Schnee-Bild von #33.
        let ice = terrain.ice.count == n * n ? terrain.ice : [0.0]
        let iceOn = ice.count == n * n
        let iceRef = terrain.cfg.iceCoverRef
        // Höhenbänder (Issue #4): einmal je Puffer gelesen — sie kommen aus dem
        // Sim-Kern (Perzentile der Landhöhen), nicht aus einer zweiten Kopie hier.
        let bands = terrain.heightBands
        var out = [UInt8](repeating: 255, count: n * n * 4)
        // Wasser (Flüsse/Seen/Altarme) zeichnet das separate Wasser-Feld (WaterFieldRenderer)
        // als glattes, geshadetes Overlay — hier nur Land-Biome + Meeresgrund.
        // Jede Zelle schreibt nur ihre 4 Bytes → zeilenparallel, bit-identisch.
        h.withUnsafeBufferPointer { hb in
        rain.withUnsafeBufferPointer { rnb in
        veg.withUnsafeBufferPointer { vgb in
        salt.withUnsafeBufferPointer { slb in
        lith.withUnsafeBufferPointer { ltb in
        snow.withUnsafeBufferPointer { snb in
        ice.withUnsafeBufferPointer { icb in
        out.withUnsafeMutableBufferPointer { ob in
        let ph = hb.baseAddress!, prain = rnb.baseAddress!
        let pveg = vgb.baseAddress!, psalt = slb.baseAddress!, pout = ob.baseAddress!
        let plith = ltb.baseAddress!, psnow = snb.baseAddress!, pice = icb.baseAddress!
        parallelChunks(n) { jLo, jHi in
        for j in jLo..<jHi {
            for i in 0..<n {
                let k = j * n + i
                var r = 0.0, g = 0.0, b = 0.0
                let v = ph[k]
                if v <= sea + 0.012 {
                    (r, g, b) = gradColor(v)
                } else {
                    // Fels-first, naturalistisch entsättigt (Vorbild nickmcd): grauer
                    // Fels dominiert, Grün nur in feuchten flachen Tälern, helle
                    // Gipfel/Schnee. Die Zerklüftung/Schattierung macht das Licht.
                    // Steigung GROB (±2 Zellen, Terrain.macroSlope): seit der
                    // Pre-Erosion trägt jede Zelle feine Rinnen — die Per-Zell-
                    // Steigung wäre überall „steil" und würde die Vegetation aus
                    // allen Tälern waschen. Für die Biom-Färbung zählt der
                    // Hang-Charakter, nicht die Rinnen-Textur.
                    var slope = 0.0
                    if i > 1 && i < n - 2 && j > 1 && j < n - 2 {
                        slope = Terrain.macroSlope(ph, k, n)
                    }
                    let steep = min(1, slope * 45)                // 0 flach … 1 steil
                    r = 0.38 + 0.05 * steep                       // grauer Fels; steiler nur LEICHT heller
                    g = 0.39 + 0.05 * steep                       // (0.11 wusch die dichten 100k-Rinnen weiß)
                    b = 0.40 + 0.05 * steep
                    // Grünanteil aus DERSELBEN Standort-Eignung, die auch das
                    // veg-Ziel im Sim-Kern setzt (Issue #4) — vorher lagen hier
                    // eigene Konstanten (Höhenabfall ab 0.6 statt 0.5, Regen 1.2
                    // statt 1.3), die Färbung zeigte also nicht ganz das, was die
                    // Sim rechnet. `pveg` bleibt der zeitliche Zustand darüber.
                    // 0.85-Dämpfung: das Boden-Grün leicht entsättigen, damit die
                    // 3D-Bäume (MultiMesh, TreeInstanceRenderer) sich vom Boden abheben —
                    // vorher konkurrierte das satte Moosgrün mit den Baumkronen.
                    let habitat = Terrain.vegetationSuitability(height: v, slope: slope,
                                                                rain: prain[k], bands: bands)
                    let vegAmt = min(1, (0.5 + 0.5 * pveg[k]) * habitat * 1.3) * 0.85
                    r += (0.19 - r) * vegAmt; g += (0.42 - g) * vegAmt; b += (0.14 - b) * vegAmt // kräftigeres Moosgrün
                    // Hochlagen: neutral-grauer Fels (nicht pastell/weiß), darüber
                    // Schnee auf den Gipfeln. Die FELS-Grenze ist ein PERZENTIL der
                    // aktuellen Landhöhen (Issue #4, Terrain.heightBands): die alten
                    // absoluten 0.58/1.05 trafen 1.1 % bzw. 0 % des Landes.
                    let wg = bands.rockAmount(v)
                    if wg > 0 {
                        r += (0.43 - r) * wg; g += (0.44 - g) * wg; b += (0.45 - b) * wg
                    }
                    // Der SCHNEE kommt dagegen aus der Massenbilanz (Issue #33).
                    // Die Sättigungs-Formel steht im Sim-Kern
                    // (Terrain.snowCoverage) — hier nur der Aufruf über den rohen
                    // Puffer, keine zweite Kopie. Ohne Klima der Höhenband-Rückfall.
                    let ws = snowOn ? Terrain.snowCoverage(swe: psnow[k], ref: snowRef)
                                    : bands.snowAmount(v)
                    if ws > 0 {
                        r += (0.93 - r) * ws; g += (0.94 - g) * ws; b += (0.96 - b) * ws
                    }
                    // GLETSCHEREIS (Issue #35) liegt ÜBER dem Schnee — es ist die
                    // obere Schicht, und es soll sich davon absetzen: kühleres,
                    // deutlich blaueres Weiß (Firn/Gletschereis streut lange
                    // Wellenlängen weg) statt des neutralen Schneeweiß. Nur so
                    // ist im Bild ablesbar, wo eine ZUNGE liegt und wo bloß eine
                    // Schneedecke — die beiden Felder haben verschiedene Physik
                    // (die eine fließt und erodiert, die andere nicht).
                    // Sättigungs-Formel wie beim Schnee im Sim-Kern
                    // (Terrain.iceCoverage), hier nur der Aufruf über den rohen
                    // Puffer — keine zweite Kopie.
                    let wi = iceOn ? Terrain.iceCoverage(thickness: pice[k], ref: iceRef) : 0
                    if wi > 0 {
                        r += (0.74 - r) * wi; g += (0.85 - g) * wi; b += (0.94 - b) * wi
                    }
                    // Salzpfanne/Playa (Issue #11): der trockengefallene Boden
                    // eines abflusslosen Beckens ist NICHT mehr blau (das
                    // Wasser-Overlay malt dort nichts mehr) — als graugrünes Land
                    // wäre er aber auch nicht als das erkennbar, was er ist.
                    // Deshalb der Verdunstungsrückstand: helle, leicht warme
                    // Kruste (Terrain.saltCrust, 0 außerhalb solcher Becken).
                    // Deckel 0.9: die Kruste bleibt unter dem Gipfel-Schnee
                    // (0.93+) und liest sich als matter Salzboden, nicht als
                    // Schneefeld im Tal.
                    let sc = min(1, max(0, psalt[k])) * 0.9
                    if sc > 0 {
                        r += (0.87 - r) * sc; g += (0.86 - g) * sc; b += (0.80 - b) * sc
                    }
                    // Gesteinsbänder (Issue #12): hartes Gestein dunkler und
                    // wärmer, weiches heller — damit Schichtstufen und Härtekanten
                    // auch dort ablesbar sind, wo die Kante flach angeschnitten
                    // ist. Amplitude bewusst klein (±0.05): das Biom-Signal
                    // (Fels/Moos/Schnee) bleibt dominant, die Bänder sind Textur,
                    // keine zweite Farbskala.
                    if lithOn {
                        let hard = min(1, max(-1, plith[k])) * 0.05
                        r -= hard * 0.85; g -= hard; b -= hard * 1.25
                    }
                }
                let o = k * 4
                pout[o] = UInt8(min(max(r, 0), 1) * 255)
                pout[o + 1] = UInt8(min(max(g, 0), 1) * 255)
                pout[o + 2] = UInt8(min(max(b, 0), 1) * 255)
                // pout[o+3] bleibt 255 (Alpha)
            }
        }
        }
        }}}}}}}}
        return PackedByteArray(out)
    }

    // Höhen-Farbverlauf (Schwelle, r, g, b) — portiert aus dem Prototyp.
    private static let stops: [(Double, Double, Double, Double)] = [
        (-0.3, 0.02, 0.07, 0.20), (0.00, 0.08, 0.22, 0.45), (0.15, 0.20, 0.42, 0.60),
        (0.17, 0.76, 0.70, 0.50), (0.28, 0.25, 0.48, 0.22), (0.45, 0.16, 0.34, 0.16),
        (0.58, 0.42, 0.38, 0.34), (0.70, 0.55, 0.53, 0.51), (0.80, 0.95, 0.96, 0.98),
    ]
    private static func gradColor(_ v: Double) -> (Double, Double, Double) {
        for k in 0..<(stops.count - 1) {
            if v <= stops[k + 1].0 {
                let a = stops[k], c = stops[k + 1]
                let t = min(max((v - a.0) / (c.0 - a.0), 0), 1)
                return (a.1 + (c.1 - a.1) * t, a.2 + (c.2 - a.2) * t, a.3 + (c.3 - a.3) * t)
            }
        }
        let c = stops[stops.count - 1]
        return (c.1, c.2, c.3)
    }
}
