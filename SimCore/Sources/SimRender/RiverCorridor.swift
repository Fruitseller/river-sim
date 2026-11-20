import Foundation
import SimCore

/// Fluss als KORRIDOR mit eigenem Bett und Ufer (Look E, Issue #239).
///
/// Das Band aus `RiverRibbonRenderer` ist die Wasserfläche. Darunter legt der
/// Korridor je Stützpunkt ein Querprofil aus Geometrie: Uferkante auf
/// Geländehöhe, Böschung, Bett. Die Breite kennt er aus dem Band selbst, nicht
/// aus der Zellmaske — daran sind sechs Versuche im Hill-Climber gescheitert
/// (`docs/look-hillclimb-log.md` Nr. 1–5 und 11: eine Böschung aus der
/// Schutzmaske deckte Läufe von ein bis zwei Zellen Breite zu).
///
/// Das Gelände im Korridor wird ERSETZT, nicht überdeckt, und zwar ohne das
/// Gelände anzufassen: der Korridor-Shader (`game/shaders/corridor.gdshaderinc`)
/// schreibt als Tiefe die seines Strahls auf dem DECKEL (`lid`, je Querschnitt
/// die höchste sichtbare Geländehöhe im Korridor plus `lidClearance`) statt
/// seiner wahren Tiefe. Damit gewinnt das tiefer liegende Bett den Tiefentest
/// gegen das Gelände darüber, Hügel VOR dem Fluss verdecken ihn weiter. Die
/// Reihenfolge der Korridor-Flächen untereinander bleibt erhalten (ein kleiner
/// Anteil der wahren Tiefe, s. dort). Die Naht liegt damit genau auf der
/// Umrisslinie des Meshes; ein Absenken der Gelände-Vertices hätte sie auf das
/// Zellgitter gelegt.
///
/// Wie hoch die sichtbare Geländefläche am Ufer ist, fragt der Korridor an
/// GENAU einer Stelle: `BankSurface`. Strang D (#238) ersetzt die Fläche später
/// durch eine verfeinerte; dann ändert sich nur `BankSurface`.
public struct RiverCorridorMesh: Equatable {
    public var vertices: [SIMD3<Float>] = []
    public var normals: [SIMD3<Float>] = []
    /// rg = Band-Tangente (·0,5 + 0,5), b = Strahler-Rang/6, a = Deckkraft.
    public var colors: [SIMD4<Float>] = []
    /// x = Querlage −1 … +1 (Uferkante links … rechts), y = Bogenlänge (Welt).
    public var uvs: [SIMD2<Float>] = []
    /// x = signierte Bogenstärke (wie `RibbonMesh.uv2s.y`), y = Gleithang-Anteil
    /// 0 … 1 (Kiesbank) dieses Vertex.
    public var uv2s: [SIMD2<Float>] = []
    /// x = Tiefe unter dem Wasserspiegel (Welt-Y, negativ über Wasser),
    /// y = Deckel-Höhe (Welt-Y), z = Querversatz zur Zentrumslinie (Welt,
    /// signiert), w = Halbbreite des Wassers (Welt).
    public var custom: [SIMD4<Float>] = []
    public var indices: [Int32] = []

    public init() {}

    mutating func removeAll() {
        vertices.removeAll(keepingCapacity: true)
        normals.removeAll(keepingCapacity: true)
        colors.removeAll(keepingCapacity: true)
        uvs.removeAll(keepingCapacity: true)
        uv2s.removeAll(keepingCapacity: true)
        custom.removeAll(keepingCapacity: true)
        indices.removeAll(keepingCapacity: true)
    }
}

/// Die EINE Stelle, die weiß, wie hoch die sichtbare Geländefläche liegt
/// (Welt-Y). Heute die Triangulierung des Render-Gitters über der Sim-Höhe
/// (`renderSurfaceHeight`, dieselbe Fläche, auf die das Band seine Kanten
/// legt). Die Relief-Verschiebung fehlt bewusst: die Schutzmaske nimmt sie um
/// jedes Band samt `WaterRender.protectSeamCells` heraus.
struct BankSurface {
    let h: [Double]
    let n: Int
    let renderGrid: Int
    let hscale: Double

    /// Gitter-Koordinaten (Zellen) → Welt-Y.
    @inline(__always)
    func height(_ gx: Double, _ gz: Double) -> Double {
        renderSurfaceHeight(h, gx, gz, n: n, renderGrid: renderGrid) * hscale
    }
}

/// Geschmackswerte und Querprofil des Korridors. Kein Kalibrier-Register
/// (Entscheidung des Eigners zu #235–#239): die Zahlen stehen neben ihrem Code.
enum CorridorProfile {
    /// Spalten des Querprofils, links → rechts: Fuß, Uferkante, Böschung,
    /// Uferlinie, Bett, Thalweg, Bett, Uferlinie, Böschung, Uferkante, Fuß.
    static let columns = 11
    /// Spalte der linken Uferkante und der linken Uferlinie (rechts gespiegelt).
    static let topColumn = 1
    static let shoreColumn = 3
    /// Fuß jenseits der Uferkante (Zellen): liegt immer auf dem Gelände. Steht
    /// die Kante als Uferwall darüber, fällt sie bis zum Fuß ab; sonst ist der
    /// Fuß nur der Saum, über den der Shader ins Gelände blendet.
    static let footCells = 0.45
    static let leveeFootCells = 0.9
    /// Uferlinie (Wasser trifft Böschung) als Anteil der sichtbaren
    /// Wasser-Halbbreite auf gerader Strecke; im Bogen wandert sie am Prallhang
    /// nach außen, am Gleithang nach innen (`shoreBendShift`), dort liegt die
    /// Kiesbank. 0,65 ist die Wasserlinie des Band-Shaders
    /// (`WaterRender.ribbonWaterline` = 0,35 von außen).
    static let shoreFraction = 1 - WaterRender.ribbonWaterline
    static let shoreBendShift = 0.18
    /// Thalweg-Versatz zum Prallhang (Anteil der Wasser-Halbbreite × Bogen).
    static let thalwegShift = 0.4
    /// Böschung jenseits der Band-Halbbreite (Zellen): Grundmaß plus Anteil der
    /// Halbbreite. Die Uferkante liegt dort auf dem Gelände.
    static let bankBaseCells = 0.35
    static let bankWidthShare = 0.18
    /// Am Prallhang schmaler, am Gleithang breiter (Anteil × Bogenstärke).
    static let bankBendShare = 0.6
    /// Bett-Tiefe unter dem Wasserspiegel (Welt-Y) aus der Wasserbreite (Welt):
    /// Breite/Tiefe ~ 4 statt der natürlichen 10–20, weil das Gelände selbst
    /// ~ 6-fach überhöht ist. Gedeckelt, Furten (Riffel) flacher.
    static let depthBase = 0.025
    static let depthPerWidth = 0.26
    static let depthMax = 0.2
    static let riffleShallowing = 0.45
    /// Uferkante mindestens so weit über dem Wasserspiegel (Welt-Y).
    static let freeboard = 0.006
    /// Liegt das Gelände an der Uferkante unter dem Wasser (die
    /// Lagrange-Zentrumslinie liegt oft eine Zelle neben der D8-Rinne), sucht
    /// die Kante bis so weit (Zellen) nach außen nach Gelände über dem Wasser,
    /// in `edgeSearchStep`-Schritten. Erst danach hebt sie sich über das
    /// Gelände (gemessen n = 384: 45 % gehobene Kanten ohne Suche).
    static let edgeSearchCells = 2.5
    static let edgeSearchStep = 0.25
    /// Deckel über der höchsten Geländehöhe im Querschnitt (Welt-Y).
    static let lidClearance = 0.02

    /// Ein Querschnitt: Spalten-Lage (Zellen, signiert, links negativ),
    /// Höhe (Welt-Y), Tiefe unter Wasser (Welt-Y) und Gleithang-Anteil.
    struct Section {
        var offsets = [Double](repeating: 0, count: columns)
        var heights = [Double](repeating: 0, count: columns)
        var depths = [Double](repeating: 0, count: columns)
        var bar = [Double](repeating: 0, count: columns)
        var lid = 0.0
        var waterHalfWidthCells = 0.0
    }

    /// Querschnitt eines Stützpunkts.
    /// - `halfWidthCells`: Band-Halbbreite (Zellen, schon am Krümmungsradius
    ///   gedeckelt), `visible`: sichtbarer Breiten-Anteil (`ribbonVisibleWidth`).
    /// - `waterLeft`/`waterRight`: Höhe der Wasserfläche (des Bands) an den
    ///   Bandkanten; dazwischen ist sie eine Gerade.
    /// - `bend`: signierte Bogenstärke (`RibbonMesh.uv2s.y`), + = Prallhang links.
    /// - `surface(c)`: sichtbare Geländehöhe am Querversatz c (Zellen).
    static func section(halfWidthCells hw: Double, visible: Double,
                        waterLeft: Double, waterRight: Double,
                        bend: Double, riffle: Double, cellSize cs: Double,
                        surface: (Double) -> Double) -> Section {
        var s = Section()
        let vis = max(0, min(1, visible))
        let ww = hw * vis
        s.waterHalfWidthCells = ww
        let beta = max(-1, min(1, bend))
        // Prallhang: für bend > 0 links (c < 0), s. water.gdshader `outward`.
        func gamma(_ side: Double) -> Double { -side * beta }   // + Prallhang, − Gleithang
        func water(_ c: Double) -> Double {
            guard hw > 1e-9 else { return 0.5 * (waterLeft + waterRight) }
            let u = max(-1, min(1, c / hw))
            return 0.5 * (waterLeft + waterRight) + 0.5 * (waterRight - waterLeft) * u
        }
        let depth = vis * min(depthMax, depthBase + depthPerWidth * 2 * ww * cs)
            * (1 - riffleShallowing * max(0, min(1, riffle)))
        let bankBase = vis * (bankBaseCells + bankWidthShare * hw)
        let thalweg = -thalwegShift * beta * ww
        var col = 0
        func put(_ c: Double, _ y: Double, _ bar: Double) {
            s.offsets[col] = c
            s.heights[col] = y
            s.depths[col] = water(c) - y
            s.bar[col] = bar
            col += 1
        }
        // Linke Seite außen → innen, Thalweg, rechte Seite innen → außen.
        var right: [(Double, Double, Double)] = []
        var left: [(Double, Double, Double)] = []
        for side in [-1.0, 1.0] {
            let g = gamma(side)
            let bar = max(0, -g)
            let shore = ww * (shoreFraction + shoreBendShift * g)
            var edge = ww + bankBase * (1 - bankBendShare * g)
            let shoreY = water(side * shore)
            var ground = surface(side * edge)
            if vis > 0, ground < shoreY + freeboard {
                var d = edgeSearchStep
                while d <= edgeSearchCells + 1e-9 {
                    let g2 = surface(side * (edge + d * vis))
                    if g2 >= shoreY + freeboard { edge += d * vis; ground = g2; break }
                    d += edgeSearchStep
                }
            }
            let top = max(ground, shoreY + freeboard)
            let footAt = edge + vis * (top > ground + 1e-9 ? leveeFootCells : footCells)
            let footY = surface(side * footAt)
            // Böschung: am Prallhang steil (der Abfall liegt nah am Wasser,
            // oben eine Schulter), am Gleithang flach (Kiesbank).
            let midAt = shore + (edge - shore) * (0.3 - 0.15 * g)
            let midY = shoreY + (top - shoreY) * (0.55 + 0.35 * g)
            let bedAt = 0.5 * (shore + side * thalweg)
            let bedY = water(side * bedAt) - depth * (0.7 + 0.2 * g)
            let entries = [(side * footAt, footY, 0.0), (side * edge, top, bar), (side * midAt, midY, bar),
                           (side * shore, shoreY, bar), (side * bedAt, bedY, bar * 0.5)]
            if side < 0 { left = entries } else { right = entries.reversed() }
        }
        for e in left { put(e.0, e.1, e.2) }
        put(thalweg, water(thalweg) - depth, 0)
        for e in right { put(e.0, e.1, e.2) }
        // Bett überall unter BEIDEN Uferkanten (Querneigung der Wasserfläche).
        let lowTop = min(s.heights[topColumn], s.heights[columns - 1 - topColumn]) - freeboard
        for k in (shoreColumn + 1)..<(columns - 1 - shoreColumn) where s.heights[k] > lowTop {
            s.heights[k] = lowTop
            s.depths[k] = water(s.offsets[k]) - lowTop
        }
        // Monotone Lage erzwingen (bei winziger Breite fallen Spalten zusammen).
        for k in 1..<columns { s.offsets[k] = max(s.offsets[k], s.offsets[k - 1]) }
        // Deckel: höchste Geländehöhe und höchste Korridor-Höhe im Querschnitt.
        var lid = max(waterLeft, waterRight)
        for k in 0..<columns {
            lid = max(lid, s.heights[k], surface(s.offsets[k]))
        }
        s.lid = lid + lidClearance
        return s
    }
}

/// Baut den Korridor eines Bands aus denselben Größen, die `emitRibbon` für
/// die Wasserfläche nutzt.
struct CorridorBandBuilder {
    struct Sample {
        var x: Double, z: Double          // Gitter
        var tx: Double, tz: Double        // Tangente (Einheit)
        var section: CorridorProfile.Section
        var alpha: Double
        var rank: Double
        var bend: Double
        var arc: Double
    }
    var samples: [Sample] = []

    func emit(into mesh: inout RiverCorridorMesh, cellSize cs: Double, worldHalf half: Double) {
        let m = samples.count
        guard m >= 2 else { return }
        let k = CorridorProfile.columns
        let base = mesh.vertices.count
        var pos = [SIMD3<Double>](repeating: .zero, count: m * k)
        for a in 0..<m {
            let s = samples[a]
            for c in 0..<k {
                let off = s.section.offsets[c]
                let gx = s.x - s.tz * off, gz = s.z + s.tx * off
                pos[a * k + c] = SIMD3(gx * cs - half, s.section.heights[c], gz * cs - half)
            }
        }
        for a in 0..<m {
            let s = samples[a]
            let a0 = max(0, a - 1), a1 = min(m - 1, a + 1)
            let edge = max(abs(s.section.offsets[0]), abs(s.section.offsets[k - 1]), 1e-6)
            for c in 0..<k {
                let c0 = max(0, c - 1), c1 = min(k - 1, c + 1)
                let across = pos[a * k + c1] - pos[a * k + c0]
                let along = pos[a1 * k + c] - pos[a0 * k + c]
                // Kreuzprodukt von Hand (Linux hat kein simd_cross).
                var nrm = SIMD3(across.y * along.z - across.z * along.y,
                                across.z * along.x - across.x * along.z,
                                across.x * along.y - across.y * along.x)
                if nrm.y < 0 { nrm = -nrm }
                let len = (nrm * nrm).sum().squareRoot()
                nrm = len > 1e-12 ? nrm / len : SIMD3(0, 1, 0)
                let p = pos[a * k + c]
                mesh.vertices.append(SIMD3(Float(p.x), Float(p.y), Float(p.z)))
                mesh.normals.append(SIMD3(Float(nrm.x), Float(nrm.y), Float(nrm.z)))
                mesh.colors.append(SIMD4(Float(s.tx * 0.5 + 0.5), Float(s.tz * 0.5 + 0.5),
                                         Float(clamp01(s.rank)), Float(clamp01(s.alpha))))
                mesh.uvs.append(SIMD2(Float(max(-1, min(1, s.section.offsets[c] / edge))), Float(s.arc)))
                mesh.uv2s.append(SIMD2(Float(max(-1, min(1, s.bend))), Float(s.section.bar[c])))
                mesh.custom.append(SIMD4(Float(s.section.depths[c]), Float(s.section.lid),
                                         Float(s.section.offsets[c] * cs),
                                         Float(s.section.waterHalfWidthCells * cs)))
            }
        }
        for a in 1..<m {
            for c in 0..<(k - 1) {
                let v00 = Int32(base + (a - 1) * k + c), v01 = v00 + 1
                let v10 = Int32(base + a * k + c), v11 = v10 + 1
                mesh.indices.append(contentsOf: [v00, v10, v01, v01, v10, v11])
            }
        }
    }
}
