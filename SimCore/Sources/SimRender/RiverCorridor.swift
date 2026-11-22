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
/// schreibt als Tiefe die seines Strahls auf dem DECKEL statt seiner wahren
/// Tiefe. Der Deckel (`lid`) ist je Querschnitt die höchste sichtbare
/// Geländehöhe im Korridor, GEKAPPT auf den sichtbaren Wasserspiegel plus
/// `CorridorProfile.lidMaxAboveWater`, plus `lidClearance`. Die Kappung ist
/// Absicht (Schluchten, s. dort): Gelände über dem Deckel verdeckt den
/// Korridor, statt dass der Korridor vor Grate gezogen wird. Damit gewinnt das tiefer liegende Bett den Tiefentest
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
    /// Kiesbank. Beide Zahlen liest auch das Band (`water.gdshader` endet
    /// genau hier) und der nasse Saum (`corridor.gdshaderinc`), deshalb im
    /// Kalibrier-Register.
    static let shoreFraction = WaterRender.corridorShoreFraction
    static let shoreBendShift = WaterRender.corridorShoreBendShift
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
    /// Der Fuß bleibt innerhalb der Schutzmaske (`WaterProtectMask`: Band-
    /// Deckung bis Halbbreite + 0,5 plus `WaterRender.protectSeamCells` Saum),
    /// mit diesem Abstand (Zellen) davor. Dort ist das Gelände unverschoben
    /// (kein Relief, und Strang D sagt für die verfeinerte Fläche dort exakt
    /// null Abweichung zu, #238). `BankSurface` gilt damit am ganzen Korridor.
    static let maskMarginCells = 0.25
    static func maxReachCells(halfWidthCells hw: Double) -> Double {
        hw + 0.5 + Double(WaterRender.protectSeamCells) - maskMarginCells
    }
    /// Deckel über der höchsten Geländehöhe im Querschnitt (Welt-Y).
    static let lidClearance = 0.02
    /// Höchstens so weit (Welt-Y) liegt der Deckel über dem Wasserspiegel.
    /// In einer Schlucht stieg die Uferkante sonst die Felswand hoch und der
    /// Deckel mit ihr; die Deckel-Tiefe zog Band und Böschung dann vor den
    /// Grat davor (frei hängende Fluss- und Wandstücke, Befund zu #240). Was
    /// über dem Deckel liegt, ist echtes Gelände und verdeckt den Korridor.
    /// Muss über `freeboard` bleiben: die gekappte Uferkante liegt dann noch
    /// über dem Wasser (Wächter `testCanyonKeepsTheLidNearTheWater`).
    static let lidMaxAboveWater = 0.12

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
    /// - `edges`: Lage der Uferkante je Seite (links, rechts; Zellen, ohne
    ///   Vorzeichen). Ohne Angabe sucht der Querschnitt sie selbst; die
    ///   Band-Fassung (`CorridorSections`) gibt die längs geglättete Suche vor.
    /// - `reachLimit`: höchste Reichweite je Seite (Zellen) zusätzlich zur
    ///   Schutzmaske, im Innenbogen der Krümmungsradius.
    static func section(halfWidthCells hw: Double, visible: Double,
                        waterLeft: Double, waterRight: Double,
                        bend: Double, riffle: Double, cellSize cs: Double,
                        edges: (Double, Double)? = nil,
                        reachLimit: (Double, Double) = (.infinity, .infinity),
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
            // Die Innenbogen-Grenze lässt immer Platz für Böschung und Fuß
            // jenseits der Uferlinie: das Wasser selbst ist das Band.
            let limit = max(side < 0 ? reachLimit.0 : reachLimit.1, shore + vis * (footCells + 0.1))
            let reach = min(maxReachCells(halfWidthCells: hw), limit)
            var edge = min(ww + bankBase * (1 - bankBendShare * g), reach - vis * footCells)
            let shoreY = water(side * shore)
            if let edges { edge = min(side < 0 ? edges.0 : edges.1, reach - vis * footCells) }
            edge = max(edge, min(shore, reach - vis * footCells))
            var ground = surface(side * edge)
            if edges == nil, vis > 0, ground < shoreY + freeboard {
                var d = edgeSearchStep
                while d <= edgeSearchCells + 1e-9, edge + d * vis + vis * leveeFootCells <= reach {
                    let g2 = surface(side * (edge + d * vis))
                    if g2 >= shoreY + freeboard { edge += d * vis; ground = g2; break }
                    d += edgeSearchStep
                }
            }
            let top = max(ground, shoreY + freeboard)
            let footAt = min(edge + vis * (top > ground + 1e-9 ? leveeFootCells : footCells), reach)
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
        // Deckel: höchste Geländehöhe und höchste Korridor-Höhe im Querschnitt,
        // auch zwischen den Spalten (die Ufersuche lässt bis 2,5 Zellen
        // Abstand), aber höchstens `lidMaxAboveWater` über dem Wasser. Ufer,
        // die höher hinauf reichen (Schluchtwand), enden unter dem Deckel:
        // darüber zeigt das Gelände selbst die Wand.
        // Gedeckelt über dem SICHTBAREN Spiegel (an den Uferlinien), nicht über
        // den Bandkanten: die liegen bei Querneigung höher und gehören unter
        // die Böschung.
        let waterTop = max(water(s.offsets[shoreColumn]), water(s.offsets[columns - 1 - shoreColumn]))
        var lid = max(waterLeft, waterRight)
        for k in 0..<columns {
            lid = max(lid, s.heights[k], surface(s.offsets[k]))
            if k > 0 { lid = max(lid, surface(0.5 * (s.offsets[k - 1] + s.offsets[k]))) }
        }
        lid = min(lid, waterTop + lidMaxAboveWater)
        s.lid = lid + lidClearance
        for k in 0..<columns where s.heights[k] > lid {
            s.heights[k] = lid
            s.depths[k] = water(s.offsets[k]) - lid
        }
        // Bett überall unter BEIDEN Uferkanten (Querneigung der Wasserfläche).
        let lowTop = min(s.heights[topColumn], s.heights[columns - 1 - topColumn]) - freeboard
        for k in (shoreColumn + 1)..<(columns - 1 - shoreColumn) where s.heights[k] > lowTop {
            s.heights[k] = lowTop
            s.depths[k] = water(s.offsets[k]) - lowTop
        }
        // Jenseits der Uferlinien ist trocken: die Wasser-Ebene läuft quer
        // weiter, aber ein Fuß auf tieferer Aue liegt nicht unter Wasser
        // (Review Neon Nr. 6). Tiefe dort ≤ 0.
        for k in 0..<columns where k < shoreColumn || k > columns - 1 - shoreColumn {
            s.depths[k] = min(s.depths[k], 0)
        }
        // Monotone Lage erzwingen (bei winziger Breite fallen Spalten zusammen).
        for k in 1..<columns { s.offsets[k] = max(s.offsets[k], s.offsets[k - 1]) }
        return s
    }
}

/// Querschnitte EINES Bands, längs zusammen gerechnet (Gremium, Befund 2).
/// Je Stützpunkt allein entstanden Splitter, Falten und Querwände:
///  - die Ufersuche sprang von Stützpunkt zu Stützpunkt um bis zu 2,5 Zellen
///    (spitze helle Dreiecke über Wiese und Wasser): die gefundene Kante wird
///    längs geglättet (Median, dann Kastenmittel);
///  - im Innenbogen reichte die Böschung über den Krümmungsradius hinaus, die
///    Querschnitte überschlugen sich (90°-Kerben, Falten): die Reichweite der
///    Innenseite ist am Radius gedeckelt (`innerReachShare`);
///  - an den Bandenden fiel das Profil abrupt auf null (stumpfe, rechteckige
///    Enden, Dämme am Zusammenfluss): es läuft über `endRampSamples` aus.
enum CorridorSections {
    struct Input {
        var hw: Double, visible: Double
        var waterLeft: Double, waterRight: Double
        var bend: Double, riffle: Double
        var x: Double, z: Double          // Gitter
        var tx: Double, tz: Double        // Tangente (Einheit)
    }
    /// Fenster der Kanten-Glättung in Stützpunkten (~0,5 Zellen Abstand).
    static let edgeMedianRadius = 2
    static let edgeMeanRadius = 2
    /// Innenseite höchstens dieser Anteil des Krümmungsradius.
    static let innerReachShare = 0.85
    /// Tangenten-Abstand (Stützpunkte je Seite) für die Krümmung.
    static let curvatureSpan = 2
    /// Auslauf an beiden Bandenden (Stützpunkte).
    // 8 statt 4 (Gremium 5, Befund B): Ufer und Bett endeten mit einer
    // Erdwand quer zum Lauf, während das Band noch breit war.
    static let endRampSamples = 8.0
    /// Ab diesem Korridor-Anteil trägt das Band den vollen Deckel; darunter
    /// ist der Korridor schmaler als sichtbar (`ribbonVisibleLo`).
    static let lidPresence = WaterRender.ribbonVisibleLo

    /// Sichtbarer Anteil mit Auslauf an den Enden.
    static func endRamp(_ a: Int, count m: Int) -> Double {
        smoothstep(0, endRampSamples, Double(min(a, m - 1 - a)))
    }

    static func build(_ inputs: [Input], cellSize cs: Double, bank: BankSurface) -> [CorridorProfile.Section] {
        let m = inputs.count
        guard m > 0 else { return [] }
        func surface(_ i: Input) -> (Double) -> Double {
            { c in bank.height(i.x - i.tz * c, i.z + i.tx * c) }
        }
        // Krümmungsradius (Zellen) je Stützpunkt und Innenseite.
        var limits = [(Double, Double)](repeating: (.infinity, .infinity), count: m)
        if m >= 3 {
            var radius = [Double](repeating: .infinity, count: m)
            var inner = [Double](repeating: 0, count: m)
            for a in 0..<m {
                let a0 = max(0, a - curvatureSpan), a1 = min(m - 1, a + curvatureSpan)
                guard a1 > a0 else { continue }
                let t0 = inputs[a0], t1 = inputs[a1]
                let cross = t0.tx * t1.tz - t0.tz * t1.tx
                let dot = t0.tx * t1.tx + t0.tz * t1.tz
                var len = 0.0
                for b in a0..<a1 {
                    let dx = inputs[b + 1].x - inputs[b].x, dz = inputs[b + 1].z - inputs[b].z
                    len += (dx * dx + dz * dz).squareRoot()
                }
                let angle = abs(atan2(cross, dot))
                guard angle > 1e-6 else { continue }
                radius[a] = len / angle
                // cross > 0: die Tangente dreht zur positiven Querlage
                // (rechts, `(-tz, tx)`), dort liegt der Mittelpunkt.
                inner[a] = cross > 0 ? 1 : -1
            }
            for a in 0..<m where radius[a] < .infinity {
                var r = radius[a]
                for b in max(0, a - curvatureSpan)...min(m - 1, a + curvatureSpan) { r = min(r, radius[b]) }
                let cap = innerReachShare * r
                limits[a] = inner[a] > 0 ? (.infinity, cap) : (cap, .infinity)
            }
        }
        // Erster Durchgang: Kanten aus der Suche je Stützpunkt.
        var vis = [Double](repeating: 0, count: m)
        var left = [Double](repeating: 0, count: m), right = [Double](repeating: 0, count: m)
        for a in 0..<m {
            let i = inputs[a]
            vis[a] = i.visible * endRamp(a, count: m)
            let s = CorridorProfile.section(halfWidthCells: i.hw, visible: vis[a],
                                            waterLeft: i.waterLeft, waterRight: i.waterRight,
                                            bend: i.bend, riffle: i.riffle, cellSize: cs,
                                            reachLimit: limits[a], surface: surface(i))
            left[a] = abs(s.offsets[CorridorProfile.topColumn])
            right[a] = abs(s.offsets[CorridorProfile.columns - 1 - CorridorProfile.topColumn])
        }
        left = smoothEdges(left); right = smoothEdges(right)
        // Zweiter Durchgang mit den geglätteten Kanten.
        var out: [CorridorProfile.Section] = []
        out.reserveCapacity(m)
        for a in 0..<m {
            let i = inputs[a]
            out.append(CorridorProfile.section(halfWidthCells: i.hw, visible: vis[a],
                                               waterLeft: i.waterLeft, waterRight: i.waterRight,
                                               bend: i.bend, riffle: i.riffle, cellSize: cs,
                                               edges: (left[a], right[a]), reachLimit: limits[a],
                                               surface: surface(i)))
        }
        return out
    }

    /// Median gegen einzelne Sprünge der Suche, danach Kastenmittel.
    static func smoothEdges(_ v: [Double]) -> [Double] {
        let m = v.count
        guard m > 2 else { return v }
        var med = v
        var window: [Double] = []
        for a in 0..<m {
            window.removeAll(keepingCapacity: true)
            for b in max(0, a - edgeMedianRadius)...min(m - 1, a + edgeMedianRadius) { window.append(v[b]) }
            window.sort()
            med[a] = window[window.count / 2]
        }
        var out = med
        for a in 0..<m {
            var sum = 0.0, cnt = 0.0
            for b in max(0, a - edgeMeanRadius)...min(m - 1, a + edgeMeanRadius) { sum += med[b]; cnt += 1 }
            out[a] = sum / cnt
        }
        return out
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

    /// Jeder wievielte Stützpunkt einen Querschnitt bekommt: die Band-
    /// Stützpunkte liegen ~0,5 Zellen auseinander, das Profil braucht nur
    /// ~1 Zelle. Halbiert Mesh und Upload (gemessen bis 29 ms je Band-Bau im
    /// Hauptthread bei jedem Stützpunkt).
    static let sampleStride = 2

    /// Die Stützpunkte, die einen Querschnitt bekommen (jeder
    /// `sampleStride`-te und der letzte).
    static func strideIndices(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        var out = Array(stride(from: 0, to: count, by: sampleStride))
        if (count - 1) % sampleStride != 0 { out.append(count - 1) }
        return out
    }

    /// Deckel je Band-Stützpunkt, wie ihn das Korridor-Mesh dort hat: an den
    /// Querschnitten der eigene, dazwischen linear nach Bogenlänge. Das Band
    /// trägt denselben Deckel: in der Deckel-Tiefe liegen Band und Ufer nur
    /// Millimeter auseinander, ein Band mit dem eigenen Deckel eines
    /// Zwischenpunkts lag je zweitem Quad hinter dem Korridor (Querstreifen
    /// ohne Wasser, Gremium, Befund 2; das Bett unter Wasser schreibt seitdem
    /// zusätzlich keine Tiefe mehr, `corridor_wet.gdshader`).
    static func meshLids(_ lids: [Double], arc: [Double]) -> [Double] {
        let idx = strideIndices(count: lids.count)
        var out = lids
        guard idx.count >= 2 else { return out }
        for s in 1..<idx.count {
            let a0 = idx[s - 1], a1 = idx[s]
            guard a1 - a0 > 1 else { continue }
            let span = max(arc[a1] - arc[a0], 1e-12)
            for a in (a0 + 1)..<a1 {
                let t = (arc[a] - arc[a0]) / span
                out[a] = lids[a0] + (lids[a1] - lids[a0]) * t
            }
        }
        return out
    }

    func emit(into mesh: inout RiverCorridorMesh, cellSize cs: Double, worldHalf half: Double) {
        let all = samples
        guard all.count >= 2 else { return }
        let samples = Self.strideIndices(count: all.count).map { all[$0] }
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
            // Querlage je Seite auf ±1 am eigenen Fuß (Review Neon Nr. 8):
            // der Shader blendet an beiden Kanten ins Gelände.
            let edgeL = max(abs(s.section.offsets[0]), 1e-6), edgeR = max(abs(s.section.offsets[k - 1]), 1e-6)
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
                // B = Anteil eigenes Ufer (1; 0 im Wasser eines anderen Bands,
                // `RiverRibbonRenderer.fadeCorridorsInForeignWater`). Den Rang
                // las der Korridor-Shader nie.
                mesh.colors.append(SIMD4(Float(s.tx * 0.5 + 0.5), Float(s.tz * 0.5 + 0.5),
                                         1, Float(clamp01(s.alpha))))
                let off = s.section.offsets[c]
                mesh.uvs.append(SIMD2(Float(max(-1, min(1, off / (off < 0 ? edgeL : edgeR)))), Float(s.arc)))
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
