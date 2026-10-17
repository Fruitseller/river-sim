import Foundation
import SimCore

/// Strand und Felsküste (Issue #174, Paket C): welche Landzellen an der Küste
/// Sand tragen und welche Fels sind.
///
/// Reine Render-Ableitung aus Höhe, Abfluss und Abstand zum Meer, zustandslos,
/// ändert das Terrain nie. Kalibrierung und Begründung: `WaterRender` § Strand
/// und Felsküste. Die Gewichte fließen im `TerrainColorRenderer` in die
/// Materialpuffer (Sand im A-Kanal der Makrofarbe, Fels im G-Kanal der
/// Materialgewichte); Wächter: `SimCoreTests/CoastMaterialTests.swift`.
///
/// **Warum nicht mehr nur Höhe und Steigung.** `Terrain.wavePass` hält JEDE
/// Küste am selben Wellen-Talus; Höhe und lokale Steigung einer Küstenzelle
/// unterscheiden sich zwischen Bucht, Landzunge und Steilküste kaum (gemessen,
/// `docs/river-coast-render-measurements.md` §E): alle Küstenzellen waren Strand,
/// ein gleichbreiter Ring um die ganze Insel. Die Unterschiede liegen im
/// größeren Zusammenhang, und den liest `shore` je Küstenpunkt:
///  1. **Rückland-Relief**: wie hoch steigt das Land binnen
///     `WaterRender.beachReliefRadiusCells`? Flache Küstenebene trägt Strand,
///     ein Steilhang kommt mit Fels oder Bewuchs bis ans Wasser.
///  2. **Offenheit**: Meeresanteil im Fenster um den Küstenpunkt. Geschützte,
///     konkave Küste (Bucht) sammelt Sand, die offene, konvexe Landzunge
///     wird abgetragen. Die Sim hat kein Wellenfeld (`wavePass` ist lokal, ohne
///     Richtung oder Fetch); der Meeresanteil ist der Stellvertreter für
///     Wellenenergie.
///  3. **Sedimentzufuhr**: nahe der Mündung eines Flusses (Einzugsgebiet) liegt
///     Sand, auch an steilerer Küste; dort öffnet das Tal das Rückland.
///  4. **Rauschen** entlang der Küste bricht den Verlauf auf: die Breite
///     schwankt, Strände enden und setzen neu an.
public enum CoastMaterial {

    /// Küstenfeld einer Welt, je Zelle.
    public struct Shore {
        /// Chebyshev-Abstand (Zellen) zur nächsten Meereszelle, gedeckelt
        /// (`seaDistance`). Meer = 0.
        public let distance: [UInt8]
        /// Strandbreite landeinwärts in Zellen (0 = kein Strand), von der
        /// Küstenzelle geerbt, von der die Zelle ausgeht.
        public let beachWidth: [Float]
        /// Steilküsten-Anteil 0…1 aus dem Rückland-Relief, ebenfalls geerbt.
        public let cliff: [Float]

        public static let empty = Shore(distance: [], beachWidth: [], cliff: [])
    }

    /// Deckel des Abstandsfelds: so weit reicht jede Küsten-Ableitung
    /// landeinwärts (Brandungssaum und Strandbreite).
    static var distanceCap: Int {
        min(254, max(WaterRender.coastReachCells, Int(WaterRender.beachMaxWidthCells.rounded(.up))) + 1)
    }

    /// Chebyshev-Abstand (Zellen) jeder Zelle zur nächsten Meereszelle
    /// (`h ≤ sea`, dieselbe Meeres-Definition wie `openWaterSurface`),
    /// gedeckelt auf `distanceCap`. Meer = 0.
    public static func seaDistance(_ terrain: Terrain) -> [UInt8] {
        shoreSeeds(terrain).distance
    }

    /// Abstandsfeld plus die Küstenzellen (Abstand 1) in Zeilenreihenfolge.
    /// Breitensuche von der Küste aus: jede Zelle im Saum wird einmal besucht,
    /// die Kosten hängen am Saum und nicht an der Gittergröße.
    static func shoreSeeds(_ terrain: Terrain) -> (distance: [UInt8], origin: [Int32], seeds: [Int]) {
        let n = terrain.cfg.n
        guard n > 0, terrain.h.count == n * n else { return ([], [], []) }
        let cap = UInt8(distanceCap)
        let sea = terrain.cfg.sea
        let h = terrain.h
        var dist = [UInt8](repeating: cap, count: n * n)
        // Küstenzelle, von der die Breitensuche die Zelle erreicht (−1 = keine).
        var origin = [Int32](repeating: -1, count: n * n)
        var sea8 = [UInt8](repeating: 0, count: n * n)   // 1 = Meer
        for k in 0..<(n * n) where h[k] <= sea { dist[k] = 0; sea8[k] = 1 }
        // Land mit Meer in der 3×3-Nachbarschaft (Küstenzelle): getrennte
        // Dilatation, erst je Zeile, dann je Spalte.
        var rowNear = [UInt8](repeating: 0, count: n * n)
        sea8.withUnsafeBufferPointer { mb in
        rowNear.withUnsafeMutableBufferPointer { rb in
            let pm = mb.baseAddress!, pr = rb.baseAddress!
            parallelChunks(n) { jLo, jHi in
                for j in jLo..<jHi {
                    for i in 0..<n {
                        var v = pm[j * n + i]
                        if i > 0 { v |= pm[j * n + i - 1] }
                        if i < n - 1 { v |= pm[j * n + i + 1] }
                        pr[j * n + i] = v
                    }
                }
            }
        }}
        var seeds: [Int] = []
        for j in 0..<n {
            for i in 0..<n {
                let k = j * n + i
                guard dist[k] != 0 else { continue }
                var near = rowNear[k]
                if j > 0 { near |= rowNear[k - n] }
                if j < n - 1 { near |= rowNear[k + n] }
                if near != 0 { seeds.append(k) }
            }
        }
        var queue = seeds
        for k in seeds { dist[k] = 1; origin[k] = Int32(k) }
        var head = 0
        while head < queue.count {
            let k = queue[head]; head += 1
            let d = dist[k]
            guard d < cap else { continue }
            let i = k % n, j = k / n
            for nj in max(0, j - 1)...min(n - 1, j + 1) {
                for ni in max(0, i - 1)...min(n - 1, i + 1) {
                    let nb = nj * n + ni
                    if dist[nb] > d + 1 {
                        dist[nb] = d + 1
                        origin[nb] = origin[k]
                        queue.append(nb)
                    }
                }
            }
        }
        return (dist, origin, seeds)
    }

    /// Küstenfeld der Welt: Abstand, Strandbreite und Steilküste je Zelle.
    public static func shore(_ terrain: Terrain) -> Shore {
        let n = terrain.cfg.n
        let (dist, origin, seeds) = shoreSeeds(terrain)
        guard n > 2, !dist.isEmpty else { return Shore(distance: dist, beachWidth: [], cliff: []) }
        let h = terrain.h, sea = terrain.cfg.sea

        // Offenheit: Meeresanteil im Fenster, über ein Summenbild.
        let r = max(1, WaterRender.beachOpenRadiusCells)
        var sum = [Int32](repeating: 0, count: (n + 1) * (n + 1))
        for j in 0..<n {
            var row: Int32 = 0
            for i in 0..<n {
                if h[j * n + i] <= sea { row += 1 }
                sum[(j + 1) * (n + 1) + i + 1] = sum[j * (n + 1) + i + 1] + row
            }
        }
        func openness(_ i: Int, _ j: Int) -> Double {
            let i0 = max(0, i - r), i1 = min(n - 1, i + r), j0 = max(0, j - r), j1 = min(n - 1, j + r)
            let s = sum[(j1 + 1) * (n + 1) + i1 + 1] - sum[j0 * (n + 1) + i1 + 1]
                - sum[(j1 + 1) * (n + 1) + i0] + sum[j0 * (n + 1) + i0]
            return Double(s) / Double((i1 - i0 + 1) * (j1 - j0 + 1))
        }
        // Rückland-Relief: höchste Höhe im Fenster über der Küstenzelle.
        let rr = max(1, WaterRender.beachReliefRadiusCells)
        func relief(_ i: Int, _ j: Int) -> Double {
            var top = h[j * n + i]
            for jj in max(0, j - rr)...min(n - 1, j + rr) {
                for ii in max(0, i - rr)...min(n - 1, i + rr) { top = max(top, h[jj * n + ii]) }
            }
            return top - h[j * n + i]
        }
        let supply = mouthSupply(terrain, seeds: seeds)

        var width = [Float](repeating: 0, count: n * n)
        var cliff = [Float](repeating: 0, count: n * n)
        for (index, k) in seeds.enumerated() {
            let i = k % n, j = k / n
            guard i >= 2, i < n - 2, j >= 2, j < n - 2 else { continue }
            let (w, c) = beach(relief: relief(i, j), openness: openness(i, j),
                               supply: supply[index], noise: alongShoreNoise(i, j))
            width[k] = Float(w)
            cliff[k] = Float(c)
        }
        // Jede Saumzelle erbt von ihrer Küstenzelle.
        var inherited = width, inheritedCliff = cliff
        for k in 0..<(n * n) {
            let o = Int(origin[k])
            if o >= 0, o != k { inherited[k] = width[o]; inheritedCliff[k] = cliff[o] }
        }
        return Shore(distance: dist, beachWidth: inherited, cliff: inheritedCliff)
    }

    /// Die Stellschrauben der Küstenableitung aus `WaterRender`. Eine eigene
    /// Struktur nur, damit die Messreihe (`CoastShapeTests`) Alternativen
    /// durchrechnen kann, ohne Konstanten umzuschreiben; Produktion liest
    /// immer `.calibrated`.
    struct Calibration {
        var reliefLo = WaterRender.beachReliefLo, reliefHi = WaterRender.beachReliefHi
        var openLo = WaterRender.beachOpenLo, openHi = WaterRender.beachOpenHi
        var exposedShare = WaterRender.beachExposedShare
        var supplyReliefCut = WaterRender.beachSupplyReliefCut
        var noiseAmplitude = WaterRender.beachNoiseAmplitude
        var supplyNoiseCut = WaterRender.beachSupplyNoiseCut
        var potentialLo = WaterRender.beachPotentialLo, potentialHi = WaterRender.beachPotentialHi
        var maxWidth = WaterRender.beachMaxWidthCells
        var cliffLo = WaterRender.cliffReliefLo, cliffHi = WaterRender.cliffReliefHi
        var cliffExposedBoost = WaterRender.cliffExposedBoost

        static let calibrated = Calibration()
    }

    /// Strandbreite (Zellen) und Steilküsten-Anteil eines Küstenpunkts.
    /// Reine Funktion der vier Größen — Kalibrierung `WaterRender` § Strand.
    static func beach(relief: Double, openness: Double, supply: Double, noise: Double,
                      _ c: Calibration = .calibrated) -> (width: Double, cliff: Double) {
        // Die Mündung öffnet das Rückland: das Tal zählt halb.
        let effective = relief * (1 - c.supplyReliefCut * supply)
        let plain = 1 - smoothstep(c.reliefLo, c.reliefHi, effective)
        let shelter = 1 - smoothstep(c.openLo, c.openHi, openness)
        var potential = plain * (c.exposedShare + (1 - c.exposedShare) * max(shelter, supply))
        // Wo ein Fluss Sand liefert, bricht das Rauschen den Strand weniger auf.
        potential += c.noiseAmplitude * (1 - c.supplyNoiseCut * supply) * (noise - 0.5)
        let strength = smoothstep(c.potentialLo, c.potentialHi, potential)
        // Offene Landzungen wirken steiler: der Fels reicht früher bis ans Wasser.
        let exposure = smoothstep(c.openLo, c.openHi, openness)
        let steep = relief * (1 + c.cliffExposedBoost * exposure)
        let rock = smoothstep(c.cliffLo, c.cliffHi, steep)
        return (strength * c.maxWidth, rock * (1 - strength))
    }

    /// Sedimentzufuhr 0…1 je Küstenzelle: Nähe zu Flussmündungen, gewichtet
    /// nach dem Einzugsgebiet (log-Rampe `beachSupplyMinCells…beachSupplyFullCells`).
    static func mouthSupply(_ terrain: Terrain, seeds: [Int]) -> [Double] {
        let n = terrain.cfg.n, sea = terrain.cfg.sea
        let h = terrain.h, rec = terrain.receiver, area = terrain.area
        let cellArea = terrain.cfg.cellSize * terrain.cfg.cellSize
        var out = [Double](repeating: 0, count: seeds.count)
        guard rec.count == n * n, area.count == n * n, cellArea > 0, cellArea.isFinite else { return out }
        let lo = WaterRender.beachSupplyMinCells, hi = WaterRender.beachSupplyFullCells
        // Eine Mündung ist eine Landzelle mit Meer als D8-Empfänger — also selbst
        // eine Küstenzelle.
        var mouths: [(i: Int, j: Int, weight: Double)] = []
        for k in seeds {
            let r = Int(rec[k])
            guard r >= 0, r < n * n, h[r] <= sea else { continue }
            let q = area[k] / cellArea
            guard q.isFinite, q >= lo else { continue }
            mouths.append((k % n, k / n, clamp01(log(q / lo) / log(hi / lo))))
        }
        guard !mouths.isEmpty else { return out }
        let reach = WaterRender.beachSupplyReachCells
        for (index, k) in seeds.enumerated() {
            let i = k % n, j = k / n
            var best = 0.0
            for m in mouths {
                let d = (Double((m.i - i) * (m.i - i) + (m.j - j) * (m.j - j))).squareRoot()
                guard d < reach else { continue }
                // Auch der kleinste zählende Fluss liefert etwas.
                let weight = WaterRender.beachSupplyFloor + (1 - WaterRender.beachSupplyFloor) * m.weight
                best = max(best, weight * (1 - smoothstep(0, reach, d)))
            }
            out[index] = best
        }
        return out
    }

    /// Value-Noise 0…1 über die Zellkoordinaten (zwei Oktaven): hängt nur an
    /// der Zellenlage, springt also im Zeitraffer nicht, wenn die Küste wandert.
    static func alongShoreNoise(_ i: Int, _ j: Int) -> Double {
        let scale = WaterRender.beachNoiseCells
        func hash(_ x: Int, _ y: Int) -> Double {
            var v = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
            v = (v ^ (v >> 13)) &* 1_274_126_177
            v ^= v >> 16
            return Double(v & 0xFFFF) / 65535
        }
        func value(_ x: Double, _ y: Double) -> Double {
            let xi = Int(x.rounded(.down)), yi = Int(y.rounded(.down))
            let fx = x - Double(xi), fy = y - Double(yi)
            let ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy)
            let a = hash(xi, yi), b = hash(xi + 1, yi), c = hash(xi, yi + 1), d = hash(xi + 1, yi + 1)
            return (a + (b - a) * ux) + ((c + (d - c) * ux) - (a + (b - a) * ux)) * uy
        }
        let x = Double(i) / scale, y = Double(j) / scale
        return 0.65 * value(x, y) + 0.35 * value(x * 2.3 + 17.1, y * 2.3 + 5.7)
    }

    /// In Reichweite der Brandung? `distance` aus `seaDistance`; Meer (0)
    /// selbst ist keine Küste.
    @inline(__always)
    static func inSurf(_ distance: UInt8) -> Bool {
        distance >= 1 && Int(distance) <= WaterRender.coastReachCells
    }

    /// Sandgewicht 0…1 einer Landzelle: so breit wie der Strand ihres
    /// Küstenpunkts (`width` in Zellen), flach und knapp über dem Meer.
    /// `height` = Höhe über dem Meeresspiegel. Die Strandkante läuft über
    /// eine Zelle aus.
    @inline(__always)
    public static func sand(distance: UInt8, width: Float, slope: Double, height: Double) -> Double {
        guard distance >= 1, height > 0 else { return 0 }
        let reach = clamp01(Double(width) - Double(distance - 1))
        guard reach > 0 else { return 0 }
        return reach
            * (1 - smoothstep(WaterRender.beachSlopeLo, WaterRender.beachSlopeHi, slope))
            * (1 - smoothstep(WaterRender.beachHeightLo, WaterRender.beachHeightHi, height))
    }

    /// Felsgewicht 0…1 einer Küstenzelle in Reichweite der Brandung: steile
    /// lokale Steigung ODER steiles Rückland (`relief` = Steilküsten-Anteil
    /// des Küstenpunkts).
    @inline(__always)
    public static func cliff(distance: UInt8, slope: Double, relief: Float) -> Double {
        guard inSurf(distance) else { return 0 }
        return max(smoothstep(WaterRender.cliffCoastSlopeLo, WaterRender.cliffCoastSlopeHi, slope),
                   Double(relief))
    }
}
