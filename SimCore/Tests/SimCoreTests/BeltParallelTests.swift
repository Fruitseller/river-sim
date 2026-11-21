import Foundation
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
    /// radius-nahe Kanalpaare als auch für knapp über der Disjunktheitsgrenze
    /// liegende parallele Läufe (`part` 0, 1 und 2, mit und ohne `lockHere`).
    /// Zusätzlich prüft der Test deterministisch je Einzellauf, dass alle
    /// geänderten Zellen im berechneten `BeltFootprint` liegen, und belegt über
    /// `BeltStampBatchTrace`, dass der parallele Zweig tatsächlich über mehrere
    /// Arbeiter/Threads lief.
    func testBeltStampBatchParallelMatchesSerialBitIdentically() throws {
        try XCTSkipIf(ProcessInfo.processInfo.activeProcessorCount <= 1,
                      "beltStampBatch fällt bei activeProcessorCount <= 1 in die serielle Schleife")

        var cfg = SimConfig.production
        cfg.n = 192
        cfg.world = SimConfig.production.world * (Double(cfg.n) / Double(SimConfig.production.n))
        let nn = cfg.n, count = cfg.count, maxCoord = Double(nn - 1)

        // Synthetisches Gelände: sanftes Talgefälle mit seitlicher Welligkeit
        // (damit Außenkurven abtragen und Gleithang-Bänke bis `(0.5 + barW)·b`
        // ablagern) sowie eine steile Rampe ab z >= 152 für `part == 2`.
        var h = [Double](repeating: 0, count: count)
        for j in 0..<nn {
            for i in 0..<nn {
                let x = Double(i), z = Double(j)
                let base: Double
                if j >= 152 {
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

        func makeChannelAtLoZ(x0: Double, loZ: Double, amp: Double, freq: Double = 0.18, phase: Double,
                              steps: Int = 70, dx: Double = 1.4, q0: Double = 5000, dq: Double = 90) -> RiverChannel {
            let rawZ = (0..<steps).map { amp * sin(Double($0) * freq + phase) }
            let minRawZ = rawZ.min() ?? 0
            let shiftZ = loZ - minRawZ
            let nodes = (0..<steps).map { i in
                MeanderNode(x: x0 + Double(i) * dx, z: rawZ[i] + shiftZ)
            }
            let q = (0..<steps).map { q0 + Double($0) * dq }
            return RiverChannel(nodes: nodes, discharge: q)
        }
        func hiZ(_ ch: RiverChannel) -> Double { ch.nodes.map(\.z).max() ?? 0 }

        // Exakter Stempel-Radius aus derselben Formel wie `Terrain.beltStampFootprint`:
        // Mit `meanderBarWidths = 0.75` und gekappter Breite `b = 2 · 3.2 = 6.4` Zellen
        // ergibt sich `w = 6.4 · 1.001 ≈ 6.4064` und `flatRadius = (0.5 + 0.75)·w + 2 ≈ 10.008` Zellen
        // (für `part == 2`: `steepRadius = 2.0` Zellen). Zwei horizontale Läufe mit gleichem
        // Radius überlappen in ihren Footprints genau dann, wenn `loZ_b - hiZ_a <= 2 · radius`.
        let sampleMaxQ = 5000.0 + 69.0 * 90.0
        let sampleW = MeanderState.beltWidthCells(discharge: sampleMaxQ, config: cfg) * 1.001
        let flatRadius = max(0.5 * sampleW + 0.5, (0.5 + cfg.meanderBarWidths) * sampleW) + 2.0
        let coreReach = 0.5 * MeanderState.beltWidthCells(discharge: sampleMaxQ, config: cfg) + 0.5
        let steepRadius = 2.0

        // Kanal-Satz, Abstände sichtbar aus `flatRadius` / `steepRadius` abgeleitet:
        // - Paar (0, 1): Abstand `< flatRadius` (`0.4 · flatRadius`), teilen sich direkt
        //   Bett- und Bank-Schreibzellen → `BeltSchedule` muss strikt serialisieren.
        // - Paar (2, 3): Abstand knapp UNTER `2 · flatRadius` (`2 · flatRadius − 1.0`) →
        //   Footprints überlappen um ~1 Zelle → `BeltSchedule` serialisiert 3 nach 2.
        // - Paar (4, 5): Abstand knapp ÜBER `2 · flatRadius` (`2 · flatRadius + 0.5`) →
        //   Footprints sind um 0,5 Zellen disjunkt → laufen gleichzeitig im `BeltSchedule`,
        //   während seitliche Gleithang-Ablagen bis `(0.5 + barW)·b` ins Schreibfenster greifen.
        // - Paar (6, 7) + Lauf (8) (`part == 2`, `steepRadius = 2.0`): (6, 7) knapp unter
        //   `2 · steepRadius` (überlappend), (7, 8) knapp über `2 · steepRadius` (disjunkt).
        let ch0 = makeChannelAtLoZ(x0: 18, loZ: 16.0, amp: 2.5, phase: 0.0, q0: 6500, dq: 120)
        let ch1 = makeChannelAtLoZ(x0: 20, loZ: hiZ(ch0) + 0.4 * flatRadius, amp: 2.5, phase: 0.9, q0: 5500, dq: 110)
        let ch2 = makeChannelAtLoZ(x0: 22, loZ: hiZ(ch1) + 2 * flatRadius + 4.0, amp: 1.5, freq: 0.24, phase: 0.4, q0: 5000, dq: 90)
        let ch3 = makeChannelAtLoZ(x0: 22, loZ: hiZ(ch2) + 2 * flatRadius - 1.0, amp: 1.5, freq: 0.24, phase: 2.1, q0: 5000, dq: 90)
        let ch4 = makeChannelAtLoZ(x0: 24, loZ: hiZ(ch3) + 2 * flatRadius + 4.0, amp: 1.2, freq: 0.30, phase: 1.2, q0: 5000, dq: 90)
        let ch5 = makeChannelAtLoZ(x0: 24, loZ: hiZ(ch4) + 2 * flatRadius + 0.5, amp: 1.2, freq: 0.30, phase: 0.3, q0: 5000, dq: 90)
        let ch6 = makeChannelAtLoZ(x0: 16, loZ: 160.0, amp: 1.0, phase: 0.0, steps: 60, q0: 3200, dq: 50)
        let ch7 = makeChannelAtLoZ(x0: 16, loZ: hiZ(ch6) + 2 * steepRadius - 1.0, amp: 1.0, phase: 0.7, steps: 60, q0: 3200, dq: 50)
        let ch8 = makeChannelAtLoZ(x0: 16, loZ: hiZ(ch7) + 2 * steepRadius + 0.5, amp: 1.0, phase: 0.2, steps: 60, q0: 2800, dq: 40)

        let items: [(ch: RiverChannel, part: Int)] = [
            (ch0, 0), (ch1, 0),
            (ch2, 0), (ch3, 1),
            (ch4, 1), (ch5, 0),
            (ch6, 2), (ch7, 2), (ch8, 2),
        ]

        // Footprint-Beziehungen explizit prüfen (damit der Kanal-Satz garantiert die Grenze trifft):
        let footprints = try items.map { item in
            try XCTUnwrap(Terrain.beltStampFootprint(item.ch, part: item.part, config: cfg, maxCoord: maxCoord))
        }
        XCTAssertTrue(footprints[0].overlaps(footprints[1]), "Paar (0, 1) muss überlappen (gemeinsame Schreibzellen)")
        XCTAssertFalse(footprints[1].overlaps(footprints[2]), "Paar (1, 2) muss disjunkt sein")
        XCTAssertTrue(footprints[2].overlaps(footprints[3]), "Paar (2, 3) muss knapp unter 2·flatRadius überlappen")
        XCTAssertFalse(footprints[3].overlaps(footprints[4]), "Paar (3, 4) muss disjunkt sein")
        XCTAssertFalse(footprints[4].overlaps(footprints[5]), "Paar (4, 5) muss knapp über 2·flatRadius disjunkt sein")
        XCTAssertTrue(footprints[6].overlaps(footprints[7]), "Steiles Paar (6, 7) muss knapp unter 2·steepRadius überlappen")
        XCTAssertFalse(footprints[7].overlaps(footprints[8]), "Steiles Paar (7, 8) muss knapp über 2·steepRadius disjunkt sein")

        // Deterministische Footprint-Prüfung (unabhängig von Thread-Timing): jeden Lauf
        // einzeln von `baseState` stempeln und prüfen, dass JEDE veränderte Zelle innerhalb
        // seines `BeltFootprint` liegt; zusätzlich nachweisen, dass (0, 1) echte gemeinsame
        // Schreibzellen haben und das Grenzpaar (4, 5) seitliche Ablagen über `0.5·b + 0.5`
        // hinaus ins Bank-Fenster `(0.5 + barW)·b` schreibt.
        var touchedPerItem: [Set<Int>] = []
        touchedPerItem.reserveCapacity(items.count)
        var boundaryPairReachedBarZone = false
        for (idx, item) in items.enumerated() {
            let solo = Terrain(config: cfg, seed: 42)
            solo.restore(baseState)
            solo.beltStampBatchForTests([item], dt: 100, ageAtEnd: 0, lockHere: true, serial: true)
            let fp = footprints[idx]
            let inBeltSolo = solo.inBeltForTests()
            let gateSolo = solo.dropletGateForTests()
            var touched: Set<Int> = []
            for k in 0..<count {
                let changed = solo.h[k].bitPattern != baseState.h[k].bitPattern
                    || solo.sed[k].bitPattern != baseState.sed[k].bitPattern
                    || solo.rock[k].bitPattern != baseState.rock[k].bitPattern
                    || solo.veg[k].bitPattern != baseState.veg[k].bitPattern
                    || solo.isChannel[k] != baseState.isChannel[k]
                    || inBeltSolo[k]
                    || solo.barAge[k].bitPattern != baseState.barAge[k].bitPattern
                    || gateSolo[k]
                guard changed else { continue }
                touched.insert(k)
                let cx = Double(k % nn), cz = Double(k / nn)
                XCTAssertTrue(cx >= fp.minX && cx <= fp.maxX && cz >= fp.minZ && cz <= fp.maxZ,
                              "Lauf \(idx): geänderte Zelle (\(Int(cx)), \(Int(cz))) liegt außerhalb des Footprints [\(fp.minX)...\(fp.maxX)] × [\(fp.minZ)...\(fp.maxZ)]")
                if (idx == 4 || idx == 5) && solo.barAge[k] >= 0 {
                    var minDistSq = Double.infinity
                    for p in item.ch.nodes {
                        let dx = cx - p.x, dz = cz - p.z
                        let d2 = dx * dx + dz * dz
                        if d2 < minDistSq { minDistSq = d2 }
                    }
                    if minDistSq.squareRoot() > coreReach {
                        boundaryPairReachedBarZone = true
                    }
                }
            }
            XCTAssertFalse(touched.isEmpty, "Lauf \(idx) muss mindestens eine Zelle verändern")
            touchedPerItem.append(touched)
        }
        XCTAssertFalse(touchedPerItem[0].isDisjoint(with: touchedPerItem[1]),
                       "Paar (0, 1) muss echte gemeinsame Schreibzellen besitzen")
        XCTAssertTrue(boundaryPairReachedBarZone,
                      "Disjunktes Grenzpaar (4, 5) muss seitliche Gleithang-Ablagen jenseits der halben Kanalbreite (0.5·b + 0.5) auslösen")

        // Mehrfache Wiederholung (mit und ohne `lockHere`) für den Bit-Vergleich seriell
        // gegen den parallelen `BeltSchedule`-Pfad; Spur belegt echte Parallelität.
        var peakConcurrent = 0
        var maxWorkerSlots = 0
        var maxDistinctThreads = 0
        for lockHere in [false, true] {
            for round in 0..<4 {
                let serial = Terrain(config: cfg, seed: 42)
                let parallel = Terrain(config: cfg, seed: 42)
                serial.restore(baseState)
                parallel.restore(baseState)

                let ageAtEnd = Double(round) * 12.5
                let serialTrace = serial.beltStampBatchForTests(items, dt: 100, ageAtEnd: ageAtEnd, lockHere: lockHere, serial: true)
                let parallelTrace = parallel.beltStampBatchForTests(items, dt: 100, ageAtEnd: ageAtEnd, lockHere: lockHere, serial: false)

                XCTAssertFalse(serialTrace.usedSchedule, "Serielle Referenz darf BeltSchedule nicht betreten")
                XCTAssertTrue(parallelTrace.usedSchedule, "Paralleler Lauf muss den BeltSchedule-Zweig betreten")
                XCTAssertEqual(parallelTrace.itemsScheduled, items.count, "Alle Läufe müssen über BeltSchedule.take() verteilt werden")
                peakConcurrent = max(peakConcurrent, parallelTrace.maxConcurrent)
                maxWorkerSlots = max(maxWorkerSlots, parallelTrace.workerSlots.count)
                maxDistinctThreads = max(maxDistinctThreads, parallelTrace.threadIds.count)

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
        XCTAssertGreaterThan(maxWorkerSlots, 1, "BeltSchedule muss Arbeit an mehr als einen Arbeiter-Slot verteilen")
        XCTAssertGreaterThan(maxDistinctThreads, 1, "BeltSchedule muss Arbeit an mehr als einen Thread verteilen")
        XCTAssertGreaterThan(peakConcurrent, 1, "Mindestens zwei disjunkte Stempel müssen gleichzeitig gelaufen sein")
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
