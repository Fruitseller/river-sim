import XCTest
@testable import SimCore
@testable import SimRender

/// Lauf-Größen der Flussbänder (Look-Iteration 14, `RibbonMesh.flows`):
/// Kolk ↔ Riffel, Weißwasser, Gefälle und Breite je Vertex.
final class RibbonFlowTests: XCTestCase {

    /// Pflicht-Wächter: der Kanal ist vollständig, im Wertebereich, auf
    /// Stillwasser und Delta-Armen still, und auf Flüssen wechselt er
    /// tatsächlich (kein einheitliches Band).
    func testRibbonFlowAttributesVaryAlongRivers() {
        let t = agedWorld(renderConfig(n: 192), years: 2000)
        let mesh = builtRibbons(t).mesh
        XCTAssertEqual(mesh.flows.count, mesh.vertices.count)
        var riffles: [Float] = [], whites: [Float] = []
        let starts = mesh.stripStarts.map(Int.init) + [mesh.vertices.count]
        for s in 0..<(starts.count - 1) {
            let lo = starts[s], hi = starts[s + 1]
            guard hi > lo else { continue }
            let kind = Double(mesh.uv2s[lo].x)
            for v in lo..<hi {
                let f = mesh.flows[v]
                for c in 0..<3 { XCTAssert((0...1).contains(f[c]), "flows[\(v)][\(c)] = \(f[c])") }
                XCTAssertGreaterThanOrEqual(f.w, 0)
                if kind != WaterRender.ribbonKindRiver {
                    XCTAssertEqual(f.x + f.y + f.z, 0, "Stillwasser/Delta trägt keine Strömung")
                } else {
                    riffles.append(f.x); whites.append(f.y)
                }
            }
        }
        XCTAssertGreaterThan(riffles.count, 200, "Testwelt trägt zu wenig Flussbänder")
        let rifflesHigh = riffles.filter { $0 > 0.7 }.count, poolsLow = riffles.filter { $0 < 0.3 }.count
        XCTAssertGreaterThan(rifflesHigh, riffles.count / 10, "kaum Riffel")
        XCTAssertGreaterThan(poolsLow, riffles.count / 10, "kaum Kolke")
        let white = whites.filter { $0 > 0.3 }.count
        XCTAssertGreaterThan(white, 0, "nirgends Weißwasser")
        // Die Hälfte statt eines Drittels: die steilere Linux-Welt (glibc-libm)
        // trägt auf 402 von rund 1200 Fluss-Vertices Weißwasser, zu Recht
        // (Gefällestufen). Ein Saum über ganze Läufe läge nahe 100 %.
        XCTAssertLessThan(white, whites.count / 2, "Weißwasser ist kein Saum über ganze Läufe")
    }

    /// Messlauf: Verteilung der Lauf-Größen auf der Produktionswelt.
    func testRibbonFlowProductionDiagnostic() throws {
        try skipUnlessMeasuring()
        let env = ProcessInfo.processInfo.environment
        let path = env["RS_CACHE"].map { "\($0)/world-s1337-20000.rsw" }
        var t: Terrain
        if let p = path, FileManager.default.fileExists(atPath: p) {
            t = try WorldSnapshot.read(from: p)
        } else {
            t = Terrain(config: SimConfig.production, seed: 1337,
                        settleYears: SimConfig.productionSettleYears)
            let start = t.years
            while t.years < start + 20000 - 1e-6 { t.step(dtYears: 1000) }
        }
        t.computeFlow()
        let r = RiverRibbonRenderer()
        r.renderGrid = t.cfg.n
        let mesh = r.build(t, hscale: RenderContract.heightScale, lift: RenderContract.riverLift)
        var comp: [[Float]] = [[], [], [], []]
        for v in stride(from: 0, to: mesh.flows.count, by: 2)
        where Double(mesh.uv2s[v].x) == WaterRender.ribbonKindRiver && mesh.colors[v].w > 0.25 {
            for c in 0..<4 { comp[c].append(mesh.flows[v][c]) }
        }
        // Rohes Längsgefälle entlang der Zentrumslinien (Sim-Höhe je Zelle),
        // für die Fenster `ribbonSlopeLo/Hi` und `ribbonWhiteSlopeLo/Hi`.
        var raw: [Double] = []
        let n = t.cfg.n
        for ch in t.meander.channels where ch.nodes.count > 8 {
            let hs = ch.nodes.map { bilinearGrid(t.h, $0.x, $0.z, n: n) }
            var arc = [0.0]
            for i in 1..<ch.nodes.count {
                let dx = ch.nodes[i].x - ch.nodes[i - 1].x, dz = ch.nodes[i].z - ch.nodes[i - 1].z
                arc.append(arc[i - 1] + (dx * dx + dz * dz).squareRoot())
            }
            for i in 0..<ch.nodes.count {
                var lo = i, hi = i
                while lo > 0, arc[i] - arc[lo - 1] <= WaterRender.ribbonSlopeWindowCells { lo -= 1 }
                while hi < ch.nodes.count - 1, arc[hi + 1] - arc[i] <= WaterRender.ribbonSlopeWindowCells { hi += 1 }
                if arc[hi] - arc[lo] > 1e-6, ch.discharge[i] > 0 { raw.append(abs(hs[lo] - hs[hi]) / (arc[hi] - arc[lo])) }
            }
        }
        let rs = raw.sorted()
        if !rs.isEmpty {
            print("rawSlope", rs.count, [0.1, 0.25, 0.5, 0.75, 0.9, 0.95, 0.98, 0.995].map {
                String(format: "%.4f", rs[min(rs.count - 1, Int($0 * Double(rs.count)))]) }.joined(separator: " "))
        }
        for (c, name) in ["riffle", "white", "steep", "width"].enumerated() {
            let s = comp[c].sorted()
            guard !s.isEmpty else { continue }
            let q = [0.1, 0.25, 0.5, 0.75, 0.9, 0.98].map { s[min(s.count - 1, Int($0 * Double(s.count)))] }
            print(name, s.count, q.map { String(format: "%.3f", $0) }.joined(separator: " "))
        }
    }
}
