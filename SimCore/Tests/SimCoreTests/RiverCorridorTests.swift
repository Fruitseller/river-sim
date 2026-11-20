import XCTest
@testable import SimCore
@testable import SimRender

/// Fluss als Korridor (Look E, Issue #239): Querprofil und Korridor-Mesh unter
/// den Flussbändern. Die Verträge mit `corridor.gdshaderinc` und
/// `water.gdshader`: Bett unter der Uferkante, Wasser nie über dem Ufer, und
/// der Deckel (`lid`, Tiefe des Korridors im Bild) liegt über allem Gelände im
/// Querschnitt — sonst stäche Gelände durch Bett und Wasserfläche.
final class RiverCorridorTests: XCTestCase {

    private func flat(_ y: Double) -> (Double) -> Double { { _ in y } }

    /// Querprofil auf ebenem Gelände: Uferkante auf Geländehöhe, Bett darunter,
    /// im Bogen Thalweg am Prallhang und breite Bank am Gleithang.
    func testSectionShape() {
        let cs = 0.156
        let s = CorridorProfile.section(halfWidthCells: 2, visible: 1, waterLeft: 1.0, waterRight: 1.0,
                                        bend: 0.8, riffle: 0, cellSize: cs, surface: flat(1.05))
        let k = CorridorProfile.columns, top = CorridorProfile.topColumn, sh = CorridorProfile.shoreColumn
        for c in [0, top, k - 1 - top, k - 1] {
            XCTAssertEqual(s.heights[c], 1.05, accuracy: 1e-12, "Fuß und Uferkante auf dem Gelände (\(c))")
        }
        for c in (top + 1)..<(k - 1 - top) { XCTAssertLessThan(s.heights[c], 1.05, "Spalte \(c) über der Uferkante") }
        let thalweg = (0..<k).min { s.heights[$0] < s.heights[$1] }!
        XCTAssertLessThan(s.offsets[thalweg], 0, "bend > 0: Prallhang links, Thalweg dorthin versetzt")
        // Uferlinie: am Gleithang (rechts) näher zur Mitte.
        XCTAssertGreaterThan(-s.offsets[sh], s.offsets[k - 1 - sh], "Gleithang trägt die breitere Bank")
        XCTAssertGreaterThan(s.bar[k - 1 - top - 1], 0.5, "Kiesbank am Gleithang")
        XCTAssertEqual(s.bar[top + 1], 0, "kein Kies am Prallhang")
        XCTAssertGreaterThanOrEqual(s.lid, 1.05 + CorridorProfile.lidClearance - 1e-12)
        // Breiter = tiefer, Furt = flacher, unsichtbar = flach.
        let wide = CorridorProfile.section(halfWidthCells: 3, visible: 1, waterLeft: 1, waterRight: 1,
                                           bend: 0, riffle: 0, cellSize: cs, surface: flat(1.05))
        let narrow = CorridorProfile.section(halfWidthCells: 0.5, visible: 1, waterLeft: 1, waterRight: 1,
                                             bend: 0, riffle: 0, cellSize: cs, surface: flat(1.05))
        let ford = CorridorProfile.section(halfWidthCells: 3, visible: 1, waterLeft: 1, waterRight: 1,
                                           bend: 0, riffle: 1, cellSize: cs, surface: flat(1.05))
        let gone = CorridorProfile.section(halfWidthCells: 3, visible: 0, waterLeft: 1, waterRight: 1,
                                           bend: 0, riffle: 0, cellSize: cs, surface: flat(1.05))
        XCTAssertGreaterThan(wide.depths[k / 2], narrow.depths[k / 2])
        XCTAssertLessThan(ford.depths[k / 2], wide.depths[k / 2])
        XCTAssertEqual(gone.depths[k / 2], 0, accuracy: 1e-12)
        XCTAssertEqual(gone.offsets[0], gone.offsets[k - 1], accuracy: 1e-12, "unsichtbar: Breite null")
    }

    /// Liegt das Gelände am Ufer UNTER dem Wasser (Damm, Querneigung), hebt
    /// sich die Uferkante über den Wasserspiegel: Wasser steht nie über dem Ufer.
    func testWaterNeverAboveTheBankInSection() {
        let s = CorridorProfile.section(halfWidthCells: 2, visible: 1, waterLeft: 1.0, waterRight: 1.1,
                                        bend: -0.5, riffle: 0, cellSize: 0.156, surface: flat(0.9))
        let k = CorridorProfile.columns, top = CorridorProfile.topColumn, sh = CorridorProfile.shoreColumn
        XCTAssertGreaterThanOrEqual(s.heights[top], s.heights[sh] + CorridorProfile.freeboard - 1e-12)
        XCTAssertGreaterThanOrEqual(s.heights[k - 1 - top], s.heights[k - 1 - sh] + CorridorProfile.freeboard - 1e-12)
        XCTAssertEqual(s.heights[0], 0.9, accuracy: 1e-12, "Fuß des Uferwalls auf dem Gelände")
        XCTAssertGreaterThanOrEqual(s.lid, 1.1, "Deckel über dem Wasser")
    }

    /// Pflicht-Wächter auf der gealterten Render-Testwelt: Mesh konsistent,
    /// Bett unter der Uferkante, Wasser nie über dem Ufer, kein Gelände über
    /// dem Deckel (sonst stäche es durch Bett und Wasserfläche).
    func testCorridorOnAgedWorld() {
        let size = Int(ProcessInfo.processInfo.environment["RS_CORRIDOR_N"] ?? "384") ?? 384
        let t = agedWorld(renderConfig(n: size), years: 4000)
        let render = RenderState(geometryMode: true)
        _ = frameOverlays(render, t)
        let mesh = render.riverRibbonMesh
        let c = mesh.corridor
        let k = CorridorProfile.columns, top = CorridorProfile.topColumn, sh = CorridorProfile.shoreColumn
        XCTAssertEqual(mesh.profile.count, mesh.vertices.count, "ribbon_profile je Band-Vertex")
        XCTAssertGreaterThan(c.vertices.count, 50 * k, "Testwelt trägt zu wenig Korridor")
        XCTAssertEqual(c.vertices.count % k, 0)
        for arr in [c.normals.count, c.colors.count, c.uvs.count, c.uv2s.count, c.custom.count] {
            XCTAssertEqual(arr, c.vertices.count, "Korridor-Puffer gleich lang")
        }
        XCTAssertEqual(c.indices.count % 3, 0)
        XCTAssertTrue(c.indices.allSatisfy { $0 >= 0 && Int($0) < c.vertices.count })

        let n = t.cfg.n, cs = t.cfg.cellSize, half = t.cfg.world / 2
        let bank = BankSurface(h: t.h, n: n, renderGrid: n, hscale: RenderContract.heightScale)
        var sections = 0, bedAbove = 0, waterAbove = 0, pierced = 0, lifted = 0
        var maxPierce = 0.0
        for start in stride(from: 0, to: c.vertices.count, by: k) {
            guard c.colors[start].w > 0.05 else { continue }   // sichtbare Querschnitte
            sections += 1
            let topL = Double(c.vertices[start + top].y), topR = Double(c.vertices[start + k - 1 - top].y)
            for col in (sh + 1)..<(k - 1 - sh) {
                if Double(c.vertices[start + col].y) > min(topL, topR) + 1e-5 { bedAbove += 1 }
            }
            // Wasserspiegel an den Uferlinien gegen die eigene Uferkante.
            let wL = Double(c.vertices[start + sh].y + c.custom[start + sh].x)
            let wR = Double(c.vertices[start + k - 1 - sh].y + c.custom[start + k - 1 - sh].x)
            if wL > topL + 1e-5 || wR > topR + 1e-5 { waterAbove += 1 }
            let lid = Double(c.custom[start].y)
            for col in 0..<k {
                let v = c.vertices[start + col]
                let g = bank.height((Double(v.x) + half) / cs, (Double(v.z) + half) / cs)
                let over = max(g, Double(v.y)) - lid
                if over > 1e-4 { pierced += 1; maxPierce = max(maxPierce, over) }
            }
            // Der Fuß liegt auf dem Gelände (keine Lippe, keine Lücke zum Gelände);
            // gezählt werden die Uferkanten, die als Uferwall darüber stehen.
            for e in [start, start + k - 1] {
                let v = c.vertices[e]
                let g = bank.height((Double(v.x) + half) / cs, (Double(v.z) + half) / cs)
                XCTAssertEqual(Double(v.y), g, accuracy: 1e-4, "Korridor-Fuß nicht auf dem Gelände")
            }
            for e in [start + top, start + k - 1 - top] {
                let v = c.vertices[e]
                let g = bank.height((Double(v.x) + half) / cs, (Double(v.z) + half) / cs)
                if Double(v.y) > g + 0.02 { lifted += 1 }
            }
        }
        let rows = c.vertices.count / k
        let alphas = stride(from: 0, to: c.vertices.count, by: k).map { c.colors[$0].w }
        print("rows=\(rows) a>0.05=\(alphas.filter { $0 > 0.05 }.count) a>0=\(alphas.filter { $0 > 0 }.count) "
              + "ribbonVerts=\(mesh.vertices.count) presence>0=\(mesh.profile.filter { $0.x > 0 }.count) "
              + "n=\(n) cs=\(cs)")
        print("corridor sections=\(sections) bedAbove=\(bedAbove) waterAbove=\(waterAbove) "
              + "pierced=\(pierced) maxPierce=\(maxPierce) liftedEdges=\(lifted)")
        XCTAssertGreaterThan(sections, 200)
        XCTAssertEqual(bedAbove, 0, "Bett über der Uferkante")
        XCTAssertEqual(waterAbove, 0, "Wasser über dem Ufer")
        XCTAssertEqual(pierced, 0, "Gelände oder Korridor über dem Deckel")
        // Die Wasserfläche des Bands liegt unter dem Deckel ihres Stützpunkts.
        for (v, p) in zip(mesh.vertices, mesh.profile) where p.x > 0 {
            XCTAssertLessThanOrEqual(v.y, p.y + 1e-5, "Wasserfläche über dem Deckel")
        }
    }
}
