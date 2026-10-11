import XCTest
@testable import SimCore

// Kennzahlen des Zielbilds (Issue #174): Großform (Paket A, Abnahmepunkte 1–4)
// und Mäandergürtel (Paket B, Abnahmepunkte 9–15). EINE Definition je Kennzahl,
// gelesen von der Ist-Messung (`testZielbildBaselineDiagnostic`) und von den
// Wächtern, die mit den Paketen dazukommen — sonst misst der Wächter etwas
// anderes als die Tabelle im Issue.
//
// Einheiten: `Terrain.macroSlope` liefert Höhe JE ZELLE, `meanderFlatSlope`
// ist dagegen Höhe JE WELTEINHEIT (Mäander-Gate in `MeanderState.lateralStep`:
// `Δh / (arc · cellSize)`, ebenso `testTerrainFlatnessDiagnostic`). „Tiefland"
// heißt deshalb `macroSlope / cellSize < meanderFlatSlope`: genau die Strecke,
// auf der ein Lauf mobil werden darf.
enum ZielbildMetrics {

    // MARK: - Großform (A)

    struct Landform {
        var landCells = 0
        /// Landzellen mit `macroSlope/cellSize < meanderFlatSlope` (Punkt 1).
        var lowlandCells = 0
        var lowlandFraction: Double { landCells == 0 ? 0 : Double(lowlandCells) / Double(landCells) }
        /// Zusammenhängende Tieflandflächen ab `corridorMinFraction` des Landes.
        var corridors = 0
        /// Anteil des LANDES in den `mainCorridors` größten Tieflandflächen.
        /// Das ist die Lesart von „≥ 20 % Tiefland in ≤ 4 Korridoren": nicht
        /// „höchstens vier Flecken" — bei einer Schwelle von 0,003 Höhe je Zelle
        /// zählt jede Talsohle im Hügelland als eigener Fleck —, sondern „die
        /// vier größten zusammenhängenden Flächen tragen schon 20 % des Landes".
        var mainCorridorLandShare = 0.0
        /// Größte Reichweite eines dieser Hauptkorridore landeinwärts, sofern er
        /// die Küste berührt, als Anteil der größten Küstendistanz der Insel
        /// (1 = reicht bis zum küstenfernsten Punkt, also zum Kamm). Punkt 2.
        var coastCorridorReach = 0.0
        /// Landzellen im äußersten Ring des Gitters (Punkt 3: muss 0 sein).
        var landOnBorder = 0
        /// Kleinster Abstand einer Landzelle zum Gitterrand (Zellen).
        var minBorderDistance = 0
        /// Vergletscherte Zellen (`underIce`, Punkt 4).
        var iceCells = 0
        /// Zerklüftung des Tieflands: mittlerer Betrag des diskreten Laplace
        /// (Höhe je Zelle) über die Tieflandzellen (Punkt 14, Gegenprobe zum
        /// geparkten `floodplainAggradation`, dort gemessen als „2,7×").
        var lowlandRuggedness = 0.0
        /// Tiefland-Maske für die Mäander-Kennzahlen.
        var lowland: [Bool] = []
    }

    /// Mindestgröße eines Tieflandkorridors (Anteil der Landzellen): Flecken
    /// darunter sind Talsohlen-Stücke, keine Korridore.
    static let corridorMinFraction = 0.0025
    /// Zahl der Hauptkorridore (Issue #174: „in ≤ 4 zusammenhängenden Korridoren").
    static let mainCorridors = 4

    static func landform(_ t: Terrain) -> Landform {
        let n = t.cfg.n, cs = t.cfg.cellSize, sea = t.cfg.sea
        let flat = t.cfg.meanderFlatSlope
        var r = Landform()
        var land = [Bool](repeating: false, count: n * n)
        var lowland = [Bool](repeating: false, count: n * n)
        var minBorder = Int.max
        for j in 0..<n {
            for i in 0..<n {
                let k = j * n + i
                guard t.hf[k] > sea else { continue }
                land[k] = true
                r.landCells += 1
                let bd = min(min(i, j), min(n - 1 - i, n - 1 - j))
                minBorder = min(minBorder, bd)
                if bd == 0 { r.landOnBorder += 1 }
                if i >= 2, j >= 2, i <= n - 3, j <= n - 3,
                   Terrain.macroSlope(t.h, k, n) / cs < flat {
                    lowland[k] = true
                    r.lowlandCells += 1
                }
            }
        }
        r.minBorderDistance = minBorder == Int.max ? n : minBorder
        r.iceCells = t.underIce.reduce(0) { $0 + ($1 ? 1 : 0) }

        // Zerklüftung über das Tiefland.
        var rug = 0.0, rugN = 0
        for k in 0..<(n * n) where lowland[k] {
            let lap = t.h[k - 1] + t.h[k + 1] + t.h[k - n] + t.h[k + n] - 4 * t.h[k]
            rug += abs(lap); rugN += 1
        }
        r.lowlandRuggedness = rugN == 0 ? 0 : rug / Double(rugN)

        // Küstendistanz (4er-BFS über Land, Start: Land neben Meer).
        var dist = [Int32](repeating: -1, count: n * n)
        var queue: [Int] = []
        queue.reserveCapacity(n * n)
        for k in 0..<(n * n) where land[k] {
            let i = k % n, j = k / n
            let coast = (i > 0 && !land[k - 1]) || (i < n - 1 && !land[k + 1])
                || (j > 0 && !land[k - n]) || (j < n - 1 && !land[k + n])
            if coast { dist[k] = 0; queue.append(k) }
        }
        var head = 0, maxDist: Int32 = 0
        while head < queue.count {
            let k = queue[head]; head += 1
            let i = k % n, j = k / n
            for (ok, nb) in [(i > 0, k - 1), (i < n - 1, k + 1), (j > 0, k - n), (j < n - 1, k + n)]
            where ok && land[nb] && dist[nb] < 0 {
                dist[nb] = dist[k] + 1
                maxDist = max(maxDist, dist[nb])
                queue.append(nb)
            }
        }

        // Korridore = Zusammenhangskomponenten des Tieflands (4er).
        let minSize = max(1, Int(corridorMinFraction * Double(r.landCells)))
        var seen = [Bool](repeating: false, count: n * n)
        var stack: [Int] = []
        var comps: [(size: Int, coastReach: Double)] = []
        for start in 0..<(n * n) where lowland[start] && !seen[start] {
            stack.removeAll(keepingCapacity: true)
            stack.append(start); seen[start] = true
            var size = 0, touchesCoast = false, reach: Int32 = 0
            while let k = stack.popLast() {
                size += 1
                if dist[k] == 0 { touchesCoast = true }
                reach = max(reach, dist[k])
                let i = k % n, j = k / n
                for (ok, nb) in [(i > 0, k - 1), (i < n - 1, k + 1), (j > 0, k - n), (j < n - 1, k + n)]
                where ok && lowland[nb] && !seen[nb] {
                    seen[nb] = true; stack.append(nb)
                }
            }
            if size >= minSize { r.corridors += 1 }
            comps.append((size, touchesCoast && maxDist > 0 ? Double(reach) / Double(maxDist) : 0))
        }
        comps.sort { $0.size > $1.size }
        let main = comps.prefix(mainCorridors)
        r.mainCorridorLandShare = r.landCells == 0 ? 0
            : Double(main.reduce(0) { $0 + $1.size }) / Double(r.landCells)
        r.coastCorridorReach = main.map(\.coastReach).max() ?? 0
        r.lowland = lowland
        return r
    }

    // MARK: - Mäandergürtel (B)

    struct Belt {
        /// Knoten im längsten Tieflandabschnitt des Hauptlaufs (0 = keiner).
        var reachNodes = 0
        /// Abfluss (Zellen Einzugsgebiet) am Ende des Hauptlaufs.
        var mainDischarge = 0.0
        /// Sinuosität des Tieflandabschnitts (Punkt 9).
        var sinuosity = 1.0
        /// Kanalbreite (Zellen); bis Paket B gibt es sie nur im Render
        /// (`WaterRender.ribbonHalfWidthCells`), danach aus der Sim.
        var width = 0.0
        /// Mittlere Mäanderwellenlänge (Luftlinie über zwei Halbwellen), Zellen.
        var wavelength = 0.0
        var wavelengthPerWidth: Double { width > 0 ? wavelength / width : 0 }
        /// Mittlere Auslenkung je Halbwelle (Abstand zur Sehne), Zellen.
        var amplitude = 0.0
        /// Median der Gürtelbreite (überstrichene Zellen quer zum Tal), Zellen.
        var beltWidth = 0.0
        /// Unter 0,5 Zellen Amplitude ist der Lauf praktisch gerade — kein Verhältnis.
        var beltPerAmplitude: Double { amplitude > 0.5 ? beltWidth / amplitude : 0 }
        /// Mittlere Tiefe Außen- / Innenufer in Bögen über dem Krümmungs-Median.
        var asymmetry = 0.0
        /// Altarme mit Schwerpunkt im Tiefland, davon als offenes Wasser
        /// (Alter < `WaterRender.oxbowVisibleYears`).
        var lowlandOxbows = 0
        var openLowlandOxbows = 0
    }

    /// Fenster (Knoten je Seite) für die Längsneigung des Tieflandabschnitts.
    static let slopeWindow = 3

    /// Hauptlauf. Mit Gürtel (Paket B, Abfluss entlang des Laufs monoton): der
    /// Lauf mit dem größten Abfluss unter denen mit mindestens 30 Knoten —
    /// `traceChannels` bricht den Stamm an jedem Zusammenfluss, darunter
    /// liegen Stummel vor der Mündung. Ohne Gürtel war der Abfluss am Ende
    /// unzuverlässig (bilinear auf der einzelligen D8-Rinne); dort gilt die
    /// größte Abfluss-Summe über die Knoten. Die Summe bevorzugt aber lange,
    /// gewundene Läufe (mehr Knoten) und wählte auf Seed 42 mit Gürtel einen
    /// Lauf mit Sinuosität 11.
    static func mainChannel(_ t: Terrain) -> RiverChannel? {
        if t.cfg.meanderBelt {
            return t.meander.channels.filter { $0.nodes.count >= 30 }
                .max { ($0.discharge.max() ?? 0) < ($1.discharge.max() ?? 0) }
        }
        return t.meander.channels.max { $0.discharge.reduce(0, +) < $1.discharge.reduce(0, +) }
    }

    /// Längster zusammenhängender Knotenbereich, dessen Längsneigung (±`slopeWindow`
    /// Knoten) unter `meanderFlatSlope` liegt.
    /// Mit Gürtel: der längste Bereich, den die Sim selbst als mobil führt
    /// (`BeltGeometry.mob > 0` und Abfluss ab `meanderBeltMinCells`) — dieselbe
    /// Definition wie die Migration, kein zweites Gate.
    static func lowlandReach(_ t: Terrain, _ ch: RiverChannel) -> Range<Int>? {
        let nodes = ch.nodes, cs = t.cfg.cellSize, flat = t.cfg.meanderFlatSlope
        guard nodes.count > 2 * slopeWindow + 2 else { return nil }
        func hAt(_ p: MeanderNode) -> Double {
            t.h.withUnsafeBufferPointer { Terrain.bilinear($0.baseAddress!, t.cfg.n, p.x, p.z) }
        }
        if t.cfg.meanderBelt {
            let g = MeanderState.beltGeometry(ch, config: t.cfg, heightAt: hAt)
            var best: Range<Int>? = nil, start: Int? = nil
            for i in 0...nodes.count {
                let on = i < nodes.count && g.mob[i] > 0 && ch.discharge[i] >= t.cfg.meanderBeltMinCells
                if on { if start == nil { start = i } }
                else if let s0 = start { if best == nil || i - s0 > best!.count { best = s0..<i }; start = nil }
            }
            return best
        }
        var cum = [Double](repeating: 0, count: nodes.count)
        for i in 1..<nodes.count { cum[i] = cum[i - 1] + dist(nodes[i - 1], nodes[i]) }
        var best: Range<Int>? = nil, runStart: Int? = nil
        for i in 0...nodes.count {
            var isFlat = false
            if i < nodes.count {
                let a = max(0, i - slopeWindow), b = min(nodes.count - 1, i + slopeWindow)
                let arc = (cum[b] - cum[a]) * cs
                isFlat = arc > 0 && abs(hAt(nodes[a]) - hAt(nodes[b])) / arc < flat
            }
            if isFlat { if runStart == nil { runStart = i } }
            else if let s = runStart {
                if best == nil || i - s > best!.count { best = s..<i }
                runStart = nil
            }
        }
        return best
    }

    /// Signierte Krümmung je Knoten (dieselbe Formel wie `lateralStep`), über
    /// ±`window` Knoten geglättet, damit Knicke unter der Kanalbreite (D8-Treppe,
    /// Resample) keine Schein-Wendepunkte setzen. Echte Bögen (Halbwelle ≈ 5
    /// Breiten) überstehen ein Fenster von ±1 Breite.
    static func smoothedCurvature(_ nodes: [MeanderNode], window: Int = 2) -> [Double] {
        let c = nodes.count
        var curv = [Double](repeating: 0, count: c)
        guard c >= 3 else { return curv }
        for i in 1..<(c - 1) {
            let a = nodes[i - 1], b = nodes[i], d = nodes[i + 1]
            let v1x = b.x - a.x, v1z = b.z - a.z, v2x = d.x - b.x, v2z = d.z - b.z
            let ds = 0.5 * ((v1x * v1x + v1z * v1z).squareRoot() + (v2x * v2x + v2z * v2z).squareRoot())
            if ds < 1e-9 { continue }
            curv[i] = atan2(v1x * v2z - v1z * v2x, v1x * v2x + v1z * v2z) / ds
        }
        var out = curv
        for i in 0..<c {
            let a = max(0, i - window), b = min(c - 1, i + window)
            out[i] = curv[a...b].reduce(0, +) / Double(b - a + 1)
        }
        return out
    }

    /// `swept`: Zellen, die ein Lauf im Messlauf je überstrichen hat (s.
    /// `markSwept`) — die Gürtel-Ausdehnung bis Paket B (danach `barAge ≥ 0`).
    static func belt(_ t: Terrain, lowland: [Bool], swept: [Bool],
                     channel: RiverChannel? = nil) -> Belt {
        var r = Belt()
        let n = t.cfg.n
        for (oi, ox) in t.meander.oxbows.enumerated() where !ox.isEmpty {
            let cx = ox.reduce(0) { $0 + $1.x } / Double(ox.count)
            let cz = ox.reduce(0) { $0 + $1.z } / Double(ox.count)
            let k = min(max(Int(cz.rounded()), 0), n - 1) * n + min(max(Int(cx.rounded()), 0), n - 1)
            guard lowland[k] else { continue }
            r.lowlandOxbows += 1
            if t.meander.oxbowAge[oi] < WaterRender.oxbowVisibleYears { r.openLowlandOxbows += 1 }
        }
        guard let ch = channel ?? mainChannel(t), let reach = lowlandReach(t, ch), reach.count >= 8 else { return r }
        let nodes = Array(ch.nodes[reach])
        r.reachNodes = nodes.count
        r.mainDischarge = ch.discharge.last ?? 0
        var len = 0.0
        for i in 1..<nodes.count { len += dist(nodes[i - 1], nodes[i]) }
        let chord = dist(nodes[0], nodes[nodes.count - 1])
        r.sinuosity = chord > 1e-9 ? len / chord : 1
        let q = ch.discharge[reach].reduce(0, +) / Double(nodes.count)
        r.width = MeanderState.beltWidthCells(discharge: q, config: t.cfg)

        // Wendepunkte, Wellenlänge, Amplitude.
        let win = max(2, Int((r.width / max(1e-6, t.cfg.meanderNodeSpacing)).rounded()))
        let curv = smoothedCurvature(nodes, window: win)
        var infl: [Int] = []
        for i in 1..<nodes.count where (curv[i - 1] < 0) != (curv[i] < 0) { infl.append(i) }
        if infl.count >= 3 {
            var lam = 0.0
            for k in 0..<(infl.count - 2) { lam += dist(nodes[infl[k]], nodes[infl[k + 2]]) }
            r.wavelength = lam / Double(infl.count - 2)
        }
        if infl.count >= 2 {
            var amp = 0.0
            for k in 0..<(infl.count - 1) {
                let a = nodes[infl[k]], b = nodes[infl[k + 1]]
                let dx = b.x - a.x, dz = b.z - a.z, l = (dx * dx + dz * dz).squareRoot()
                var m = 0.0
                for i in infl[k]...infl[k + 1] {
                    let p = nodes[i]
                    let off = l > 1e-9 ? abs((p.x - a.x) * dz - (p.z - a.z) * dx) / l : dist(p, a)
                    m = max(m, off)
                }
                amp += m
            }
            r.amplitude = amp / Double(infl.count - 1)
        }

        // Gürtelbreite: quer zur Talachse (Mittel über ±W Knoten) die
        // zusammenhängend überstrichenen Zellen zählen (1 Zelle Lücke erlaubt).
        let w = 12
        var widths: [Double] = []
        for i in stride(from: 0, to: nodes.count, by: 2) {
            let a = max(0, i - w), b = min(nodes.count - 1, i + w)
            let ax = nodes[a...b].reduce(0) { $0 + $1.x } / Double(b - a + 1)
            let az = nodes[a...b].reduce(0) { $0 + $1.z } / Double(b - a + 1)
            let tx = nodes[b].x - nodes[a].x, tz = nodes[b].z - nodes[a].z
            let tl = (tx * tx + tz * tz).squareRoot()
            guard tl > 1e-9 else { continue }
            let px = -tz / tl, pz = tx / tl
            var extent = 0.0
            for sgn in [-1.0, 1.0] {
                var s = 0.0, last = 0.0, gap = 0.0
                while s < Double(n) {
                    s += 0.5
                    let x = Int((ax + sgn * px * s).rounded()), z = Int((az + sgn * pz * s).rounded())
                    guard x >= 0, z >= 0, x < n, z < n else { break }
                    if swept[z * n + x] { last = s; gap = 0 } else { gap += 0.5; if gap > 1.5 { break } }
                }
                extent += last
            }
            widths.append(extent)
        }
        widths.sort()
        if !widths.isEmpty { r.beltWidth = widths[widths.count / 2] }

        // Querprofil-Asymmetrie: Tiefe unter der höheren Uferkante, außen gegen
        // innen, in Bögen mit |Krümmung| über dem Median.
        let absC = curv.map(abs).sorted()
        let median = absC[absC.count / 2]
        let half = r.width / 2
        let off = max(1.0, 0.5 * half)
        var dOut = 0.0, dIn = 0.0, bends = 0
        t.h.withUnsafeBufferPointer { hb in
            let p = hb.baseAddress!
            for i in 1..<(nodes.count - 1) where abs(curv[i]) > median {
                let a = nodes[i - 1], c = nodes[i + 1], b = nodes[i]
                let tx = c.x - a.x, tz = c.z - a.z, tl = (tx * tx + tz * tz).squareRoot()
                guard tl > 1e-9 else { continue }
                let sgn = curv[i] > 0 ? -1.0 : 1.0     // Außen-Normale wie `meanderStamp`
                let ox = sgn * (-tz / tl), oz = sgn * (tx / tl)
                func hAt(_ d: Double) -> Double {
                    Terrain.bilinear(p, n, b.x + ox * d, b.z + oz * d)
                }
                // Bezug: höchster Punkt im benetzten Querschnitt (≈ Uferkante
                // bankfull). Die Rinnen-Wand dahinter (`channelCarve`, ≈ 35 m)
                // stauchte das Verhältnis: (35 + 6,5) / (35 + 1) ≈ 1,15.
                var ref = -Double.infinity, d = -half
                while d <= half + 1e-9 { ref = max(ref, hAt(d)); d += 0.5 }
                dOut += max(0, ref - hAt(off)); dIn += max(0, ref - hAt(-off)); bends += 1
            }
        }
        if bends > 0, dIn > 1e-12 { r.asymmetry = dOut / dIn }
        return r
    }

    /// Mittel über ALLE Mäanderläufe (mobiler Abschnitt ab `minNodes` Knoten),
    /// gewichtet mit dem Abfluss. Der Hauptlauf allein ist dünn: auf Seed 1337
    /// ist es der Abfluss des großen Sees durchs Gebirge, mit ~30 mobilen
    /// Knoten. Altarme zählen wie in `belt` (einmal über die Welt). `count` =
    /// Zahl der gemittelten Läufe in `reachNodes`.
    static func beltAll(_ t: Terrain, lowland: [Bool], swept: [Bool], minNodes: Int = 40) -> Belt {
        var r = belt(t, lowland: lowland, swept: swept, channel: RiverChannel(nodes: [], discharge: []))
        var w = 0.0, wl = 0.0, wa = 0.0, count = 0
        var sinu = 0.0, width = 0.0, lam = 0.0, amp = 0.0, beltW = 0.0, asym = 0.0
        for ch in t.meander.channels {
            guard let reach = lowlandReach(t, ch), reach.count >= minNodes else { continue }
            let b = belt(t, lowland: lowland, swept: swept, channel: ch)
            let q = ch.discharge[reach].reduce(0, +) / Double(reach.count)
            count += 1; w += q
            sinu += q * b.sinuosity; width += q * b.width; amp += q * b.amplitude; beltW += q * b.beltWidth
            if b.wavelength > 0 { lam += q * b.wavelength; wl += q }
            if b.asymmetry > 0 { asym += q * b.asymmetry; wa += q }
        }
        guard w > 0 else { return r }
        r.reachNodes = count
        r.sinuosity = sinu / w; r.width = width / w; r.amplitude = amp / w; r.beltWidth = beltW / w
        r.wavelength = wl > 0 ? lam / wl : 0
        r.asymmetry = wa > 0 ? asym / wa : 0
        return r
    }

    /// Markiert die Zellen unter allen Laufknoten als überstrichen, dazu (ab
    /// Paket B) jede Zelle mit Gleithang-Bank (`barAge ≥ 0`).
    static func markSwept(_ t: Terrain, _ swept: inout [Bool]) {
        let n = t.cfg.n
        for k in 0..<(n * n) where t.barAge[k] >= 0 { swept[k] = true }
        for ch in t.meander.channels {
            for p in ch.nodes {
                let x = min(max(Int(p.x.rounded()), 0), n - 1), z = min(max(Int(p.z.rounded()), 0), n - 1)
                swept[z * n + x] = true
            }
        }
    }
}

/// Wächter der Großform (Issue #174, Paket A, Abnahmepunkte 1–4) und der
/// lauf-unabhängigen Gürtel-Punkte (Paket B, 14–16) auf den drei Matrix-Seeds,
/// Produktions-Config mit Einlauf. Schranken aus dem Issue;
/// gemessene Werte in `docs/zielbild-measurements.md`.
final class ZielbildLandformTests: XCTestCase {
    private func world(_ seed: UInt32, years: Double) -> Terrain {
        let t = Terrain(config: .production, seed: seed, settleYears: SimConfig.productionSettleYears)
        while t.years < years - 1e-6 { t.step(dtYears: min(1000, years - t.years)) }
        return t
    }

    /// Punkte 1–4 in Jahr 2.000 und 20.000. Ein Lauf je Seed, weil der
    /// 20.000-Jahre-Lauf den teuren Teil trägt.
    func testRangeLandformMeetsTheAcceptanceSheet() {
        for seed in ZielbildBaseline.seeds {
            let t = world(seed, years: 2_000)
            var lf = ZielbildMetrics.landform(t)
            // Punkt 1: Tiefland ≥ 20 % des Landes, getragen von ≤ 4 Korridoren.
            XCTAssertGreaterThanOrEqual(lf.mainCorridorLandShare, 0.20,
                "Seed \(seed): vier größte Tieflandflächen tragen nur \(lf.mainCorridorLandShare) des Landes")
            // Punkt 2: einer davon reicht von der Küste bis zum Kamm.
            XCTAssertGreaterThanOrEqual(lf.coastCorridorReach, 0.8,
                "Seed \(seed): kein Korridor reicht von der Küste ins Inselinnere (\(lf.coastCorridorReach))")
            // Punkt 3: kein Land am Gitterrand (mit Luft: 3 % des Gitters).
            XCTAssertGreaterThanOrEqual(Double(lf.minBorderDistance), 0.03 * Double(t.cfg.n),
                "Seed \(seed): Land \(lf.minBorderDistance) Zellen vom Rand")
            while t.years < 20_000 - 1e-6 { t.step(dtYears: 1000) }
            lf = ZielbildMetrics.landform(t)
            // Punkt 4: Gletscher ab Jahr 20.000.
            XCTAssertGreaterThan(lf.iceCells, 0, "Seed \(seed): kein Eis in Jahr 20.000")
            XCTAssertEqual(lf.landOnBorder, 0, "Seed \(seed): Land am Rand in Jahr 20.000")
            // Paket B (Mäandergürtel) im selben Lauf — kein zweiter 20.000-Jahre-Lauf.
            // Punkt 15 (beide Cutoff-Arten), Punkt 16 (Bänke im Zustand),
            // Punkt 14 (Aue nicht zerklüfteter als nach Paket A: 0,00136 /
            // 0,00156 / 0,00141 in Jahr 20.000, gemessen vor dem Gürtel).
            XCTAssertGreaterThan(t.meander.neckCutoffs, 0, "Seed \(seed): kein Hals-Cutoff bis Jahr 20.000")
            XCTAssertGreaterThan(t.meander.chuteCutoffs, 0, "Seed \(seed): kein Chute-Cutoff bis Jahr 20.000")
            let bars = t.barAge.filter { $0 >= 0 }.count
            XCTAssertGreaterThan(bars, 1000, "Seed \(seed): kaum Gleithang-Bänke (\(bars) Zellen)")
            XCTAssertLessThan(lf.lowlandRuggedness, 0.00156,
                              "Seed \(seed): Aue zerklüfteter als vor dem Gürtel (\(lf.lowlandRuggedness))")
        }
    }

    /// Der Rand bleibt auch bei kleinen Gittern frei — der Abstand skaliert mit `n`.
    func testBorderMarginScalesWithGrid() {
        for n in [96, 192] {
            var c = SimConfig(); c.n = n; c.world = calibrationWorld
            for seed in ZielbildBaseline.seeds {
                let lf = ZielbildMetrics.landform(Terrain(config: c, seed: seed))
                XCTAssertEqual(lf.landOnBorder, 0, "n \(n), Seed \(seed): Land am Rand")
                XCTAssertGreaterThan(lf.landCells, n * n / 8, "n \(n), Seed \(seed): Insel verschwindet")
            }
        }
    }
}

/// Ist-Messung für Issue #174 („Erst messen, dann schrauben"): Kennzahlen 1–4
/// und 9–15 auf den drei Matrix-Seeds, Produktions-Config mit Einlauf.
///
///     RS_MEASURE=1 swift test -c release --package-path SimCore \
///         -Xswiftc -swift-version -Xswiftc 5 --filter testZielbildBaselineDiagnostic
///
/// `RS_SEED` beschränkt auf einen Seed, `RS_YEARS` kürzt den Lauf.
final class ZielbildBaseline: XCTestCase {
    static let seeds: [UInt32] = [1337, 42, 20]
    static let years: [Double] = [2_000, 20_000, 100_000]

    func testZielbildBaselineDiagnostic() throws {
        try skipUnlessMeasuring()
        let env = ProcessInfo.processInfo.environment
        let onlySeed = env["RS_SEED"].flatMap { UInt32($0) }
        let maxYear = env["RS_YEARS"].flatMap { Double($0) } ?? 100_000

        print("\n=== ZIELBILD #174: GROSSFORM (A) ===")
        print("| Seed | Jahr | Tiefland | Flecken ≥ 0,25 % | Land in 4 größten | Küsten-Reichweite | Land am Rand | min. Randabstand | Eiszellen | Zerklüftung Tiefland |")
        print("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        var beltRows: [String] = [], allRows: [String] = []
        for seed in Self.seeds where onlySeed == nil || onlySeed == seed {
            let t = Terrain(config: .production, seed: seed, settleYears: SimConfig.productionSettleYears)
            var swept = [Bool](repeating: false, count: t.cfg.count)
            ZielbildMetrics.markSwept(t, &swept)
            var year = 0.0, neckCutoffs = 0
            for target in Self.years where target <= maxYear + 1e-6 {
                while year < target - 1e-6 {
                    let dt = min(1000, target - year)
                    t.step(dtYears: dt)
                    year += dt
                    if !t.cfg.meanderBelt { neckCutoffs += t.meander.oxbowAge.filter { $0 == 0 }.count }
                    ZielbildMetrics.markSwept(t, &swept)
                }
                let lf = ZielbildMetrics.landform(t)
                print(String(format: "| %d | %.0f | %.1f %% | %d | %.0f %% | %.2f | %d | %d | %d | %.5f |",
                             seed, year, 100 * lf.lowlandFraction, lf.corridors, 100 * lf.mainCorridorLandShare,
                             lf.coastCorridorReach, lf.landOnBorder, lf.minBorderDistance,
                             lf.iceCells, lf.lowlandRuggedness))
                let b = ZielbildMetrics.belt(t, lowland: lf.lowland, swept: swept)
                let all = ZielbildMetrics.beltAll(t, lowland: lf.lowland, swept: swept)
                allRows.append(String(
                    format: "| %d | %.0f | %d | %.2f | %.2f | %.1f | %.1f | %.1f | %.1f | %.1f | %.2f |",
                    seed, year, all.reachNodes, all.sinuosity, all.width, all.wavelength, all.wavelengthPerWidth,
                    all.amplitude, all.beltWidth, all.beltPerAmplitude, all.asymmetry))
                beltRows.append(String(
                    format: "| %d | %.0f | %d | %.0f | %.2f | %.2f | %.1f | %.1f | %.1f | %.1f | %.1f | %.2f | %d / %d | %d / %d |",
                    seed, year, b.reachNodes, b.mainDischarge, b.sinuosity, b.width, b.wavelength,
                    b.wavelengthPerWidth, b.amplitude, b.beltWidth, b.beltPerAmplitude, b.asymmetry,
                    b.openLowlandOxbows, b.lowlandOxbows,
                    t.cfg.meanderBelt ? t.meander.neckCutoffs : neckCutoffs, t.meander.chuteCutoffs))
            }
        }
        print("\n=== ZIELBILD #174: MÄANDERGÜRTEL (B), Hauptlauf ===")
        print("| Seed | Jahr | Tiefland-Knoten | Abfluss | Sinuosität | Breite | Wellenlänge | λ/Breite | Amplitude | Gürtel | Gürtel/Amplitude | Asymmetrie | Altarme offen / Tiefland | Cutoffs Hals / Chute |")
        print("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        beltRows.forEach { print($0) }
        print("\n=== ZIELBILD #174: MÄANDERGÜRTEL (B), alle Mäanderläufe (≥ 40 mobile Knoten, Abfluss-gewichtet) ===")
        print("| Seed | Jahr | Läufe | Sinuosität | Breite | Wellenlänge | λ/Breite | Amplitude | Gürtel | Gürtel/Amplitude | Asymmetrie |")
        print("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        allRows.forEach { print($0) }
        print("=== ENDE ZIELBILD ===\n")
    }

    /// Karte je Seed als PPM nach `RS_OUT` (Standard `/tmp`): Meer blau, Tiefland
    /// grün, sonst Grau nach Höhe, Eis weiß, Mäanderläufe rot. Für den Blick
    /// auf die Großform beim Kalibrieren von Paket A; `RS_YEARS` wählt das Jahr.
    func testZielbildMapDiagnostic() throws {
        try skipUnlessMeasuring()
        let env = ProcessInfo.processInfo.environment
        let out = env["RS_OUT"] ?? "/tmp"
        let year = env["RS_YEARS"].flatMap { Double($0) } ?? 0
        for seed in Self.seeds where env["RS_SEED"].flatMap({ UInt32($0) }).map({ $0 == seed }) ?? true {
            let t = Terrain(config: .production, seed: seed, settleYears: SimConfig.productionSettleYears)
            while t.years < year - 1e-6 { t.step(dtYears: min(1000, year - t.years)) }
            let lf = ZielbildMetrics.landform(t)
            let n = t.cfg.n
            var px = [UInt8](repeating: 0, count: n * n * 3)
            let maxH = t.h.max() ?? 1
            for k in 0..<(n * n) {
                var c: (Double, Double, Double)
                if t.hf[k] <= t.cfg.sea { c = (30, 60, 120) }
                else if t.underIce.count == n * n && t.underIce[k] { c = (240, 245, 255) }
                else if t.hf[k] - t.h[k] > 0.01 { c = (60, 110, 200) }
                else {
                    let v = 60 + 190 * (t.h[k] - t.cfg.sea) / max(1e-9, maxH - t.cfg.sea)
                    c = lf.lowland[k] ? (v * 0.55, v * 0.9, v * 0.45) : (v, v, v)
                    // Gleithang-Bänke: frisch gelb, mit dem Alter über Hellgrün
                    // zurück in die Grundfarbe (Scroll-Bars als Bänder sichtbar).
                    let age = t.barAge[k]
                    if age >= 0 {
                        let f = max(0, min(1, age / 8000))
                        let band = 0.85 + 0.15 * cos(age / 400)
                        c = ((235 * (1 - f) + c.0 * f) * band, (215 * (1 - f) + c.1 * f) * band, (120 * (1 - f) + c.2 * f) * band)
                    }
                }
                px[3 * k] = UInt8(min(255, max(0, c.0)))
                px[3 * k + 1] = UInt8(min(255, max(0, c.1)))
                px[3 * k + 2] = UInt8(min(255, max(0, c.2)))
            }
            for ch in t.meander.channels where env["RS_NO_LINES"] != "1" {
                for p in ch.nodes {
                    let k = min(n - 1, max(0, Int(p.z.rounded()))) * n + min(n - 1, max(0, Int(p.x.rounded())))
                    px[3 * k] = 220; px[3 * k + 1] = 30; px[3 * k + 2] = 30
                }
            }
            if env["RS_NO_LINES"] == "1" { for k in 0..<(n * n) where t.hf[k] > t.cfg.sea && t.isChannel[k] {
                px[3 * k] = 40; px[3 * k + 1] = 90; px[3 * k + 2] = 210 } }
            var data = Data("P6\n\(n) \(n)\n255\n".utf8)
            data.append(contentsOf: px)
            let path = "\(out)/zielbild-\(seed)-\(Int(year)).ppm"
            try data.write(to: URL(fileURLWithPath: path))
            print("MAP \(path) Tiefland \(String(format: "%.1f", 100 * lf.lowlandFraction)) % Korridore \(lf.corridors) Reichweite \(String(format: "%.2f", lf.coastCorridorReach)) Rand \(lf.minBorderDistance) Eis \(lf.iceCells)")
        }
    }
}
