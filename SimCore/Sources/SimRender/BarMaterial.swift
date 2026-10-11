import Foundation
import SimCore

/// Material des Mäandergürtels (Issue #174, Paket C Teil 2): Sand- und
/// Kiesbänke, Scroll-Bars und die Verlandung der Altarme, je Zelle.
///
/// Reine Render-Ableitung aus dem Sim-Zustand von Paket B, zustandslos, ändert
/// das Terrain nie (Muster wie `ForestCanopyMask`):
///  1. **Sand** auf frischen Gleithang-Bänken (`Terrain.barAge`): hell bis
///     `WaterRender.barSandYearsLo` Jahre nach der letzten Ablagerung, danach
///     liest die Bank als Wiese — die Sim-Vegetation wächst auf ihr nach.
///  2. **Scroll-Bars** als Rippen über den Isolinien des Bankalters (jede
///     Isolinie ist eine frühere Lage des Gleithangs). Die Höhe kann sie auf
///     diesem Gitter nicht tragen; hier wechseln Rücken (heller, trockener)
///     und Senken (feuchter Sand, grünere Wiese). Wo die Rippen enger als
///     `barScrollMinSpacingLo` Zellen stünden, blenden sie aus (Aliasing).
///  3. **Altarme** färben über ihr Alter (`MeanderState.oxbowAge`): Ried in
///     der feuchten Senke, später ein Vegetationsbogen. Das Wasserband blendet
///     darüber wie bisher über `WaterRender.oxbowVisibleYears` aus.
///
/// Leser: `TerrainColorRenderer` (Materialgewichte, Sand im A-Kanal der
/// Makrofarbe) und `WaterProtectMask` (kein Wald, keine Verschiebung auf
/// frischen Bänken). Den Cache hält `RenderState`. Kalibrierung:
/// `SimCore.WaterRender` § Mäandergürtel im Render; Wächter:
/// `SimCoreTests/BarMaterialTests.swift`.
public enum BarMaterial {

    public struct Field: Equatable {
        /// Sandgewicht 0 … 1 (frische Bank, mit Scroll-Rippen).
        public var sand: [Float]
        /// Verschiebung des Vegetationsgewichts (−1 … +1): Rippen-Senken und
        /// alte Altarm-Bögen grüner, Rippen-Rücken magerer.
        public var vegShift: [Float]
        /// Ried-Gewicht 0 … 1 (verlandender Altarm): Makrofarbe olivbraun.
        public var reed: [Float]

        public static let empty = Field(sand: [], vegShift: [], reed: [])

        /// Passt das Feld zu einem n×n-Gitter?
        public func fits(_ count: Int) -> Bool {
            sand.count == count && vegShift.count == count && reed.count == count
        }
    }

    /// Feld für das ganze Gitter. Ohne Bank-Zustand (`barAge` leer oder
    /// falsch lang) bleiben Sand und Rippen 0; Altarme wirken trotzdem.
    public static func field(_ terrain: Terrain) -> Field {
        let n = terrain.cfg.n
        let cnt = n * n
        guard n > 2 else { return .empty }
        var sand = [Float](repeating: 0, count: cnt)
        var vegShift = [Float](repeating: 0, count: cnt)
        var reed = [Float](repeating: 0, count: cnt)
        let age = terrain.barAge
        let hasBars = age.count == cnt

        if hasBars {
            age.withUnsafeBufferPointer { ab in
            sand.withUnsafeMutableBufferPointer { sb in
            vegShift.withUnsafeMutableBufferPointer { vb in
                let pa = ab.baseAddress!, ps = sb.baseAddress!, pv = vb.baseAddress!
                parallelChunks(n) { jLo, jHi in
                    for j in jLo..<jHi {
                        for i in 0..<n {
                            let k = j * n + i
                            let a = pa[k]
                            guard a >= 0 else { continue }
                            let ripple = WaterRender.barScroll(
                                age: a, gradientYearsPerCell: ageGradient(pa, i, j, n))
                            let s = WaterRender.barSand(age: a)
                            // Im Sand: die Senke ist feucht und dunkler.
                            ps[k] = Float(s * (1 - WaterRender.barScrollSandDepth * max(0, ripple)))
                            // In der Wiese: Senke (+) grüner, Rücken (−) magerer;
                            // auf Sand wirkt die Verschiebung nicht (dort trägt
                            // der Sand die Rippe).
                            pv[k] = Float((1 - s) * WaterRender.barScrollVegGain * ripple)
                        }
                    }
                }
            }}}
        }

        if hasBars { sand = despeckle(sand, n: n) }
        stampOxbows(terrain, n: n, barAge: hasBars ? age : [], vegShift: &vegShift, reed: &reed)
        return Field(sand: sand, vegShift: vegShift, reed: reed)
    }

    /// Einzelne Sandzellen ohne Bank daneben (feste Läufe stempeln je Schritt
    /// einzelne Zellen frisch) sind keine Bank, sondern Sprenkel quer über die
    /// Aue — auf der Draufsicht als Pünktchen sichtbar. Sand bleibt nur, wo
    /// genug der 8 Nachbarn selbst Sand tragen (`barSandNeighbours*`).
    private static func despeckle(_ sand: [Float], n: Int) -> [Float] {
        var out = sand
        let lo = WaterRender.barSandNeighboursLo, hi = WaterRender.barSandNeighboursHi
        sand.withUnsafeBufferPointer { sb in
        out.withUnsafeMutableBufferPointer { ob in
            let ps = sb.baseAddress!, po = ob.baseAddress!
            parallelChunks(n) { jLo, jHi in
                for j in jLo..<jHi {
                    for i in 0..<n where ps[j * n + i] > 0 {
                        var count = 0
                        for nj in max(0, j - 1)...min(n - 1, j + 1) {
                            for ni in max(0, i - 1)...min(n - 1, i + 1)
                            where (ni != i || nj != j) && ps[nj * n + ni] > 0.05 { count += 1 }
                        }
                        po[j * n + i] = ps[j * n + i] * Float(smoothstep(lo, hi, Double(count)))
                    }
                }
            }
        }}
        return out
    }

    /// Betrag des Altersgradienten (Jahre je Zelle) über die Nachbarn, die
    /// selbst Bank sind; 0, wo keine Nachbarbank da ist.
    @inline(__always)
    private static func ageGradient(_ pa: UnsafePointer<Double>, _ i: Int, _ j: Int, _ n: Int) -> Double {
        let k = j * n + i
        @inline(__always) func axis(_ lo: Int?, _ hi: Int?) -> Double {
            let a = lo.map { pa[$0] } ?? -1, b = hi.map { pa[$0] } ?? -1
            if a >= 0 && b >= 0 { return 0.5 * (b - a) }
            if b >= 0 { return b - pa[k] }
            if a >= 0 { return pa[k] - a }
            return 0
        }
        let gx = axis(i > 0 ? k - 1 : nil, i < n - 1 ? k + 1 : nil)
        let gz = axis(j > 0 ? k - n : nil, j < n - 1 ? k + n : nil)
        return (gx * gx + gz * gz).squareRoot()
    }

    /// Ried und Vegetationsbogen der Altarme. Dieselben Schleifen wie das
    /// Wasserband (`oxbowMinimumNodes`, Trimmung der Hals-Enden), gestempelt
    /// über die Bandbreite (`oxbowHalfWidthCells`). Je Zelle zählt der JÜNGSTE
    /// Altarm; eine jüngere Bank (`barAge` kleiner als das Altarm-Alter) hat
    /// den Bogen überschüttet und gewinnt.
    private static func stampOxbows(_ terrain: Terrain, n: Int, barAge: [Double],
                                    vegShift: inout [Float], reed: inout [Float]) {
        let oxbows = terrain.meander.oxbows, ages = terrain.meander.oxbowAge
        guard !oxbows.isEmpty else { return }
        let cnt = n * n
        var youngest = [Double](repeating: .infinity, count: cnt)
        let radius = WaterRender.oxbowHalfWidthCells + 0.5
        let reach = Int(radius.rounded(.up))
        for (index, loop) in oxbows.enumerated() where loop.count >= WaterRender.oxbowMinimumNodes {
            let age = index < ages.count ? ages[index] : 0
            guard age.isFinite, age >= 0 else { continue }
            let trim = min(WaterRender.oxbowMaximumTrimmedNodes, max(1, loop.count / 8))
            let first = trim, last = loop.count - trim - 1
            guard last - first >= 2 else { continue }
            for nodeIndex in first...last {
                let node = loop[nodeIndex]
                guard node.x.isFinite, node.z.isFinite, abs(node.x) < 1e9, abs(node.z) < 1e9 else { continue }
                let ci = Int(node.x.rounded()), cj = Int(node.z.rounded())
                for j in max(0, cj - reach)...min(n - 1, max(0, cj + reach)) {
                    for i in max(0, ci - reach)...min(n - 1, max(0, ci + reach)) {
                        let dx = Double(i) - node.x, dz = Double(j) - node.z
                        if dx * dx + dz * dz > radius * radius { continue }
                        let k = j * n + i
                        if age < youngest[k] { youngest[k] = age }
                    }
                }
            }
        }
        let maxAge = terrain.cfg.oxbowMaxAge
        let hasBars = barAge.count == cnt
        for k in 0..<cnt where youngest[k].isFinite {
            if hasBars, barAge[k] >= 0, barAge[k] < youngest[k] { continue }
            let stage = WaterRender.oxbowStages(age: youngest[k], maxAge: maxAge)
            reed[k] = max(reed[k], Float(stage.reed))
            vegShift[k] += Float(stage.reed * WaterRender.oxbowReedVeg
                                 + stage.arc * WaterRender.oxbowArcVeg)
        }
    }
}
