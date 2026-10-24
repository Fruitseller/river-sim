import Foundation
import SimCore

/// Material des Mäandergürtels (Issue #174, Paket C Teil 2): Sand- und
/// Kiesbänke, Scroll-Bars und die Verlandung der Altarme, je Zelle.
///
/// Reine Render-Ableitung aus dem Sim-Zustand von Paket B, zustandslos, ändert
/// das Terrain nie (Muster wie `ForestCanopyMask`):
///  1. **Sand** nur auf der JUNGEN Gleithang-Bank direkt am Gerinne: jung
///     nach `Terrain.barAge` (`WaterRender.barSandYearsLo/Hi`) UND nah an der
///     aktuellen Zentrumslinie (`barSandReachLo/Hi`, in Kanalbreiten). Was der
///     Lauf früher überstrichen hat, ist Aue, kein Sand.
///  2. **Pionier-Grün** dahinter: die Sim setzt den Bewuchs beim Stempeln auf
///     0 und lässt ihn über Jahrhunderte nachwachsen; die junge Bank liest
///     deshalb über `barPioneer` grüner, statt als kahler Trockenrasen.
///  3. **Scroll-Bars** als leise Rippen im Bewuchs über den Isolinien des
///     Bankalters (jede Isolinie ist eine frühere Lage des Gleithangs). Die
///     Höhe kann sie auf diesem Gitter nicht tragen; Senken sind grüner,
///     Rücken magerer — nie heller Sand. Wo die Rippen enger als
///     `barScrollMinSpacingLo` Zellen stünden, blenden sie aus (Aliasing).
///  4. **Altarme** färben über ihr Alter (`MeanderState.oxbowAge`): Ried in
///     der feuchten Senke, später ein Vegetationsbogen. Das Wasserband blendet
///     darüber wie bisher über `WaterRender.oxbowVisibleYears` aus.
///
/// Leser: `TerrainColorRenderer` (Materialgewichte, Sand im A-Kanal der
/// Makrofarbe) und `WaterProtectMask` (kein Wald, keine Verschiebung auf
/// frischen Bänken). Den Cache hält `RenderState`. Kalibrierung:
/// `SimCore.WaterRender` § Mäandergürtel im Render; Wächter:
/// `SimCoreTests/BarMaterialTests.swift`.
public enum BarMaterial {

    /// `Sendable` (Issue #201): reiner Wert-Puffer (nur `[Float]`-Felder), die
    /// `empty`-Konstante ist globales `let`. Öffentliche Structs bekommen keine
    /// implizite Konformität, hier ist sie vollständig geprüft.
    public struct Field: Equatable, Sendable {
        /// Sandgewicht 0 … 1 (junge Bank am Gerinne).
        public var sand: [Float]
        /// Verschiebung des Vegetationsgewichts (−1 … +1): Pionier-Grün auf
        /// junger Bank, Rippen-Senken und alte Altarm-Bögen grüner,
        /// Rippen-Rücken magerer.
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
            let near = lineDistance(terrain, barAge: age, reachWidths: WaterRender.barSandReachHi)
            age.withUnsafeBufferPointer { ab in
            near.withUnsafeBufferPointer { nb in
            sand.withUnsafeMutableBufferPointer { sb in
            vegShift.withUnsafeMutableBufferPointer { vb in
                let pa = ab.baseAddress!, pn = nb.baseAddress!
                let ps = sb.baseAddress!, pv = vb.baseAddress!
                parallelChunks(n) { jLo, jHi in
                    for j in jLo..<jHi {
                        for i in 0..<n {
                            let k = j * n + i
                            let a = pa[k]
                            guard a >= 0 else { continue }
                            let ripple = WaterRender.barScroll(
                                age: a, gradientYearsPerCell: ageGradient(pa, i, j, n))
                            let s = WaterRender.barSand(age: a, lineDistanceWidths: Double(pn[k]))
                            ps[k] = Float(s)
                            // Hinter dem Sand: Pionier-Grün auf der jungen Bank,
                            // die Scroll-Rippen als leise Bewuchs-Bänder
                            // (Senke +, Rücken −). Hier noch OHNE den Sand-
                            // Abzug: er folgt nach dem Entsprenkeln (s. unten).
                            pv[k] = Float(WaterRender.barPioneer(age: a)
                                          + WaterRender.barScrollVegGain * ripple)
                        }
                    }
                }
            }}}}
        }

        if hasBars {
            sand = despeckle(sand, n: n)
            // Auf Sand wirkt weder Pionier-Grün noch Rippe — auf dem Sand, der
            // NACH dem Entsprenkeln bleibt. Mit dem rohen Sand gerechnet verlor
            // eine entfernte Sandzelle ihren Sand UND ihr Grün (kahler Punkt).
            for k in 0..<cnt { vegShift[k] *= 1 - sand[k] }
        }
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
        let minNeighbour = Float(WaterRender.barSandNeighbourMin)
        sand.withUnsafeBufferPointer { sb in
        out.withUnsafeMutableBufferPointer { ob in
            let ps = sb.baseAddress!, po = ob.baseAddress!
            parallelChunks(n) { jLo, jHi in
                for j in jLo..<jHi {
                    for i in 0..<n where ps[j * n + i] > 0 {
                        var count = 0
                        for nj in max(0, j - 1)...min(n - 1, j + 1) {
                            for ni in max(0, i - 1)...min(n - 1, i + 1)
                            where (ni != i || nj != j) && ps[nj * n + ni] > minNeighbour { count += 1 }
                        }
                        po[j * n + i] = ps[j * n + i] * Float(smoothstep(lo, hi, Double(count)))
                    }
                }
            }
        }}
        return out
    }

    /// Abstand jeder BANK-Zelle (`barAge` ≥ 0) zur nächsten AKTUELLEN
    /// Zentrumslinie in örtlichen Kanalbreiten (Breite aus dem Abfluss,
    /// `MeanderState.beltWidthCells`, dieselbe Kurve wie Bett und Band).
    /// Gemessen bis `reachWidths`, sonst `.infinity`. Punkt-Strecke-Abstand je
    /// Knotenpaar, Breite gemittelt. Parallel über Zeilenbereiche: jede
    /// Strecke liegt in den Zeilenbändern, die ihr Kasten berührt, und jeder
    /// Bereich schreibt nur seine Zeilen (Minimum, reihenfolgeunabhängig).
    static func lineDistance(_ terrain: Terrain, barAge: [Double], reachWidths: Double) -> [Float] {
        let n = terrain.cfg.n, cnt = n * n
        var dist = [Float](repeating: .infinity, count: cnt)
        guard reachWidths > 0, barAge.count == cnt else { return dist }
        struct Segment { var ax, az, sx, sz, invL2, invB2: Double; var x0, x1, z0, z1: Int }
        var segments: [Segment] = []
        for ch in terrain.meander.channels where ch.nodes.count >= 2 && ch.discharge.count >= ch.nodes.count {
            let nodes = ch.nodes
            var wA = MeanderState.beltWidthCells(discharge: ch.discharge[0], config: terrain.cfg)
            for s in 0..<(nodes.count - 1) {
                let wB = MeanderState.beltWidthCells(discharge: ch.discharge[s + 1], config: terrain.cfg)
                defer { wA = wB }
                let a = nodes[s], e = nodes[s + 1]
                guard a.x.isFinite, a.z.isFinite, e.x.isFinite, e.z.isFinite,
                      abs(a.x) < 1e9, abs(a.z) < 1e9, abs(e.x) < 1e9, abs(e.z) < 1e9 else { continue }
                let b = max(1e-6, 0.5 * (wA + wB))
                let r = reachWidths * b
                let x0 = max(0, Int((min(a.x, e.x) - r).rounded(.down)))
                let x1 = min(n - 1, Int((max(a.x, e.x) + r).rounded(.up)))
                let z0 = max(0, Int((min(a.z, e.z) - r).rounded(.down)))
                let z1 = min(n - 1, Int((max(a.z, e.z) + r).rounded(.up)))
                guard x0 <= x1, z0 <= z1 else { continue }
                let sx = e.x - a.x, sz = e.z - a.z
                segments.append(Segment(ax: a.x, az: a.z, sx: sx, sz: sz,
                                        invL2: 1 / max(1e-12, sx * sx + sz * sz), invB2: 1 / (b * b),
                                        x0: x0, x1: x1, z0: z0, z1: z1))
            }
        }
        guard !segments.isEmpty else { return dist }
        // Zeilenbänder → Strecken, deren Kasten sie berührt.
        let band = 8
        var buckets = [[Int32]](repeating: [], count: (n + band - 1) / band)
        for (si, sg) in segments.enumerated() {
            for bi in (sg.z0 / band)...(sg.z1 / band) { buckets[bi].append(Int32(si)) }
        }
        let reach2 = reachWidths * reachWidths
        barAge.withUnsafeBufferPointer { ab in
        dist.withUnsafeMutableBufferPointer { db in
            let pa = ab.baseAddress!, pd = db.baseAddress!
            parallelChunks(n) { jLo, jHi in
                for bi in (jLo / band)...((jHi - 1) / band) {
                    let r0 = max(jLo, bi * band), r1 = min(jHi, bi * band + band)
                    for si in buckets[bi] {
                        let sg = segments[Int(si)]
                        let zLo = max(r0, sg.z0), zHi = min(r1, sg.z1 + 1)
                        guard zLo < zHi else { continue }
                        for j in zLo..<zHi {
                            let pz = Double(j) - sg.az
                            for i in sg.x0...sg.x1 {
                                let k = j * n + i
                                guard pa[k] >= 0 else { continue }
                                let px = Double(i) - sg.ax
                                let u = max(0, min(1, (px * sg.sx + pz * sg.sz) * sg.invL2))
                                let dx = px - u * sg.sx, dz = pz - u * sg.sz
                                let d2 = (dx * dx + dz * dz) * sg.invB2
                                if d2 <= reach2 {
                                    let d = Float(d2.squareRoot())
                                    if d < pd[k] { pd[k] = d }
                                }
                            }
                        }
                    }
                }
            }
        }}
        return dist
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
        for (index, loop) in oxbows.enumerated() {
            guard let nodeRange = oxbowNodeRange(count: loop.count) else { continue }
            let age = index < ages.count ? ages[index] : 0
            guard age.isFinite, age >= 0 else { continue }
            for nodeIndex in nodeRange {
                let node = loop[nodeIndex]
                guard node.x.isFinite, node.z.isFinite, abs(node.x) < 1e9, abs(node.z) < 1e9 else { continue }
                let ci = Int(node.x.rounded()), cj = Int(node.z.rounded())
                // Ein Knoten weiter als `reach` jenseits des Gitters stempelt
                // nichts (Untergrenze über Obergrenze wäre ein Abbruch,
                // wie bei `WaterFieldRenderer.stampCorridor`).
                let jLo = max(0, cj - reach), jHi = min(n - 1, max(0, cj + reach))
                let iLo = max(0, ci - reach), iHi = min(n - 1, max(0, ci + reach))
                guard jLo <= jHi, iLo <= iHi else { continue }
                for j in jLo...jHi {
                    for i in iLo...iHi {
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
