import XCTest
@testable import SimCore
@testable import SimRender

final class RiverCorridorTests: XCTestCase {

    private func flat(_ y: Double) -> (Double) -> Double { { _ in y } }

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
        XCTAssertGreaterThan(-s.offsets[sh], s.offsets[k - 1 - sh], "Gleithang trägt die breitere Bank")
        XCTAssertGreaterThan(s.bar[k - 1 - top - 1], 0.5, "Kiesbank am Gleithang")
        XCTAssertEqual(s.bar[top + 1], 0, "kein Kies am Prallhang")
        XCTAssertGreaterThanOrEqual(s.lid, 1.05 + CorridorProfile.lidClearance - 1e-12)
        for c in [0, k - 1] {
            XCTAssertLessThanOrEqual(abs(s.offsets[c]), CorridorProfile.maxReachCells(halfWidthCells: 2) + 1e-9)
        }
        let wideBar = CorridorProfile.section(halfWidthCells: 3.2, visible: 1, waterLeft: 1, waterRight: 1,
                                              bend: 1, riffle: 0, cellSize: cs, surface: flat(0.9))
        for c in [0, k - 1] {
            XCTAssertLessThanOrEqual(abs(wideBar.offsets[c]), CorridorProfile.maxReachCells(halfWidthCells: 3.2) + 1e-9,
                                     "Ufersuche und Uferwall bleiben in der Schutzmaske")
        }
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

    func testWaterNeverAboveTheBankInSection() {
        let s = CorridorProfile.section(halfWidthCells: 2, visible: 1, waterLeft: 1.0, waterRight: 1.1,
                                        bend: -0.5, riffle: 0, cellSize: 0.156, surface: flat(0.9))
        let k = CorridorProfile.columns, top = CorridorProfile.topColumn, sh = CorridorProfile.shoreColumn
        XCTAssertGreaterThanOrEqual(s.heights[top], s.heights[sh] + CorridorProfile.freeboard - 1e-12)
        XCTAssertGreaterThanOrEqual(s.heights[k - 1 - top], s.heights[k - 1 - sh] + CorridorProfile.freeboard - 1e-12)
        XCTAssertEqual(s.heights[0], 0.9, accuracy: 1e-12, "Fuß des Uferwalls auf dem Gelände")
        XCTAssertGreaterThanOrEqual(s.lid, 1.1, "Deckel über dem Wasser")
    }

    func testCanyonKeepsTheLidNearTheWater() {
        let k = CorridorProfile.columns, sh = CorridorProfile.shoreColumn
        let wall: (Double) -> Double = { c in 1.0 + max(0, abs(c) - 1.5) }
        let s = CorridorProfile.section(halfWidthCells: 2, visible: 1, waterLeft: 1.0, waterRight: 1.0,
                                        bend: 0, riffle: 0, cellSize: 0.156, surface: wall)
        let cap = 1.0 + CorridorProfile.lidMaxAboveWater + CorridorProfile.lidClearance
        XCTAssertLessThanOrEqual(s.lid, cap + 1e-12, "Deckel klettert die Schluchtwand hoch")
        for c in 0..<k {
            XCTAssertLessThanOrEqual(s.heights[c], s.lid - CorridorProfile.lidClearance + 1e-12,
                                     "Korridor über dem Deckel (Spalte \(c))")
        }
        XCTAssertGreaterThanOrEqual(s.heights[CorridorProfile.topColumn], s.heights[sh] + CorridorProfile.freeboard - 1e-12,
                                    "Wasser über dem Ufer")
        XCTAssertGreaterThan(CorridorProfile.lidMaxAboveWater, CorridorProfile.freeboard)
        let steep: (Double) -> Double = { c in 1.0 + 4 * max(0, abs(c) - 1.0) }
        let w = CorridorProfile.section(halfWidthCells: 2, visible: 1, waterLeft: 1.0, waterRight: 1.0,
                                        bend: 0.6, riffle: 0, cellSize: 0.156, surface: steep)
        let top = CorridorProfile.topColumn
        for (t, shore) in [(top, sh), (k - 1 - top, k - 1 - sh)] {
            XCTAssertEqual(w.depths[shore], 0, accuracy: 1e-12, "Uferlinie nicht auf dem Wasser")
            XCTAssertGreaterThanOrEqual(w.heights[t], w.heights[shore] + CorridorProfile.freeboard - 1e-12,
                                        "Wand ab der Uferlinie: Wasser über dem Ufer")
            XCTAssertLessThanOrEqual(w.heights[t], w.lid - CorridorProfile.lidClearance + 1e-12)
        }
    }

    func testEdgeSmoothingRemovesSingleJumps() {
        var v = [Double](repeating: 1.0, count: 12)
        v[6] = 3.5
        let s = CorridorSections.smoothEdges(v)
        XCTAssertEqual(s[6], 1.0, accuracy: 1e-12, "einzelner Sprung der Ufersuche bleibt stehen")
        let ramp = (0..<12).map { Double($0) * 0.1 }
        let r = CorridorSections.smoothEdges(ramp)
        for a in 4..<8 { XCTAssertEqual(r[a], ramp[a], accuracy: 1e-12, "Rampe verfälscht (\(a))") }
    }

    func testInnerBendReachIsLimited() {
        let cs = 0.156
        let free = CorridorProfile.section(halfWidthCells: 2, visible: 1, waterLeft: 1, waterRight: 1,
                                           bend: 0, riffle: 0, cellSize: cs, surface: flat(0.9))
        let capped = CorridorProfile.section(halfWidthCells: 2, visible: 1, waterLeft: 1, waterRight: 1,
                                             bend: 0, riffle: 0, cellSize: cs, reachLimit: (.infinity, 2.0),
                                             surface: flat(0.9))
        let k = CorridorProfile.columns, sh = CorridorProfile.shoreColumn
        XCTAssertGreaterThan(free.offsets[k - 1], 2.0, "Testaufbau: freie Reichweite über der Grenze")
        XCTAssertLessThanOrEqual(capped.offsets[k - 1], 2.0 + 1e-9, "Innenseite über die Grenze")
        XCTAssertEqual(capped.offsets[0], free.offsets[0], accuracy: 1e-12, "Außenseite verändert")
        let tight = CorridorProfile.section(halfWidthCells: 2, visible: 1, waterLeft: 1, waterRight: 1,
                                            bend: 0, riffle: 0, cellSize: cs, reachLimit: (.infinity, 0.1),
                                            surface: flat(0.9))
        XCTAssertGreaterThan(tight.offsets[k - 1], tight.offsets[k - 1 - sh], "kein Platz mehr für das Ufer")
        for c in 1..<k { XCTAssertGreaterThanOrEqual(tight.offsets[c], tight.offsets[c - 1], "Querschnitt gefaltet") }
    }

    func testCorridorOnAgedWorld() {
        let size = Int(ProcessInfo.processInfo.environment["RS_CORRIDOR_N"] ?? "384") ?? 384
        let t = agedWorld(renderConfig(n: size), years: 4000)
        let render = RenderState(geometryMode: true)
        let overlays = frameOverlays(render, t)
        let mesh = render.riverRibbonMesh
        let c = mesh.corridor
        let k = CorridorProfile.columns, top = CorridorProfile.topColumn, sh = CorridorProfile.shoreColumn
        XCTAssertEqual(mesh.profile.count, mesh.vertices.count, "ribbon_profile je Band-Vertex")
        XCTAssertGreaterThan(mesh.profile.filter { $0.x > 0 }.count, 0, "Testwelt ohne Korridor")
        XCTAssertGreaterThan(mesh.profile.filter { $0.x == 0 }.count, 0,
                             "Testwelt ohne Band ohne Korridor — Wächter wäre leer")
        XCTAssertGreaterThan(c.vertices.count, 50 * k, "Testwelt trägt zu wenig Korridor")
        let drained = mesh.profile.indices.filter {
            mesh.profile[$0].x > 0.5 && mesh.colors[$0].w > 0.5 && mesh.profile[$0].z <= 0
        }.count
        XCTAssertEqual(drained, 0, "Band-Wasser läuft am Korridor-Ende auf null aus")
        XCTAssertEqual(c.vertices.count % k, 0)
        for arr in [c.normals.count, c.colors.count, c.uvs.count, c.uv2s.count, c.custom.count] {
            XCTAssertEqual(arr, c.vertices.count, "Korridor-Puffer gleich lang")
        }
        XCTAssertEqual(c.indices.count % 3, 0)
        XCTAssertTrue(c.indices.allSatisfy { $0 >= 0 && Int($0) < c.vertices.count })

        let n = t.cfg.n, cs = t.cfg.cellSize, half = t.cfg.world / 2
        let bank = BankSurface(h: t.h, n: n, renderGrid: n, hscale: RenderContract.heightScale)
        var sections = 0, bedAbove = 0, waterAbove = 0, pierced = 0, lifted = 0, outsideMask = 0, lidHigh = 0, wetRock = 0, wetVertices = 0
        var maxWetRockOver = 0.0, maxBedRockOver = 0.0, thalwegRock = 0
        var maxPierce = 0.0
        for start in stride(from: 0, to: c.vertices.count, by: k) {
            guard c.colors[start].w > 0.05 else { continue }
            sections += 1
            let topL = Double(c.vertices[start + top].y), topR = Double(c.vertices[start + k - 1 - top].y)
            for col in (sh + 1)..<(k - 1 - sh) {
                if Double(c.vertices[start + col].y) > min(topL, topR) + 1e-5 { bedAbove += 1 }
            }
            let wL = Double(c.vertices[start + sh].y + c.custom[start + sh].x)
            let wR = Double(c.vertices[start + k - 1 - sh].y + c.custom[start + k - 1 - sh].x)
            if wL > topL + 1e-5 || wR > topR + 1e-5 { waterAbove += 1 }
            let lid = Double(c.custom[start].y)
            let waterTop = max(Double(c.vertices[start + sh].y + c.custom[start + sh].x),
                               Double(c.vertices[start + k - 1 - sh].y + c.custom[start + k - 1 - sh].x))
            if lid > waterTop + CorridorProfile.lidMaxAboveWater + CorridorProfile.lidClearance + 1e-4 { lidHigh += 1 }
            for col in 0..<k {
                let v = c.vertices[start + col]
                let over = Double(v.y) - lid
                if over > 1e-4 { pierced += 1; maxPierce = max(maxPierce, over) }
                if col >= sh && col <= k - 1 - sh {
                    wetVertices += 1
                    let rock = bank.height((Double(v.x) + half) / cs, (Double(v.z) + half) / cs) - lid
                    if rock > 1e-4 { wetRock += 1 }
                    maxWetRockOver = max(maxWetRockOver, rock)
                    if col > sh && col < k - 1 - sh { maxBedRockOver = max(maxBedRockOver, rock) }
                    if col == k / 2, rock > 1e-4 { thalwegRock += 1 }
                }
            }
            for e in [start, start + k - 1] {
                let v = c.vertices[e]
                let gx = (Double(v.x) + half) / cs, gz = (Double(v.z) + half) / cs
                let lidTop = Double(c.custom[start].y) - CorridorProfile.lidClearance
                XCTAssertEqual(Double(v.y), min(bank.height(gx, gz), lidTop), accuracy: 1e-4,
                               "Korridor-Fuß nicht auf dem Gelände")
                let ci = min(max(Int(gx.rounded()), 0), n - 1), cj = min(max(Int(gz.rounded()), 0), n - 1)
                if overlays.protectMask[cj * n + ci] == 0 { outsideMask += 1 }
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
              + "pierced=\(pierced) maxPierce=\(maxPierce) liftedEdges=\(lifted) outsideMask=\(outsideMask) "
              + "lidHigh=\(lidHigh) wetRock=\(wetRock)/\(wetVertices) maxWetRockOver=\(maxWetRockOver) "
              + "maxBedRockOver=\(maxBedRockOver) thalwegRock=\(thalwegRock)")
        XCTAssertGreaterThan(sections, 200)
        XCTAssertEqual(bedAbove, 0, "Bett über der Uferkante")
        XCTAssertEqual(waterAbove, 0, "Wasser über dem Ufer")
        XCTAssertEqual(pierced, 0, "Korridor über dem Deckel")
        XCTAssertLessThanOrEqual(wetRock, wetVertices / 100, "Gelände sticht oft durch das Wasser")
        XCTAssertLessThanOrEqual(thalwegRock, sections / 500, "Fels in der Flussmitte über dem Deckel")
        XCTAssertEqual(lidHigh, 0, "Deckel weit über dem Wasser (zöge den Fluss vor Grate davor)")
        XCTAssertEqual(outsideMask, 0, "Korridor-Fuß außerhalb der Schutzmaske (Naht zu #238)")
        for (v, p) in zip(mesh.vertices, mesh.profile) {
            XCTAssertLessThanOrEqual(v.y, p.y + 1e-5, "Wasserfläche über dem Deckel")
            if p.x == 0 { XCTAssertEqual(v.y, p.y, accuracy: 1e-6, "Band ohne Korridor mit fremdem Deckel") }
        }
        var lidPairs = 0
        for start in stride(from: 0, to: c.vertices.count, by: k) where c.colors[start].w > 0.5 {
            let lid = c.custom[start].y
            if mesh.profile.contains(where: { Double($0.x) >= CorridorSections.lidPresence && abs($0.y - lid) < 1e-5 }) { lidPairs += 1 }
        }
        let fullSections = stride(from: 0, to: c.vertices.count, by: k).filter { c.colors[$0].w > 0.5 }.count
        XCTAssertGreaterThan(fullSections, 0)
        XCTAssertGreaterThanOrEqual(Double(lidPairs), 0.99 * Double(fullSections),
                                    "Band trägt nicht den Deckel des Korridors (\(lidPairs)/\(fullSections))")
    }
}
