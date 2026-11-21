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

    /// Stempel-Charge über den parallelen `BeltSchedule`-Pfad muss bit-identisch
    /// zur seriellen Schleife stempeln — sowohl für eng überlappende und
    /// radius-nahe Kanalpaare als auch für weit getrennte parallele Läufe
    /// (`part` 0, 1 und 2, mit und ohne `lockHere`).
    func testBeltStampBatchParallelMatchesSerialBitIdentically() {
        var cfg = SimConfig.production
        cfg.n = 192
        cfg.world = SimConfig.production.world * (Double(cfg.n) / Double(SimConfig.production.n))
        let nn = cfg.n, count = cfg.count

        // Synthetisches Gelände: sanftes Talgefälle mit seitlicher Welligkeit
        // (damit Außenkurven abtragen und Gleithang-Bänke bis `(0.5 + barW)·w`
        // ablagern) sowie eine steile Rampe ab z >= 150 für `part == 2`.
        var h = [Double](repeating: 0, count: count)
        for j in 0..<nn {
            for i in 0..<nn {
                let x = Double(i), z = Double(j)
                let base: Double
                if j >= 150 {
                    base = 0.85 - x * 0.0045
                } else {
                    base = 0.35 - x * 0.00004 + 0.004 * sin(z * 0.35 + x * 0.07)
                        + 0.0025 * cos(z * 0.19 - x * 0.11)
                }
                h[j * nn + i] = base
            }
        }
        let sed = [Double](repeating: 0.02, count: count)
        let rock = zip(h, sed).map { $0 - $1 }

        let template = Terrain(config: cfg, seed: 42)
        var baseState = template.state
        baseState.h = h
        baseState.sed = sed
        baseState.rock = rock
        baseState.hf = h
        baseState.veg = [Double](repeating: 0.75, count: count)
        baseState.isChannel = [Bool](repeating: false, count: count)
        baseState.barAge = [Double](repeating: -1, count: count)

        func makeChannel(x0: Double, z0: Double, amp: Double, phase: Double,
                         steps: Int = 70, dx: Double = 1.4, q0: Double = 5000, dq: Double = 90) -> RiverChannel {
            let nodes = (0..<steps).map { i in
                MeanderNode(x: x0 + Double(i) * dx, z: z0 + amp * sin(Double(i) * 0.18 + phase))
            }
            let q = (0..<steps).map { q0 + Double($0) * dq }
            return RiverChannel(nodes: nodes, discharge: q)
        }

        // Kanal-Satz:
        // - Paar (0, 1): eng überlappende Mäander (z = 36 vs. z = 40), teilen sich
        //   Schreibzellen und fordern strikte Reihenfolge im `BeltSchedule`.
        // - Paar (2, 3): dicht am Footprint-Radius (z = 74 vs. z = 84), prüfen
        //   Abdeckung des seitlichen Lese-/Schreibfensters `(0.5 + barW)·w + 2`.
        // - Läufe (4, 5): weit getrennt (z = 114 und z = 136), laufen echt parallel.
        // - Paar (6, 7): steile Strecken (`part == 2`, z = 164 vs. z = 165.4),
        //   überlappend innerhalb `radius = 2.0` plus getrennter Lauf (8) bei z = 180.
        let items: [(ch: RiverChannel, part: Int)] = [
            (makeChannel(x0: 18, z0: 36, amp: 5.5, phase: 0.0, q0: 6500, dq: 120), 0),
            (makeChannel(x0: 20, z0: 40, amp: 5.0, phase: 0.9, q0: 5500, dq: 110), 0),
            (makeChannel(x0: 22, z0: 74, amp: 4.5, phase: 0.4, q0: 4800, dq: 90), 0),
            (makeChannel(x0: 22, z0: 84, amp: 4.5, phase: 2.1, q0: 4800, dq: 90), 1),
            (makeChannel(x0: 24, z0: 114, amp: 5.0, phase: 1.2, q0: 6000, dq: 100), 1),
            (makeChannel(x0: 24, z0: 136, amp: 4.0, phase: 0.3, q0: 5200, dq: 80), 0),
            (makeChannel(x0: 16, z0: 164, amp: 1.2, phase: 0.0, steps: 60, q0: 3200, dq: 50), 2),
            (makeChannel(x0: 16, z0: 165.4, amp: 1.2, phase: 0.7, steps: 60, q0: 3200, dq: 50), 2),
            (makeChannel(x0: 16, z0: 180, amp: 1.0, phase: 0.2, steps: 60, q0: 2800, dq: 40), 2),
        ]

        // Mehrfache Wiederholung (mit und ohne `lockHere`) erhöht die Chance,
        // ein echtes Datenrennen bei zu knappem Radius durch Thread-Jitter aufzudecken.
        for lockHere in [false, true] {
            for round in 0..<4 {
                let serial = Terrain(config: cfg, seed: 42)
                let parallel = Terrain(config: cfg, seed: 42)
                serial.restore(baseState)
                parallel.restore(baseState)

                let ageAtEnd = Double(round) * 12.5
                serial.beltStampBatchForTests(items, dt: 100, ageAtEnd: ageAtEnd, lockHere: lockHere, serial: true)
                parallel.beltStampBatchForTests(items, dt: 100, ageAtEnd: ageAtEnd, lockHere: lockHere, serial: false)

                // Gegenprobe gegen leere/unveränderte Puffer: alle Ziel-Felder
                // müssen tatsächlich vom Stempel berührt worden sein.
                if round == 0 {
                    XCTAssertTrue(serial.h.indices.contains { serial.h[$0].bitPattern != baseState.h[$0].bitPattern },
                                  "Stempel muss Höhenfeld verändern")
                    XCTAssertTrue(serial.sed.indices.contains { serial.sed[$0].bitPattern != baseState.sed[$0].bitPattern },
                                  "Stempel muss Sediment verändern")
                    XCTAssertTrue(serial.veg.contains { $0 == 0 }, "Stempel muss Vegetation räumen")
                    XCTAssertTrue(serial.isChannel.contains(true), "Stempel muss isChannel setzen")
                    XCTAssertTrue(serial.inBeltForTests().contains(true), "Stempel muss inBelt setzen")
                    XCTAssertTrue(serial.barAge.contains { $0 >= 0 }, "Stempel muss Gleithang-Bänke ablegen")
                    if lockHere {
                        XCTAssertTrue(serial.dropletGateForTests().contains(true),
                                      "Stempel mit lockHere muss Tropfen-Sperrmaske setzen")
                    }
                }

                XCTAssertEqual(parallel.h.map(\.bitPattern), serial.h.map(\.bitPattern))
                XCTAssertEqual(parallel.sed.map(\.bitPattern), serial.sed.map(\.bitPattern))
                XCTAssertEqual(parallel.rock.map(\.bitPattern), serial.rock.map(\.bitPattern))
                XCTAssertEqual(parallel.hf.map(\.bitPattern), serial.hf.map(\.bitPattern))
                XCTAssertEqual(parallel.veg.map(\.bitPattern), serial.veg.map(\.bitPattern))
                XCTAssertEqual(parallel.isChannel, serial.isChannel)
                XCTAssertEqual(parallel.inBeltForTests(), serial.inBeltForTests())
                XCTAssertEqual(parallel.barAge.map(\.bitPattern), serial.barAge.map(\.bitPattern))
                if lockHere {
                    XCTAssertEqual(parallel.dropletGateForTests(), serial.dropletGateForTests())
                }
            }
        }
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
