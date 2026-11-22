import XCTest
@testable import SimCore
@testable import SimRender

/// „Flussbänder schweben über dem Gelände" (Issue #233, Look-Hill-Climber
/// Nr. 13): misst je Band-Dreieck die Höhe der Bandfläche gegen die
/// GERENDERTE Geländehöhe darunter.
///
/// Gerenderte Höhe = `renderSurfaceHeight` der Sim-Höhe × `heightScale`, über
/// Seen so weit zum Spiegel gehoben wie im Terrain-Vertex-Shader. Die
/// Relief-Verschiebung des Bakes fehlt bewusst: `relief_bake.gdshader`
/// gewichtet sie mit `1 − Schutzmaske`, und die Schutzmaske deckt jedes Band
/// samt `WaterRender.protectSeamCells` Saum — unter einem Band ist sie null.
/// Das Kronendach hebt das Gelände nur an (verdeckt also höchstens Wasser,
/// lässt es nie schweben) und fehlt ebenso.
///
/// Gemessen wird an der WASSERLINIE (`water.gdshader`: sichtbar ist das
/// Wasser für |2u − 1| ≤ (1 − `ribbonWaterline`) · visible(alpha)): liegt
/// die Wasserfläche dort über dem Gelände, sieht man unter ihrer Kante das
/// Gelände — die Platte schwebt. In der Bandmitte darf Wasser über dem Bett
/// stehen (dafür ist es Wasser), dort zählt umgekehrt nur, ob es unter dem
/// Gelände verschwindet.
enum RibbonFloat {
    struct Summary {
        /// Gemessene Wasserlinien-Punkte (sichtbare Land-Bänder).
        var edgePoints = 0
        /// Davon mit Überstand über `floatTolerance`.
        var floating = 0
        /// Davon in Segmentmitten und auf Altarmen.
        var floatingMid = 0, floatingOxbow = 0
        var maxOverhang = 0.0
        var meanOverhang = 0.0
        /// Mittelpunkte (u = 0,5), deren Wasser unter dem Gelände liegt.
        var centerPoints = 0
        var sunk = 0
        /// Histogramm der Wasserlinien-Überstände (Welt-Y).
        var over: [Double: Int] = [:]
    }

    /// Überstand an der Wasserlinie, den das Auge nicht als Schweben liest
    /// (Welt-Y; eine Zelle ist 0,156 breit): die halbe Höhe einer
    /// Zellbreite. Darunter liegt die Kante im Gelände.
    static let floatTolerance = 0.08
    /// Mitte gilt als versunken, wenn das Gelände um mehr darüber liegt.
    static let sinkTolerance = 0.02
    static let visibleAlpha = 0.25
    static let bins = [0.02, 0.05, 0.08, 0.15, 0.25, 0.35]

    /// `water` = RGBA8-Wasserfeld desselben Frames (G = See-Kanal): daraus
    /// das See-Gate wie im Terrain-Shader (`lake_gate_at`). Leer = ohne Gate;
    /// dann hebt die Fläche hier über kleinen Tümpeln mehr als im Bild, und
    /// Schweben darüber bliebe unsichtbar (Review Neon Nr. 6) — die
    /// Pflicht-Wächter geben es deshalb mit.
    static func measure(_ t: Terrain, mesh: RibbonMesh, water: [UInt8] = [],
                        hscale: Double = RenderContract.heightScale) -> Summary {
        let n = t.cfg.n, cs = t.cfg.cellSize, half = t.cfg.world / 2
        let sea = t.cfg.sea
        let gated = water.count == n * n * 4
        // Gerenderte Oberfläche wie im Terrain-Vertex-Shader: Seen heben das
        // Gelände über `geometryLift*` (smoothstep auf die Spiegeltiefe) auf
        // ihren Spiegel, mal dem See-Gate des Rasterwassers.
        var surface = t.h
        for k in 0..<surface.count where t.waterLevel[k] > sea && t.h[k] > sea {
            let pond = t.waterLevel[k] - t.h[k]
            let gate = gated
                ? WaterRender.smoothstep(WaterRender.lakeGateLo, WaterRender.lakeGateHi,
                                         Double(water[k * 4 + 1]) / 255) : 1
            surface[k] += WaterRender.smoothstep(WaterRender.geometryLiftLo,
                                                 WaterRender.geometryLiftHi, pond) * max(0, pond) * gate
        }
        // Über dem Meer zählt der Punkt nicht: dort liegt das Band als
        // Trübung unter der Meeresfläche.
        func ground(_ x: Double, _ z: Double) -> (y: Double, water: Bool) {
            let gx = (x + half) / cs, gz = (z + half) / cs
            let y = renderSurfaceHeight(surface, gx, gz, n: n, renderGrid: n)
            let raw = renderSurfaceHeight(t.h, gx, gz, n: n, renderGrid: n)
            return (y * hscale, raw <= sea + 1e-4)
        }
        var out = Summary()
        var sum = 0.0
        let line = 1 - WaterRender.ribbonWaterline
        let starts = mesh.stripStarts.map(Int.init) + [mesh.vertices.count]
        for s in 0..<(starts.count - 1) {
            let lo = starts[s], hi = starts[s + 1]
            guard hi - lo >= 4 else { continue }
            for v in stride(from: lo, to: hi - 2, by: 2) {
                let kind = Double(mesh.uv2s[v].x)
                if abs(kind - WaterRender.ribbonKindDelta) < 0.1 { continue }
                let L0 = SIMD3<Double>(mesh.vertices[v]), R0 = SIMD3<Double>(mesh.vertices[v + 1])
                let L1 = SIMD3<Double>(mesh.vertices[v + 2]), R1 = SIMD3<Double>(mesh.vertices[v + 3])
                let a0 = Double(mesh.colors[v].w), a1 = Double(mesh.colors[v + 2].w)
                for tt in [0.0, 0.5] {
                    let alpha = a0 + (a1 - a0) * tt
                    guard alpha >= visibleAlpha else { continue }
                    let vis = WaterRender.ribbonVisibleWidth(alpha)
                    var points: [(Double, Bool)] = [(0.5, false)]
                    for reach in [line - WaterRender.ribbonWaterlineJitter, line,
                                  line + WaterRender.ribbonWaterlineJitter] {
                        let du = 0.5 * reach * vis
                        points += [(0.5 - du, true), (0.5 + du, true)]
                    }
                    for (u, edge) in points {
                        // Dreiecke wie im Mesh: (L0, L1, R0) und (R0, L1, R1).
                        let p: SIMD3<Double> = u + tt <= 1
                            ? L0 + u * (R0 - L0) + tt * (L1 - L0)
                            : R1 + (1 - u) * (L1 - R1) + (1 - tt) * (R0 - R1)
                        let g = ground(p.x, p.z)
                        if g.water { continue }
                        let d = p.y - g.y
                        if edge {
                            out.edgePoints += 1
                            sum += d
                            out.maxOverhang = max(out.maxOverhang, d)
                            if d > floatTolerance {
                                out.floating += 1
                                if tt > 0 { out.floatingMid += 1 }
                                if kind > 0.75 { out.floatingOxbow += 1 }
                            }
                            for b in bins where d > b { out.over[b, default: 0] += 1 }
                        } else {
                            out.centerPoints += 1
                            if d < -sinkTolerance { out.sunk += 1 }
                        }
                    }
                }
            }
        }
        out.meanOverhang = out.edgePoints > 0 ? sum / Double(out.edgePoints) : 0
        return out
    }

    static func report(_ s: Summary, label: String) -> String {
        let hist = bins.map { String(format: ">%.2f:%d", $0, s.over[$0] ?? 0) }.joined(separator: " ")
        return String(format: "%@: Wasserlinie %d Punkte, schwebend (>%.2f) %d = %.1f %% (Segmentmitte %d, Altarm %d), max %.3f, Mittel %.3f | %@ | Mitte %d, versunken %d = %.1f %%",
                      label, s.edgePoints, floatTolerance, s.floating,
                      100 * Double(s.floating) / Double(max(1, s.edgePoints)),
                      s.floatingMid, s.floatingOxbow,
                      s.maxOverhang, s.meanOverhang, hist, s.centerPoints, s.sunk,
                      100 * Double(s.sunk) / Double(max(1, s.centerPoints)))
    }
}

final class RibbonFloatTests: XCTestCase {

    /// Pflicht-Wächter (Issue #233): auf der gealterten Render-Testwelt liegt
    /// die Wasserlinie der Bänder im Gelände, nicht darüber.
    func testRibbonWaterlineDoesNotFloat() {
        let t = agedWorld(renderConfig(n: 192), years: 2000)
        let render = RenderState(geometryMode: true)
        let water = frameOverlays(render, t).water
        let s = RibbonFloat.measure(t, mesh: render.riverRibbonMesh, water: water)
        print(RibbonFloat.report(s, label: "n192/2000"))
        XCTAssertGreaterThan(s.edgePoints, 200, "Testwelt trägt zu wenig Bänder für eine Aussage")
        // Schranken über BEIDE Welt-Realisierungen (System-libm), gemessen
        // MIT See-Gate (Review Neon Nr. 6; ohne Gate hob die Messung kleine
        // Tümpel an, über denen das Bild nicht hebt): macOS 0,9 % über 0,08,
        // nichts über 0,15, 1,1 % versunkene Mitten; die steilere Linux-Welt
        // (glibc) 4,0 % über 0,08 (meist Segmentmitten über rauem Gelände,
        // Mittel −0,07: das Band liegt dort tief im Einschnitt), 2 von 2654
        // Punkten über 0,15 und 1,8 % versunkene Mitten (ohne Gate 3,5 %
        // schwebend). Vor dem Fix aus #233 schwebten 64,9 % mit Mittel 0,34 —
        // die Platte liegt weit über beiden Schranken.
        XCTAssertLessThanOrEqual(Double(s.floating), 0.05 * Double(s.edgePoints),
                                 "Wasserlinie schwebt über dem Gelände (Issue #233)")
        // 1 % statt 0,5 % (Gremium 3, Befund 3): kurze Kolke im Gerinne
        // blenden das Band nicht mehr aus (`ribbonPondBridgeSamples`), dort
        // deckt der Korridor; am Kolkrand stehen damit einzelne sichtbare
        // Wasserlinien-Punkte bis 0,23 über dem Gelände (macOS 6 von 1056,
        // ohne Überbrückung 0). Die Platte vor #233 lag bei 65 %.
        XCTAssertLessThanOrEqual(Double(s.over[0.15] ?? 0), 0.01 * Double(s.edgePoints),
                                 "Wasserlinie steht als Platte über dem Gelände (Issue #233)")
        // Bis zum Review Neon Nr. 6: 25 %. Ein Zehntel lässt beiden Welten
        // Luft und fängt ein Band, das in größeren Teilen ins Gelände sinkt.
        XCTAssertLessThanOrEqual(Double(s.sunk), 0.10 * Double(s.centerPoints),
                                 "Bandmitte verschwindet unter dem Gelände")
    }

    /// Messlauf auf der Produktionswelt (Seed 1337, 20.000 Jahre wie die
    /// Aufnahmen des Hill-Climbers). RS_CACHE = Ordner für den Welt-Snapshot.
    func testRibbonFloatProductionDiagnostic() throws {
        try skipUnlessMeasuring()
        let env = ProcessInfo.processInfo.environment
        let years = Double(env["RS_YEARS"] ?? "20000") ?? 20000
        let path = env["RS_CACHE"].map { "\($0)/world-s1337-\(Int(years)).rsw" }
        var t: Terrain
        if let p = path, FileManager.default.fileExists(atPath: p) {
            t = try WorldSnapshot.read(from: p)
        } else {
            t = Terrain(config: SimConfig.production, seed: 1337,
                        settleYears: SimConfig.productionSettleYears)
            let start = t.years
            while t.years < start + years - 1e-6 { t.step(dtYears: 1000) }
            if let p = path { _ = try WorldSnapshot.write(t, to: p) }
        }
        t.computeFlow()
        let r = RiverRibbonRenderer()
        r.renderGrid = t.cfg.n
        let mesh = r.build(t, hscale: RenderContract.heightScale, lift: RenderContract.riverLift)
        print(RibbonFloat.report(RibbonFloat.measure(t, mesh: mesh), label: "produktion/\(Int(years))"))
    }
}
