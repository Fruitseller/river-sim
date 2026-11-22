import XCTest
@testable import SimCore

extension MeanderState {
    /// Ebenen des Abhängigkeitsgraphen, nur für die Überlappungs-Diagnose.
    static func beltLevels(_ footprints: [BeltFootprint]) -> [[Int]] {
        guard !footprints.isEmpty else { return [] }
        var levels = [Int](repeating: 0, count: footprints.count)
        for j in footprints.indices {
            for i in 0..<j where footprints[i].overlaps(footprints[j]) {
                levels[j] = max(levels[j], levels[i] + 1)
            }
        }
        return (0...levels.max()!).map { level in footprints.indices.filter { levels[$0] == level } }
    }
}

final class BeltParallelTests: XCTestCase {
    func testBeltScheduleReleasesOnlyIndependentReadyRuns() {
        let boxes: [MeanderState.BeltFootprint] = (0..<40).map { i in
            let x = Double(i % 8) * 4, z = Double(i / 8) * 4
            return .init(minX: x, maxX: x + 5, minZ: z, maxZ: z + 5, maxSubsteps: 1)
        }
        let schedule = Terrain.BeltSchedule(boxes)
        let lock = NSLock()
        // Swift 6 (Issue #201): beide Mengen werden ausschließlich unter dem
        // obigen `lock` gelesen und geschrieben — der Wächter PRÜFT hier ja
        // gerade die Disziplin, die der Compiler nicht sehen kann.
        nonisolated(unsafe) var active: Set<Int> = [], completed: Set<Int> = []
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            while let index = schedule.take() {
                lock.lock()
                XCTAssertTrue(active.allSatisfy { !boxes[$0].overlaps(boxes[index]) })
                XCTAssertTrue((0..<index).allSatisfy { !boxes[$0].overlaps(boxes[index]) || completed.contains($0) })
                XCTAssertFalse(completed.contains(index))
                active.insert(index)
                lock.unlock()
                lock.lock()
                active.remove(index)
                completed.insert(index)
                lock.unlock()
                schedule.finish(index)
            }
        }
        XCTAssertEqual(completed, Set(boxes.indices))
        XCTAssertTrue(active.isEmpty)
        XCTAssertNil(Terrain.BeltSchedule([]).take())
    }

    private func line(_ count: Int = 120) -> RiverChannel {
        let nodes = (0..<count).map { i in
            MeanderNode(x: 80 + Double(i) * 1.5, z: 260 + 14 * sin(Double(i) * 0.12))
        }
        return RiverChannel(nodes: nodes, discharge: nodes.indices.map { 1800 + Double($0) * 200 })
    }

    func testBeltCachedGeometryRefreshesTheChangedBed() {
        let cfg = SimConfig.production, ch = line()
        let old: (MeanderNode) -> Double = { 0.3 - $0.x * 1e-6 }
        let fresh: (MeanderNode) -> Double = { 0.3 - $0.x * 0.0001 + sin($0.z) * 0.001 }
        var cache = MeanderState.beltGeometry(ch, config: cfg, heightAt: old)
        MeanderState.updateBeltMobility(&cache, ch, config: cfg, minDischarge: cfg.meanderBeltMinCells, heightAt: fresh)
        let reference = MeanderState.beltGeometry(ch, config: cfg, minDischarge: cfg.meanderBeltMinCells, heightAt: fresh)
        for (a, b) in [(cache.width, reference.width), (cache.curv, reference.curv),
                       (cache.nx, reference.nx), (cache.nz, reference.nz),
                       (cache.mob, reference.mob), (cache.cum, reference.cum)] {
            XCTAssertEqual(a.map(\.bitPattern), b.map(\.bitPattern))
        }
        XCTAssertNotEqual(cache.mob, MeanderState.beltGeometry(ch, config: cfg, heightAt: old).mob)
    }

    func testBeltLocalWorkerRetainsTheOriginalNoiseKey() {
        let cfg = SimConfig.production
        let reference = MeanderState(), local = MeanderState()
        let ch = line()
        reference.channels = [ch, ch, ch]
        local.channels = [ch]
        let height: (MeanderNode) -> Double = { 0.3 - $0.x * 1e-6 }
        for step in 0..<12 {
            reference.migrateBeltChannel(2, dt: 10, time: Double(step) * 10, config: cfg, heightAt: height)
            local.migrateBeltChannel(0, dt: 10, time: Double(step) * 10, config: cfg, heightAt: height, noiseChannel: 2)
            XCTAssertEqual(reference.channels[2].nodes, local.channels[0].nodes)
            XCTAssertEqual(reference.channels[2].discharge, local.channels[0].discharge)
            XCTAssertEqual(reference.oxbows, local.oxbows)
            XCTAssertEqual(reference.oxbowAge, local.oxbowAge)
        }
    }

    func testBeltFootprintBoundsSubstepsAndEveryMigrationRead() throws {
        let cfg = SimConfig.production
        for dt in [15.0, 100, 1000] {
            let state = MeanderState()
            state.channels = [line()]
            let box = try XCTUnwrap(state.beltFootprint(state.channels[0], dt: dt, config: cfg))
            let height: (MeanderNode) -> Double = { p in
                XCTAssertTrue(p.x >= box.minX && p.x <= box.maxX && p.z >= box.minZ && p.z <= box.maxZ)
                return 0.3 - p.x * 0.00001 + sin(p.z * 0.1) * 0.001
            }
            let plan = state.beltMigrationPlan(channel: 0, config: cfg, heightAt: height)
            let substeps = max(1, min(4096, Int((plan.rate * dt / (0.5 * cfg.meanderNodeSpacing)).rounded(.up))))
            XCTAssertLessThanOrEqual(substeps, box.maxSubsteps)
            for si in 0..<substeps {
                let sub = dt / Double(substeps)
                state.migrateBeltChannel(0, dt: sub, time: Double(si) * sub, config: cfg, heightAt: height)
                for p in state.channels[0].nodes {
                    XCTAssertTrue(p.x >= box.minX && p.x <= box.maxX && p.z >= box.minZ && p.z <= box.maxZ)
                }
            }
        }
    }

    private func hullBox(_ minX: Double, _ maxX: Double, _ minZ: Double, _ maxZ: Double) -> Terrain.BeltHull {
        Terrain.BeltHull(minX: minX, maxX: maxX, minZ: minZ, maxZ: maxZ,
                         minU: minX + minZ, maxU: maxX + maxZ,
                         minV: minX - maxZ, maxV: maxX - minZ)
    }

    /// Prüft die Konflikt-Regeln von `BeltRWFootprint` (einschließlich reiner
    /// Schreib/Schreib-Überlappung ohne Lese-Überlappung, reiner Lese/Lese-Freigabe
    /// und diagonaler 8-DOP-Trennung) sowie `BeltSchedule` mit R/W-Konflikten und
    /// Kritischer-Pfad-Priorität.
    func testBeltRWFootprintConflictsAndSchedule() {
        let wideFp = MeanderState.BeltFootprint(minX: 0, maxX: 100, minZ: 0, maxZ: 100, maxSubsteps: 1)

        // 1. Reine Schreib/Schreib-Überlappung (disjunkte/leere Lese-Hüllen) muss konfliktieren.
        let writeOnlyA = Terrain.BeltRWFootprint(fp: wideFp,
                                                 writeHulls: [hullBox(10, 20, 10, 20)],
                                                 readHulls: [hullBox(0, 5, 0, 5)])
        let writeOnlyB = Terrain.BeltRWFootprint(fp: wideFp,
                                                 writeHulls: [hullBox(18, 28, 18, 28)],
                                                 readHulls: [])
        XCTAssertTrue(writeOnlyA.conflicts(with: writeOnlyB))
        XCTAssertTrue(writeOnlyB.conflicts(with: writeOnlyA))

        // 2. Schreib/Lese in beiden Richtungen konfliktiert.
        let rwA = Terrain.BeltRWFootprint(fp: wideFp,
                                          writeHulls: [hullBox(10, 15, 10, 15)],
                                          readHulls: [hullBox(5, 25, 5, 25)])
        let rwB = Terrain.BeltRWFootprint(fp: wideFp,
                                          writeHulls: [hullBox(22, 30, 22, 30)],
                                          readHulls: [hullBox(20, 35, 20, 35)])
        XCTAssertTrue(rwA.conflicts(with: rwB))
        XCTAssertTrue(rwB.conflicts(with: rwA))

        // 3. Reine Lese/Lese-Überlappung (disjunkte Schreib-Hüllen) läuft parallel.
        let readOverlapA = Terrain.BeltRWFootprint(fp: wideFp,
                                                   writeHulls: [hullBox(10, 15, 10, 15)],
                                                   readHulls: [hullBox(5, 25, 5, 25)])
        let readOverlapB = Terrain.BeltRWFootprint(fp: wideFp,
                                                   writeHulls: [hullBox(30, 35, 30, 35)],
                                                   readHulls: [hullBox(20, 40, 20, 40)])
        XCTAssertFalse(readOverlapA.conflicts(with: readOverlapB))
        XCTAssertFalse(readOverlapB.conflicts(with: readOverlapA))

        // 4. Diagonale 8-DOP-Trennung: AABBs überlappen, aber u/v trennen die Läufe.
        let diagA = Terrain.BeltHull(minX: 0, maxX: 40, minZ: 0, maxZ: 40,
                                     minU: 0, maxU: 80, minV: -2, maxV: 2)
        let diagB = Terrain.BeltHull(minX: 0, maxX: 40, minZ: 0, maxZ: 40,
                                     minU: 0, maxU: 80, minV: 10, maxV: 14)
        let diagRWA = Terrain.BeltRWFootprint(fp: wideFp, writeHulls: [diagA], readHulls: [diagA])
        let diagRWB = Terrain.BeltRWFootprint(fp: wideFp, writeHulls: [diagB], readHulls: [diagB])
        XCTAssertFalse(diagRWA.conflicts(with: diagRWB))

        // 5. Grobes Rechteck disjunkt -> kein Konflikt trotz gleicher Hülle.
        let farFp = MeanderState.BeltFootprint(minX: 200, maxX: 250, minZ: 200, maxZ: 250, maxSubsteps: 1)
        let farRW = Terrain.BeltRWFootprint(fp: farFp, writeHulls: [hullBox(10, 20, 10, 20)], readHulls: [])
        XCTAssertFalse(writeOnlyA.conflicts(with: farRW))

        // 6. BeltSchedule mit BeltRWFootprint: Exklusivität + Reihenfolge + Kritischer Pfad.
        let rws: [Terrain.BeltRWFootprint] = (0..<24).map { i in
            let x = Double(i % 6) * 12, z = Double(i / 6) * 12
            let fp = MeanderState.BeltFootprint(minX: x - 6, maxX: x + 10, minZ: z - 6, maxZ: z + 10, maxSubsteps: 1)
            return Terrain.BeltRWFootprint(fp: fp,
                                           writeHulls: [hullBox(x, x + 5, z, z + 5)],
                                           readHulls: [hullBox(x - 5, x + 10, z - 5, z + 10)])
        }
        let schedule = Terrain.BeltSchedule(count: rws.count,
                                            weights: (0..<rws.count).map { 1 + ($0 % 5) * 3 },
                                            conflicts: { rws[$0].conflicts(with: rws[$1]) })
        let lock = NSLock()
        // Swift 6 (Issue #201): Zugriff ausschließlich unter `lock` (wie `testBeltScheduleReleasesOnlyIndependentReadyRuns`).
        nonisolated(unsafe) var active: Set<Int> = [], completed: Set<Int> = []
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            while let index = schedule.take() {
                lock.lock()
                XCTAssertTrue(active.allSatisfy { !rws[$0].conflicts(with: rws[index]) })
                XCTAssertTrue((0..<index).allSatisfy { !rws[$0].conflicts(with: rws[index]) || completed.contains($0) })
                active.insert(index)
                lock.unlock()
                lock.lock()
                active.remove(index)
                completed.insert(index)
                lock.unlock()
                schedule.finish(index)
            }
        }
        XCTAssertEqual(completed, Set(rws.indices))

        // Kritischer-Pfad-Priorität: Kette 0 -> 1 (10 + 20 = 30) startet vor unabhängigem Lauf 2 (15).
        let priSched = Terrain.BeltSchedule(count: 3, weights: [10, 20, 15],
                                            conflicts: { ($0 == 0 && $1 == 1) })
        XCTAssertEqual(priSched.take(), 0)
        XCTAssertEqual(priSched.take(), 2)
        priSched.finish(0)
        XCTAssertEqual(priSched.take(), 1)
        priSched.finish(2); priSched.finish(1)
        XCTAssertNil(priSched.take())
    }

    /// Gemischter diagonaler Lauf: unbewegter Oberlauf (`discharge < meanderBeltMinCells`),
    /// Übergang an der ±1-Interpolationsgrenze und beweglicher Mäander-Unterlauf.
    private func mixedDiagonalLine() -> RiverChannel {
        let count = 130
        var nodes: [MeanderNode] = []
        var discharge: [Double] = []
        nodes.reserveCapacity(count)
        discharge.reserveCapacity(count)
        for i in 0..<count {
            let t = Double(i)
            let base = 100.0 + t * 1.15
            let wiggle = i >= 45 ? 16.0 * sin((t - 45.0) * 0.14) : 2.0 * sin(t * 0.1)
            nodes.append(MeanderNode(x: base + wiggle * 0.7, z: base - wiggle * 0.7))
            if i < 48 {
                discharge.append(400.0 + t * 32.0)           // < 2000 (unbewegt)
            } else {
                discharge.append(2000.0 + (t - 48.0) * 240.0) // >= 2000 (beweglich)
            }
        }
        return RiverChannel(nodes: nodes, discharge: discharge)
    }

    /// Lauf mit enger Hufeisenschleife knapp über Hals-Cutoff-Distanz, damit im
    /// Teilschritt-Lauf tatsächlich Altarme abgeschnürt und `plugOxbow` ausgeführt wird.
    private func oxbowProneLine(originX: Double = 45, originZ: Double = 80, scale: Double = 1.0) -> RiverChannel {
        var nodes: [MeanderNode] = []
        var discharge: [Double] = []
        // Unbewegter Oberlauf (20 Knoten, Abfluss < 2000)
        for i in 0..<20 {
            nodes.append(MeanderNode(x: originX + Double(i) * 1.5 * scale, z: originZ))
            discharge.append(500.0 + Double(i) * 70.0)
        }
        // Enger Hals und Schleife im beweglichen Abschnitt (Abfluss >= 2000)
        let neckX = nodes.last!.x + 1.5 * scale
        let loopRadius = 11.0 * scale
        let steps = 38
        for k in 0...steps {
            // Fast voller Kreis nach +Z, der am Ausgang nahe am Eingang vorbeiläuft (Hals ~2,8 Zellen)
            let ang = -Double.pi * 0.44 + Double(k) / Double(steps) * (Double.pi * 1.88)
            let cx = neckX + 1.4 * scale
            let cz = originZ + loopRadius
            let x = cx + loopRadius * cos(ang)
            let z = cz + loopRadius * sin(ang)
            nodes.append(MeanderNode(x: x, z: z))
            discharge.append(2600.0 + Double(k) * 80.0)
        }
        let exitX = nodes.last!.x
        for i in 1...25 {
            let t = Double(i)
            nodes.append(MeanderNode(x: exitX + t * 1.5 * scale, z: originZ + 4.0 * sin(t * 0.25)))
            discharge.append(5600.0 + t * 150.0)
        }
        return RiverChannel(nodes: nodes, discharge: discharge)
    }

    /// Regressionstest für den Vertrag von `BeltRWFootprint`: jede tatsächlich
    /// gelesene Zelle (bilineare Knoten-/Talwand-Abfragen bei `3,5·b`,
    /// Sohlen-Querschnitt, `plugOxbow`-Nachbarn `k±1`/`k±nn`) liegt in
    /// `rw.readHulls`, jede tatsächlich geschriebene Zelle (seitlicher Stempel
    /// `w+0,5` außen / `w+barW·b` innen, `plugOxbow`-Pfropfen und reale
    /// Bett-Mutationen aus `beltStamp` + `plugOxbows`) liegt in `rw.writeHulls`.
    func testBeltRWFootprintBoundsSubstepsReadsStampsAndOxbows() throws {
        let cfg = SimConfig.production
        let nn = cfg.n, maxc = Double(nn - 1)
        let barW = cfg.meanderBarWidths

        func verifyChannel(_ initial: RiverChannel, dt: Double, expectSplitHulls: Bool,
                           expectOxbow: Bool) throws {
            let state = MeanderState()
            state.channels = [initial]
            let fp = try XCTUnwrap(state.beltFootprint(initial, dt: dt, config: cfg))
            let rw = Terrain.BeltRWFootprint.build(channel: initial, dt: dt, footprint: fp, config: cfg)
            if expectSplitHulls {
                XCTAssertGreaterThan(rw.writeHulls.count, 1, "Gemischter Lauf muss statische + mobile Hüllen trennen")
            }

            func assertReadCell(_ ci: Int, _ cj: Int, _ label: String) {
                let x = Double(ci), z = Double(cj)
                XCTAssertTrue(x >= fp.minX && x <= fp.maxX && z >= fp.minZ && z <= fp.maxZ,
                              "\(label): Zelle (\(ci),\(cj)) außerhalb BeltFootprint")
                XCTAssertTrue(rw.containsRead(x: x, z: z),
                              "\(label): Zelle (\(ci),\(cj)) außerhalb rw.readHulls (dt=\(dt))")
            }
            func assertWriteCell(_ ci: Int, _ cj: Int, _ label: String) {
                let x = Double(ci), z = Double(cj)
                XCTAssertTrue(x >= fp.minX && x <= fp.maxX && z >= fp.minZ && z <= fp.maxZ,
                              "\(label): Zelle (\(ci),\(cj)) außerhalb BeltFootprint")
                XCTAssertTrue(rw.containsWrite(x: x, z: z),
                              "\(label): Zelle (\(ci),\(cj)) außerhalb rw.writeHulls (dt=\(dt))")
            }

            var farWallReads = 0
            var stampCells = 0
            var oxbowsPlugged = 0

            let heightAt: (MeanderNode) -> Double = { p in
                let xi = min(max(Int(p.x), 0), nn - 2)
                let yi = min(max(Int(p.z), 0), nn - 2)
                assertReadCell(xi, yi, "bilinear")
                assertReadCell(xi + 1, yi, "bilinear")
                assertReadCell(xi, yi + 1, "bilinear")
                assertReadCell(xi + 1, yi + 1, "bilinear")
                if !state.channels[0].nodes.contains(where: { hypot($0.x - p.x, $0.z - p.z) < 2.0 }) {
                    farWallReads += 1
                }
                return 0.35 - p.x * 0.00001 + sin(p.z * 0.08) * 0.0005
            }

            let plan = state.beltMigrationPlan(channel: 0, config: cfg, heightAt: heightAt)
            let nsub = max(1, min(4096, Int((plan.rate * dt / (0.5 * cfg.meanderNodeSpacing)).rounded(.up))))
            XCTAssertLessThanOrEqual(nsub, fp.maxSubsteps)
            let sub = dt / Double(nsub)
            var geometry: BeltGeometry?

            for si in 0..<nsub {
                let ox0 = state.oxbows.count
                if si == 0 {
                    state.applyBeltMigrationPlan(0, plan: plan, dt: sub, time: 0, config: cfg, noiseChannel: 0)
                } else {
                    state.migrateBeltChannel(0, dt: sub, time: Double(si) * sub, config: cfg,
                                             heightAt: heightAt, geometry: geometry, noiseChannel: 0)
                }
                state.channels[0].clampToWorld(maxCoord: maxc)
                let ch = state.channels[0]
                let nodes = ch.nodes, c = nodes.count
                for p in nodes {
                    XCTAssertTrue(rw.containsWrite(x: p.x, z: p.z), "Knoten außerhalb rw.writeHulls")
                    XCTAssertTrue(rw.containsRead(x: p.x, z: p.z), "Knoten außerhalb rw.readHulls")
                }

                // Exakte Abbildung der Lese- und Schreibzellen von `beltStampChannel(..., part: 1)`.
                let g = MeanderState.beltGeometry(ch, config: cfg, heightAt: heightAt)
                geometry = g
                if let firstMob = g.mob.firstIndex(where: { $0 > 0 }),
                   let lastMob = g.mob.lastIndex(where: { $0 > 0 }) {
                    let bendCurv = MeanderState.bendCurvature(g, config: cfg, activeRange: firstMob...lastMob)
                    let fLo = max(0, firstMob - 2), fHi = min(c - 1, lastMob + 2)
                    for i in fLo...fHi {
                        var flat = false
                        for j in max(0, i - 2)...min(c - 1, i + 2) where g.mob[j] > 0 { flat = true; break }
                        if !flat { continue }
                        let w = 0.5 * g.width[i]
                        var s = -w
                        while s <= w + 1e-9 {
                            let k = Terrain.cellIndex(nodes[i].x + g.nx[i] * s, nodes[i].z + g.nz[i] * s, n: nn)
                            assertReadCell(k % nn, k / nn, "floorRef")
                            s += 0.5
                        }
                    }
                    if cfg.meanderBeltSillCutDepths > 0 {
                        for i in 0..<c {
                            let k = Terrain.cellIndex(nodes[i].x, nodes[i].z, n: nn)
                            assertReadCell(k % nn, k / nn, "sillCut")
                        }
                    }
                    let sLo = max(1, firstMob), sHi = min(c - 2, lastMob)
                    if sLo <= sHi {
                        for i in sLo...sHi where g.mob[i] > 0 {
                            let ck = Terrain.cellIndex(nodes[i].x, nodes[i].z, n: nn)
                            assertReadCell(ck % nn, ck / nn, "stampCenter")
                            let b = g.width[i], w = 0.5 * b
                            let sgn = bendCurv[i] > 0 ? -1.0 : 1.0
                            let ox = sgn * g.nx[i], oz = sgn * g.nz[i]
                            var s = w + 0.5
                            let inner = -(w + barW * b)
                            while s >= inner - 1e-9 {
                                let k = Terrain.cellIndex(nodes[i].x + ox * s, nodes[i].z + oz * s, n: nn)
                                assertWriteCell(k % nn, k / nn, "lateralStamp")
                                assertReadCell(k % nn, k / nn, "lateralStamp")
                                stampCells += 1
                                s -= 0.5
                            }
                        }
                    }
                }

                // Exakte Abbildung von `plugOxbow`: Schreibzelle `k` + 4 Nachbarn `k±1`/`k±nn`.
                for oi in ox0..<state.oxbows.count {
                    let loop = state.oxbows[oi]
                    guard loop.count >= 4 else { continue }
                    oxbowsPlugged += 1
                    for nd in [loop[1], loop[loop.count - 2]] {
                        let ci = min(max(Int(nd.x.rounded()), 1), nn - 2)
                        let cj = min(max(Int(nd.z.rounded()), 1), nn - 2)
                        assertWriteCell(ci, cj, "plugOxbowWrite")
                        assertReadCell(ci, cj, "plugOxbowRead")
                        assertReadCell(ci - 1, cj, "plugOxbowRead-x")
                        assertReadCell(ci + 1, cj, "plugOxbowRead+x")
                        assertReadCell(ci, cj - 1, "plugOxbowRead-z")
                        assertReadCell(ci, cj + 1, "plugOxbowRead+z")
                    }
                }
            }

            XCTAssertGreaterThan(farWallReads, 0, "Talwand-Abfragen bei 3,5·b müssen tatsächlich ausgeführt werden")
            XCTAssertGreaterThan(stampCells, 0, "Seitliche Stempelzellen müssen tatsächlich geprüft werden")
            if expectOxbow {
                XCTAssertGreaterThan(oxbowsPlugged, 0, "Hufeisenschleife muss mindestens einen Altarm für plugOxbow erzeugen")
            }
        }

        for dt in [15.0, 100.0, 1000.0] {
            try verifyChannel(mixedDiagonalLine(), dt: dt, expectSplitHulls: true, expectOxbow: false)
        }
        try verifyChannel(oxbowProneLine(originX: 120, originZ: 200, scale: 1.0), dt: 100.0,
                          expectSplitHulls: true, expectOxbow: true)

        // End-to-End-Gegenprobe auf realem `Terrain` (`beltStamp` + `plugOxbows`):
        // jede tatsächlich veränderte Zelle in h/sed/rock/veg/isChannel/barAge
        // muss in `rw.writeHulls` liegen.
        var smallCfg = SimConfig.production
        smallCfg.n = 160
        let t = Terrain(config: smallCfg, seed: 1337)
        let sn = smallCfg.n, smaxc = Double(sn - 1)
        // Sanfte Ebene oberhalb des Meeresspiegels, damit der Lauf voll mobil stempelt.
        var snap = t.state
        for j in 0..<sn {
            for i in 0..<sn {
                let k = j * sn + i
                let elev = smallCfg.sea + 0.25 - Double(i) * 1e-5
                snap.rock[k] = elev - 0.05
                snap.sed[k] = 0.05
                snap.h[k] = elev
                snap.hf[k] = elev
                snap.veg[k] = 0.8
                snap.isChannel[k] = false
                snap.barAge[k] = -1
            }
        }
        let realCh = oxbowProneLine(originX: 25, originZ: 70, scale: 0.75)
        snap.meanderChannels = [realCh]
        snap.oxbows = []
        snap.oxbowAge = []
        t.restore(snap)
        let realDt = 100.0
        let realFp = try XCTUnwrap(t.meander.beltFootprint(realCh, dt: realDt, config: smallCfg))
        let realRW = Terrain.BeltRWFootprint.build(channel: realCh, dt: realDt, footprint: realFp, config: smallCfg)

        let h0 = t.h, sed0 = t.sed, rock0 = t.rock, veg0 = t.veg
        let chan0 = t.isChannel, age0 = t.barAge

        let plan = t.h.withUnsafeBufferPointer { hb in
            let ph = hb.baseAddress!
            return t.meander.beltMigrationPlan(channel: 0, config: smallCfg,
                                               heightAt: { Terrain.bilinear(ph, sn, $0.x, $0.z) })
        }
        let nsub = max(1, min(4096, Int((plan.rate * realDt / (0.5 * smallCfg.meanderNodeSpacing)).rounded(.up))))
        XCTAssertLessThanOrEqual(nsub, realFp.maxSubsteps)
        let sub = realDt / Double(nsub)
        var geom: BeltGeometry?
        var realOxbows = 0
        for si in 0..<nsub {
            let ageAtEnd = realDt - Double(si + 1) * sub
            let ox0 = t.meander.oxbows.count
            t.h.withUnsafeBufferPointer { hb in
                let ph = hb.baseAddress!
                if si == 0 {
                    t.meander.applyBeltMigrationPlan(0, plan: plan, dt: sub, time: 0, config: smallCfg, noiseChannel: 0)
                } else {
                    t.meander.migrateBeltChannel(0, dt: sub, time: Double(si) * sub, config: smallCfg,
                                                 heightAt: { Terrain.bilinear(ph, sn, $0.x, $0.z) },
                                                 geometry: geom, noiseChannel: 0)
                }
            }
            for oi in ox0..<t.meander.oxbowAge.count { t.meander.oxbowAge[oi] = ageAtEnd }
            t.meander.channels[0].clampToWorld(maxCoord: smaxc)
            let stampDt = smallCfg.meanderBeltSymmetricStamp ? 0.5 * sub : sub
            geom = t.beltStamp(dt: stampDt, only: 0, ageAtEnd: ageAtEnd)
            realOxbows += t.meander.oxbows.count - ox0
            t.plugOxbows(from: ox0)
        }

        var mutatedCells = 0
        for k in 0..<smallCfg.count {
            let changed = t.h[k] != h0[k] || t.sed[k] != sed0[k] || t.rock[k] != rock0[k]
                || t.veg[k] != veg0[k] || t.isChannel[k] != chan0[k] || t.barAge[k] != age0[k]
            if changed {
                mutatedCells += 1
                let ci = k % sn, cj = k / sn
                XCTAssertTrue(realRW.containsWrite(x: Double(ci), z: Double(cj)),
                              "Reale Schreibzelle (\(ci),\(cj)) liegt außerhalb rw.writeHulls")
            }
        }
        XCTAssertGreaterThan(mutatedCells, 0)
        XCTAssertGreaterThan(realOxbows, 0)
    }

    /// Konservative Lauf-Fenster: jede der beiden geklemmten Verschiebungen
    /// trägt höchstens einen halben Knotenabstand bei; Diffusion und Resample
    /// bleiben in der konvexen Hülle. Der Radius enthält auch Talwand-Abfragen,
    /// Stempel und Nachbarn der Altarm-Pfropfen.
    func testBeltOverlapDiagnostic() throws {
        try skipUnlessMeasuring()
        let cfg = SimConfig.production
        let t = Terrain(config: cfg, seed: 1337)
        for _ in 0..<100 { t.step(dtYears: 100) }
        var samples = 0, runs = 0, isolated = 0, pairs = 0, overlaps = 0, levels = 0, slots = 0
        var bounds: [String] = []
        SimProfile.onPassEnd = { pass in
            guard pass == "belt.couple.build" else { return }
            let mobile = t.meander.channels.filter { MeanderState.migrates($0, cfg) }
            let boxes = mobile.map { t.meander.beltFootprint($0, dt: 100, config: cfg)! }
            var conflicts = [Int](repeating: 0, count: boxes.count)
            for j in boxes.indices {
                for i in 0..<j {
                    pairs += 1
                    let a = boxes[i], b = boxes[j]
                    if a.overlaps(b) {
                        overlaps += 1; conflicts[i] += 1; conflicts[j] += 1
                    }
                }
            }
            let groups = MeanderState.beltLevels(boxes)
            let depth = groups.count
            samples += 1; runs += boxes.count; isolated += conflicts.filter { $0 == 0 }.count
            levels += depth
            slots += groups.reduce(0) { $0 + ($1.count > 1 ? $1.count : 0) }
            bounds.append("\(boxes.count)/\(depth)")
        }
        SimProfile.enabled = true
        defer { SimProfile.enabled = false; SimProfile.onPassEnd = nil; SimProfile.reset() }
        for _ in 0..<30 { t.step(dtYears: 100) }
        print("[BELT-OVERLAP] samples=\(samples) runs=\(runs) isolated=\(isolated) overlappingPairs=\(overlaps)/\(pairs) levels=\(levels) parallelSlots=\(slots) runs/levels=\(bounds.joined(separator: ","))")
    }
}
