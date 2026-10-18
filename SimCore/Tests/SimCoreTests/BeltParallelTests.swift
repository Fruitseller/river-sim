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
        var active: Set<Int> = [], completed: Set<Int> = []
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
