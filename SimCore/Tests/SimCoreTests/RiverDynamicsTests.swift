import XCTest
@testable import SimCore

final class RiverDynamicsTests: XCTestCase {

    private func cfg(n: Int) -> SimConfig {
        var c = SimConfig(); c.n = n; c.world = calibrationWorld
        c.rangeLandform = calibrationRangeLandform
        c.meanderBelt = calibrationMeanderBelt
        return c
    }

    private func channelSet(_ t: Terrain, area: [Double], creek: Double = 30) -> Set<Int> {
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        var s = Set<Int>()
        for k in 0..<t.cfg.count where t.hf[k] > t.cfg.sea && t.h[k] > t.cfg.sea {
            if area[k] / cellArea >= creek { s.insert(k) }
        }
        return s
    }

    private func jaccard(_ a: Set<Int>, _ b: Set<Int>) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        let u = a.union(b).count
        return u == 0 ? 1 : Double(a.intersection(b).count) / Double(u)
    }

    func testMFDDeterminism() {
        let a = Terrain(config: cfg(n: 96), seed: 4242)
        let b = Terrain(config: cfg(n: 96), seed: 4242)
        for _ in 0..<5 { a.step(dtYears: 1000); b.step(dtYears: 1000) }
        XCTAssertEqual(a.areaMFD, b.areaMFD, "areaMFD muss deterministisch sein")
    }

    func testMFDCarriesSelf() {
        let t = Terrain(config: cfg(n: 96), seed: 777)
        for k in 0..<t.cfg.count where t.hf[k] > t.cfg.sea {
            XCTAssertGreaterThanOrEqual(t.areaMFD[k], ownContribution(t, k) - 1e-9,
                                        "areaMFD darf nie unter den eigenen Startwert fallen")
        }
    }

    private func ownContribution(_ t: Terrain, _ k: Int) -> Double {
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        let w = t.flowWeight
        return w.isEmpty ? cellArea : cellArea * w[k]
    }

    func testMFDMayUseASlowerRenderCadence() {
        var c = cfg(n: 64)
        c.mfdUpdateInterval = 2
        c.braidingEnabled = false
        let t = Terrain(config: c, seed: 777)
        let before = t.areaMFD

        t.step(dtYears: 1)
        XCTAssertEqual(t.areaMFD, before)

        t.step(dtYears: 1)
        for k in 0..<t.cfg.count where t.hf[k] > t.cfg.sea {
            XCTAssertGreaterThanOrEqual(t.areaMFD[k], ownContribution(t, k) - 1e-9)
        }
    }

    func testSpatialCutoffIndexMatchesReferenceOrder() {
        var reference = cfg(n: 32)
        reference.meanderSmooth = 0
        reference.meanderNodeSpacing = 1
        reference.meanderNeckDist = 2
        var indexed = reference
        indexed.meanderSpatialCutoffIndex = true
        let nodes = [
            MeanderNode(x: 0, z: 0), MeanderNode(x: 1, z: 0),
            MeanderNode(x: 2, z: 0), MeanderNode(x: 3, z: 0),
            MeanderNode(x: 4, z: 0), MeanderNode(x: 4, z: 1),
            MeanderNode(x: 3, z: 1), MeanderNode(x: 1, z: 1),
            MeanderNode(x: 0, z: 1),
        ]
        let channel = RiverChannel(nodes: nodes, discharge: [Double](repeating: 100, count: nodes.count))
        let a = MeanderState(); a.channels = [channel]
        let b = MeanderState(); b.channels = [channel]

        a.migrate(dt: 0, config: reference)
        b.migrate(dt: 0, config: indexed)

        XCTAssertEqual(b.channels[0].nodes, a.channels[0].nodes)
        XCTAssertEqual(b.channels[0].discharge, a.channels[0].discharge)
        XCTAssertEqual(b.oxbows, a.oxbows)
    }

    func testMFDReducesChannelJitter() {
        let t = Terrain(config: cfg(n: 200), seed: 1337)
        while t.years < 10_000 - 1e-6 { t.step(dtYears: 1000) }

        let d8Before = channelSet(t, area: t.area)
        let mfdBefore = channelSet(t, area: t.areaMFD)
        let recBefore = t.snapshotReceivers()
        t.step(dtYears: 100)
        let d8After = channelSet(t, area: t.area)
        let mfdAfter = channelSet(t, area: t.areaMFD)

        let d8J = jaccard(d8Before, d8After)
        let mfdJ = jaccard(mfdBefore, mfdAfter)
        let recChurn = 1 - t.receiverAgreement(with: recBefore)
        print(String(format: "[MFD] Kanal-Jaccard über +100 J.: D8=%.4f  MFD=%.4f  (D8-Empfänger-Churn=%.4f)",
                     d8J, mfdJ, recChurn))
        XCTAssertGreaterThanOrEqual(mfdJ, d8J - 0.02,
                                    "MFD-Kanalkarte darf nicht stärker springen als D8")
    }

    func testMeanderProductionStable() {
        var c = SimConfig(); c.n = 256; c.world = calibrationWorld
        c.rangeLandform = calibrationRangeLandform
        c.meanderBelt = calibrationMeanderBelt
        let t = Terrain(config: c, seed: 1337)
        var everOxbow = false
        var maxSinuEver = 0.0
        var yr = 0
        while yr < 80_000 {
            t.step(dtYears: 1000); yr += 1000
            for ch in t.meander.channels { maxSinuEver = max(maxSinuEver, ch.sinuosity) }
            if !t.meander.oxbows.isEmpty { everOxbow = true }
            XCTAssertLessThan(maxSinuEver, 5.0, "Sinuosität läuft weg (Deckel wirkt nicht): \(maxSinuEver)")
        }
        XCTAssertTrue(everOxbow, "über 80k Jahre entstanden keine Altarme")
        XCTAssertLessThan(t.maxHeight(), 1.0, "Terrain-Runaway unter Mäander")
        XCTAssertGreaterThan(t.landRelief(), 0.30, "Terrain eingeebnet unter Mäander")
    }

    private func bedStats(_ t: Terrain) -> (count: Int, depth: Double, filled: Double) {
        let n = t.cfg.n
        var sum = 0.0, cnt = 0, filled = 0
        for k in 0..<t.cfg.count where t.isChannel[k] && t.h[k] > t.cfg.sea {
            let i = k % n, j = k / n
            if i < 3 || i >= n - 3 || j < 3 || j >= n - 3 { continue }
            var refSum = 0.0, refN = 0
            for dj in -3...3 {
                for di in -3...3 {
                    if max(abs(di), abs(dj)) != 3 { continue }
                    let nb = (j + dj) * n + (i + di)
                    if t.isChannel[nb] || t.h[nb] <= t.cfg.sea { continue }
                    refSum += t.h[nb]; refN += 1
                }
            }
            if refN < 6 { continue }
            let d = refSum / Double(refN) - t.h[k]
            sum += d; cnt += 1
            if d < 0 { filled += 1 }
        }
        return (cnt, cnt == 0 ? 0 : sum / Double(cnt), cnt == 0 ? 0 : Double(filled) / Double(cnt))
    }

    func testChannelBedSurvivesDroplets() {
        var cOn = SimConfig(); cOn.n = 256; cOn.world = calibrationWorld
        cOn.rangeLandform = calibrationRangeLandform
        cOn.meanderBelt = calibrationMeanderBelt
        var cOff = cOn
        cOff.hydraulic.channelDepositDamp = 1.0
        let tOn = Terrain(config: cOn, seed: 1337)
        let tOff = Terrain(config: cOff, seed: 1337)
        var dOn = 0.0, dOff = 0.0, fOn = 0.0, fOff = 0.0, samples = 0.0
        while tOn.years < 20_000 - 1e-6 {
            tOn.step(dtYears: 1000); tOff.step(dtYears: 1000)
            if Int(tOn.years) % 4000 != 0 { continue }
            let a = bedStats(tOn), b = bedStats(tOff)
            dOn += a.depth; fOn += a.filled
            dOff += b.depth; fOff += b.filled
            samples += 1
        }
        dOn /= samples; dOff /= samples; fOn /= samples; fOff /= samples
        print(String(format: "[RECON] Bett-Tiefe an=%+.5f aus=%+.5f | verlandete Betten an=%.1f%% aus=%.1f%%",
                     dOn, dOff, fOn * 100, fOff * 100))
        XCTAssertGreaterThan(dOn, 0.015, "Mäanderbett ist nicht eingetieft — Tropfen füllen es zu")
        XCTAssertGreaterThan(dOn, dOff * 1.20, "Kanalmaske wirkt im Droplet-Pfad nicht")
        XCTAssertLessThan(fOn, fOff * 0.75, "Kopplung verhindert das Zuschütten der Betten nicht")
        XCTAssertLessThan(tOn.maxHeight(), 1.0, "Terrain-Runaway unter der Kanal-Dämpfung")
        XCTAssertGreaterThan(tOn.landRelief(), 0.30, "Terrain eingeebnet unter der Kanal-Dämpfung")
    }

    func testDropletUnchangedWithoutMask() {
        var c = SimConfig(); c.n = 96; c.world = calibrationWorld
        let t = Terrain(config: c, seed: 99)
        var h = t.h, rock = t.rock, sed = t.sed
        var h2 = h, rock2 = rock, sed2 = sed
        var trk = [Double](repeating: 0, count: c.count)
        var trk2 = trk
        Hydraulic.erode(h: &h, rock: &rock, sed: &sed, n: c.n, count: 2000, seed: 7,
                        floor: c.floor, p: c.hydraulic, track: &trk)
        Hydraulic.erode(h: &h2, rock: &rock2, sed: &sed2, n: c.n, count: 2000, seed: 7,
                        floor: c.floor, p: c.hydraulic,
                        channel: [Bool](repeating: false, count: c.count), track: &trk2)
        XCTAssertEqual(h, h2, "leere Maske und all-false-Maske müssen identisch rechnen")
    }

    func testDropletHandlesEdgeCasesAndBufferMismatches() {
        var c = SimConfig(); c.n = 32; c.world = calibrationWorld
        let t = Terrain(config: c, seed: 99)
        var h = t.h, rock = t.rock, sed = t.sed
        let hOrig = h, rockOrig = rock, sedOrig = sed
        var trk = [Double](repeating: 0, count: c.count)

        Hydraulic.erode(h: &h, rock: &rock, sed: &sed, n: c.n, count: 0, seed: 7,
                        floor: c.floor, p: c.hydraulic, track: &trk)
        XCTAssertEqual(h, hOrig)
        Hydraulic.erode(h: &h, rock: &rock, sed: &sed, n: 2, count: 10, seed: 7,
                        floor: c.floor, p: c.hydraulic, track: &trk)
        XCTAssertEqual(h, hOrig)

        var hShort = Array(h.prefix(10))
        Hydraulic.erode(h: &hShort, rock: &rock, sed: &sed, n: c.n, count: 10, seed: 7,
                        floor: c.floor, p: c.hydraulic, track: &trk)
        XCTAssertEqual(hShort, Array(hOrig.prefix(10)))
        XCTAssertEqual(rock, rockOrig)
        XCTAssertEqual(sed, sedOrig)

        for badRadius in [0, -1] {
            var hBadR = hOrig, rockBadR = rockOrig, sedBadR = sedOrig
            var trkBadR = trk
            var pBadR = c.hydraulic
            pBadR.erodeRadius = badRadius
            Hydraulic.erode(h: &hBadR, rock: &rockBadR, sed: &sedBadR, n: c.n, count: 50, seed: 7,
                            floor: c.floor, p: pBadR, track: &trkBadR)
            XCTAssertTrue(hBadR.allSatisfy(\.isFinite), "Erosion mit erodeRadius \(badRadius) muss endlich bleiben")
            XCTAssertTrue(rockBadR.allSatisfy(\.isFinite))
            XCTAssertTrue(sedBadR.allSatisfy(\.isFinite))
        }

        var hMismatched = hOrig, rockMismatched = rockOrig, sedMismatched = sedOrig
        var shortTrack = [Double](repeating: 0, count: 5)
        Hydraulic.erode(h: &hMismatched, rock: &rockMismatched, sed: &sedMismatched, n: c.n, count: 50, seed: 7,
                        floor: c.floor, p: c.hydraulic,
                        hf: [Double](repeating: 1.0, count: 5),
                        receiver: [Int32](repeating: 0, count: c.count),
                        stream: [Double](repeating: 0.5, count: 5),
                        track: &shortTrack)
        XCTAssertTrue(hMismatched.allSatisfy(\.isFinite))
        XCTAssertEqual(shortTrack, [Double](repeating: 0, count: 5), "Mismatched track-Puffer darf nicht modifiziert werden")

        var hLake = hOrig, rockLake = rockOrig, sedLake = sedOrig
        var trkLake = trk
        let badReceiver = [Int32](repeating: Int32(c.count + 100), count: c.count)
        let deepHf = hLake.map { $0 + 1.0 }
        Hydraulic.erode(h: &hLake, rock: &rockLake, sed: &sedLake, n: c.n, count: 50, seed: 7,
                        floor: c.floor, p: c.hydraulic,
                        hf: deepHf, receiver: badReceiver, track: &trkLake)
        XCTAssertTrue(hLake.allSatisfy(\.isFinite))

        var hLakeNoRec = hOrig, rockLakeNoRec = rockOrig, sedLakeNoRec = sedOrig
        var trkLakeNoRec = trk
        Hydraulic.erode(h: &hLakeNoRec, rock: &rockLakeNoRec, sed: &sedLakeNoRec, n: c.n, count: 50, seed: 7,
                        floor: c.floor, p: c.hydraulic,
                        hf: deepHf, receiver: [], track: &trkLakeNoRec)
        XCTAssertTrue(hLakeNoRec.allSatisfy(\.isFinite))
    }

    func testTerrainFlatnessDiagnostic() throws {
        try skipUnlessMeasuring()
        let t = Terrain(config: cfg(n: 256), seed: 1337)
        while t.years < 15_000 - 1e-6 { t.step(dtYears: 1000) }
        let n = t.cfg.n, cs = t.cfg.cellSize
        let flat = 0.02
        @inline(__always) func slope(_ k: Int) -> Double {
            let i = k % n, j = k / n
            if i == 0 || i == n - 1 || j == 0 || j == n - 1 { return .infinity }
            let gx = (t.h[k + 1] - t.h[k - 1]) / (2 * cs)
            let gz = (t.h[k + n] - t.h[k - n]) / (2 * cs)
            return (gx * gx + gz * gz).squareRoot()
        }
        let chan = channelSet(t, area: t.areaMFD)
        XCTAssertGreaterThan(chan.count, 0)
        var lt005 = 0, lt01 = 0, lt02 = 0, lt05 = 0
        for k in chan {
            let s = slope(k)
            if s < 0.005 { lt005 += 1 }
            if s < 0.01 { lt01 += 1 }
            if s < flat { lt02 += 1 }
            if s < 0.05 { lt05 += 1 }
        }
        let c = Double(chan.count)
        print(String(format: "[FLAT] Kanalzellen n=%d | slope<0.005: %.1f%%  <0.01: %.1f%%  <0.02: %.1f%%  <0.05: %.1f%%",
                     chan.count, 100*Double(lt005)/c, 100*Double(lt01)/c, 100*Double(lt02)/c, 100*Double(lt05)/c))
        var flatLand = [Bool](repeating: false, count: n * n)
        var flatCount = 0
        for k in 0..<(n * n) where t.hf[k] > t.cfg.sea && slope(k) < flat {
            flatLand[k] = true; flatCount += 1
        }
        var seen = [Bool](repeating: false, count: n * n)
        var largest = 0
        var stack = [Int]()
        for start in 0..<(n * n) where flatLand[start] && !seen[start] {
            stack.removeAll(keepingCapacity: true); stack.append(start); seen[start] = true
            var size = 0
            while let k = stack.popLast() {
                size += 1
                let i = k % n, j = k / n
                if i > 0 && flatLand[k-1] && !seen[k-1] { seen[k-1] = true; stack.append(k-1) }
                if i < n-1 && flatLand[k+1] && !seen[k+1] { seen[k+1] = true; stack.append(k+1) }
                if j > 0 && flatLand[k-n] && !seen[k-n] { seen[k-n] = true; stack.append(k-n) }
                if j < n-1 && flatLand[k+n] && !seen[k+n] { seen[k+n] = true; stack.append(k+n) }
            }
            largest = max(largest, size)
        }
        let land = t.landCellCount()
        print(String(format: "[FLAT] Flach-Land (slope<0.02): %d von %d Landzellen (%.1f%%), größte zusammenhängende Aue: %d Zellen",
                     flatCount, land, 100*Double(flatCount)/Double(max(1,land)), largest))
    }

    private func braidMetrics(_ t: Terrain, creek: Double = 120)
        -> (islands: Int, barCells: Int, splits: Int) {
        let n = t.cfg.n
        let chan = channelSet(t, area: t.areaMFD, creek: creek)
        var splits = 0
        for k in chan {
            let i = k % n, j = k / n
            var raw = [Double](), tgt = [Int]()
            var sMax = 0.0
            for dj in -1...1 {
                for di in -1...1 {
                    if di == 0 && dj == 0 { continue }
                    let ni = i + di, nj = j + dj
                    if ni < 0 || ni >= n || nj < 0 || nj >= n { continue }
                    let nb = nj * n + ni
                    let dist = (di != 0 && dj != 0) ? 2.0.squareRoot() : 1.0
                    let s = (t.hf[k] - t.hf[nb]) / dist
                    if s > 0 { raw.append(s); tgt.append(nb); sMax = max(sMax, s) }
                }
            }
            let p = t.mfdLocalExponent(k, sMax: sMax)
            var wsum = 0.0
            var w = [Double]()
            for s in raw { w.append(pow(s, p)); wsum += w.last! }
            guard wsum > 0 else { continue }
            var strong = 0
            for x in w.indices where w[x] / wsum >= 0.2 && chan.contains(tgt[x]) { strong += 1 }
            if strong >= 2 { splits += 1 }
        }
        var isChan = [Bool](repeating: false, count: n * n)
        for k in chan { isChan[k] = true }
        var seen = [Bool](repeating: false, count: n * n)
        var islands = 0, barCells = 0
        var stack = [Int]()
        for start in 0..<(n * n) {
            if seen[start] || isChan[start] { continue }
            if t.hf[start] <= t.cfg.sea || t.h[start] <= t.cfg.sea { continue }
            stack.removeAll(keepingCapacity: true); stack.append(start); seen[start] = true
            var size = 0, enclosed = true
            while let k = stack.popLast() {
                size += 1
                if size > 60 { enclosed = false }
                let i = k % n, j = k / n
                for dj in -1...1 {
                    for di in -1...1 {
                        if di == 0 && dj == 0 { continue }
                        let ni = i + di, nj = j + dj
                        if ni < 0 || ni >= n || nj < 0 || nj >= n { enclosed = false; continue }
                        let nb = nj * n + ni
                        if isChan[nb] { continue }
                        if t.hf[nb] <= t.cfg.sea || t.h[nb] <= t.cfg.sea { enclosed = false; continue }
                        if !seen[nb] { seen[nb] = true; stack.append(nb) }
                    }
                }
            }
            if enclosed { islands += 1; barCells += size }
        }
        return (islands, barCells, splits)
    }

    private static let braidSeeds: [UInt32] = [1337, 90210, 7, 42, 2024, 4242,
                                               8675309, 31337, 1, 512, 77, 20250809,
                                               2718, 31415, 65537, 999]

    func testBraidingBuildsBars() {
        var sumBarOn = 0, sumBarOff = 0, sumIslOn = 0, sumIslOff = 0
        var sumSplitsOn = 0, sumSplitsOff = 0
        var seedsFor = 0, seedsAgainst = 0
        var everFormed = false, everClosed = false
        for seed in Self.braidSeeds {
            var cOn = SimConfig(); cOn.n = 256; cOn.world = calibrationWorld
        cOn.rangeLandform = calibrationRangeLandform
        cOn.meanderBelt = calibrationMeanderBelt
            cOn.rangeLandform = calibrationRangeLandform
        cOn.meanderBelt = calibrationMeanderBelt
            cOn.meanderBelt = calibrationMeanderBelt
            cOn.iceFirnTemp = calibrationIceFirnTemp
            cOn.pinIceBeforeAvalanche()
            cOn.endorheicEvaporation = false
            cOn.lithologyEnabled = false
            cOn.channelDiffusionDamp = 1.0
            cOn.flowDepositDamp = 1.0
            var cOff = cOn; cOff.braidingEnabled = false
            let tOn = Terrain(config: cOn, seed: seed)
            let tOff = Terrain(config: cOff, seed: seed)
            var barOn = 0, barOff = 0, islOn = 0, islOff = 0
            var maxSplitsOn = 0, maxSplitsOff = 0, prevIslOn = 0
            while tOn.years < 30_000 - 1e-6 {
                tOn.step(dtYears: 500); tOff.step(dtYears: 500)
                if Int(tOn.years) % 2000 == 0 {
                    let mOn = braidMetrics(tOn), mOff = braidMetrics(tOff)
                    barOn += mOn.barCells; barOff += mOff.barCells
                    islOn += mOn.islands; islOff += mOff.islands
                    maxSplitsOn = max(maxSplitsOn, mOn.splits)
                    maxSplitsOff = max(maxSplitsOff, mOff.splits)
                    if mOn.islands > prevIslOn { everFormed = true }
                    if mOn.islands < prevIslOn { everClosed = true }
                    prevIslOn = mOn.islands
                }
            }
            sumBarOn += barOn; sumBarOff += barOff
            sumIslOn += islOn; sumIslOff += islOff
            sumSplitsOn += maxSplitsOn; sumSplitsOff += maxSplitsOff
            if islOn > islOff { seedsFor += 1 } else if islOn < islOff { seedsAgainst += 1 }
            print("[BRAID] seed \(seed): Bank-Fläche an \(barOn) / aus \(barOff), Inseln an \(islOn) / aus \(islOff), Splits-Max an \(maxSplitsOn) / aus \(maxSplitsOff)")
            XCTAssertLessThan(tOn.maxHeight(), 1.0, "Terrain-Runaway unter Braiding (seed \(seed))")
            XCTAssertGreaterThan(tOn.landReliefRobust(), 0.05,
                                 "Terrain eingeebnet unter Braiding (seed \(seed))")
        }
        print("[BRAID] Summe: Bank-Fläche an=\(sumBarOn) aus=\(sumBarOff), Inseln an=\(sumIslOn) aus=\(sumIslOff), Splits an=\(sumSplitsOn) aus=\(sumSplitsOff), Inseln je Seed dafür \(seedsFor) / dagegen \(seedsAgainst)")
        XCTAssertGreaterThan(sumBarOn, sumBarOff,
                             "Braiding-Pass muss Mittelbank-FLÄCHE bauen")
        XCTAssertGreaterThanOrEqual(seedsFor, seedsAgainst + 3,
                                    "Braiding darf nicht nur auf einzelnen Glücks-Seeds Inseln bauen (dafür \(seedsFor) / dagegen \(seedsAgainst))")
        XCTAssertGreaterThan(sumSplitsOn, sumSplitsOff,
                             "Braiding-Pass muss aktive Verzweigungen erzeugen")
        XCTAssertTrue(everFormed && everClosed,
                      "Bänke müssen entstehen UND wieder verschwinden (transiente Dynamik)")
    }

    func testBasinsDrainToSea() {
        for seed: UInt32 in [1337, 42, 2024] {
            var c = SimConfig(); c.n = 256; c.world = calibrationWorld
            let t = Terrain(config: c, seed: seed)
            let s0 = t.lakeStats()
            var cOff = c; cOff.breachEnabled = false
            let tOff = Terrain(config: cOff, seed: seed)
            let sOff = tOff.lakeStats()
            var minDeepLargest = Int.max
            while t.years < 10_000 - 1e-6 {
                t.step(dtYears: 1000)
                minDeepLargest = min(minDeepLargest, t.lakeStats(depth: 0.03).largest)
                if ProcessInfo.processInfo.environment["RS_BREACH_DEBUG"] != nil {
                    let s = t.lakeStats()
                    let sd = t.lakeStats(depth: 0.03)
                    print(String(format: "[sim] seed %u J%.0f: frac=%.3f largest=%d | tief(>0.03): frac=%.3f largest=%d",
                                 seed, t.years, s.fraction, s.largest, sd.fraction, sd.largest))
                }
            }
            let s1 = t.lakeStats()
            let land = t.landCellCount()
            print(String(format: "[BREACH] seed %u: ohne %.1f%%/%d → t0 %.1f%%/%d → 10k %.1f%%/%d (Land %d)",
                         seed, sOff.fraction*100, sOff.largest,
                         s0.fraction*100, s0.largest, s1.fraction*100, s1.largest, land))
            XCTAssertLessThan(s0.fraction, 0.08, "Becken nicht entwässert (seed \(seed))")
            XCTAssertLessThan(Double(s0.largest), 0.03 * Double(land),
                              "Zentralbecken-See überlebt die Generierung (seed \(seed))")
            XCTAssertLessThan(s1.fraction, 0.16, "Becken laufen wieder voll (seed \(seed))")
            XCTAssertLessThan(Double(minDeepLargest), 0.025 * Double(land),
                              "Tiefer See entwässert nie mehr (seed \(seed), min=\(minDeepLargest))")
        }
    }

    func testStreamMapMarksAndPersists() {
        var c = SimConfig(); c.n = 256; c.world = calibrationWorld
        c.rangeLandform = calibrationRangeLandform
        c.meanderBelt = calibrationMeanderBelt
        let t = Terrain(config: c, seed: 1337)
        func renderedSet() -> (set: Set<Int>, recall: Double) {
            let chan = channelSet(t, area: t.areaMFD, creek: 120)
            var s = Set<Int>()
            for k in chan where t.streamMap[k] > 0.2 { s.insert(k) }
            return (s, chan.isEmpty ? 0 : Double(s.count) / Double(chan.count))
        }
        func strongSmap() -> Set<Int> {
            var s = Set<Int>()
            for k in 0..<t.cfg.count where t.streamMap[k] > 0.2 && t.hf[k] > t.cfg.sea { s.insert(k) }
            return s
        }
        let r0 = renderedSet()
        let sm0 = strongSmap()
        XCTAssertGreaterThan(r0.set.count, 200, "gerendertes Flussnetz nach Spin-up leer")
        t.step(dtYears: 100); t.step(dtYears: 100)
        let jacShort = jaccard(sm0, strongSmap())
        t.step(dtYears: 1000); t.step(dtYears: 1000)
        let r1 = renderedSet()
        let jacLong = jaccard(r0.set, r1.set)
        print(String(format: "[SMAP] gerendert=%d Recall=%.2f→%.2f Jaccard +200J=%.2f +2kJ=%.2f",
                     r0.set.count, r0.recall, r1.recall, jacShort, jacLong))
        XCTAssertGreaterThan(r0.recall, 0.4,
                             "große Läufe sind nicht getrackt (Flüsse hätten Render-Lücken)")
        XCTAssertGreaterThan(r1.recall, 0.4,
                             "Tracking der großen Läufe zerfällt unter Simulation")
        XCTAssertGreaterThan(jacShort, 0.7,
                             "gerendertes Flussnetz SPRINGT auf kurzer Frist")
        XCTAssertGreaterThan(jacLong, 0.25,
                             "Flussnetz nach 2k Jahren ohne jede Verwandtschaft (reines Würfeln)")
    }

    func testMFDAllowsSplits() {
        let t = Terrain(config: cfg(n: 200), seed: 1337)
        while t.years < 10_000 - 1e-6 { t.step(dtYears: 1000) }
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        let n = t.cfg.n
        var splitCapable = 0
        let chan = channelSet(t, area: t.areaMFD)
        for k in chan {
            let i = k % n, j = k / n
            var lower = 0
            for dj in -1...1 {
                for di in -1...1 {
                    if di == 0 && dj == 0 { continue }
                    let ni = i + di, nj = j + dj
                    if ni < 0 || ni >= n || nj < 0 || nj >= n { continue }
                    if t.hf[nj * n + ni] < t.hf[k] { lower += 1 }
                }
            }
            if lower >= 2 { splitCapable += 1 }
        }
        print(String(format: "[MFD] aufspalt-fähige Kanalzellen (≥2 tiefere Nachbarn): %d von %d Kanalzellen (cellArea=%.4f)",
                     splitCapable, chan.count, cellArea))
        XCTAssertGreaterThan(splitCapable, 0,
                             "MFD muss strukturell Aufspaltungen zulassen (D8 kann das nie)")
    }

    func testMeanderClampToWorldHandlesNonFiniteAndBounds() {
        var channel = RiverChannel(
            nodes: [
                MeanderNode(x: Double.nan, z: -10),
                MeanderNode(x: 5, z: 25),
                MeanderNode(x: Double.infinity, z: -Double.infinity),
            ],
            discharge: [10, 20, 30]
        )
        channel.clampToWorld(maxCoord: 20)
        XCTAssertEqual(channel.nodes[0].x, 0)
        XCTAssertEqual(channel.nodes[0].z, 0)
        XCTAssertEqual(channel.nodes[1].x, 5)
        XCTAssertEqual(channel.nodes[1].z, 20)
        XCTAssertEqual(channel.nodes[2].x, 20)
        XCTAssertEqual(channel.nodes[2].z, 0)

        let before = channel.nodes
        channel.clampToWorld(maxCoord: -5)
        XCTAssertEqual(channel.nodes, before)
        channel.clampToWorld(maxCoord: Double.nan)
        XCTAssertEqual(channel.nodes, before)
    }

    func testMeanderPruneOxbowsHandlesMismatchedLengths() {
        let state = MeanderState()
        state.oxbows = [
            [MeanderNode(x: 1, z: 1), MeanderNode(x: 2, z: 2)],
            [MeanderNode(x: 3, z: 3), MeanderNode(x: 4, z: 4)],
            [MeanderNode(x: 5, z: 5), MeanderNode(x: 6, z: 6)],
        ]
        state.oxbowAge = [50.0]
        state.pruneOxbows(maxAge: 100.0)
        XCTAssertEqual(state.oxbows.count, 1)
        XCTAssertEqual(state.oxbowAge.count, 1)
        XCTAssertEqual(state.oxbowAge[0], 50.0)
    }

    func testMeanderTraceChannelsHandlesOutOfBoundsAndInvalidInputs() {
        let c = cfg(n: 4)
        let count = 4 * 4
        let h = [Double](repeating: 0.5, count: count)
        let hf = [Double](repeating: 0.5, count: count)
        let area = [Double](repeating: 200_000.0, count: count)

        var badReceiver = [Int32](repeating: 999_999, count: count)
        badReceiver[0] = 1
        badReceiver[1] = 2
        badReceiver[count - 1] = -1
        let chOutOfBounds = MeanderState.traceChannels(
            config: c, h: h, hf: hf, area: area, receiver: badReceiver
        )
        XCTAssertEqual(chOutOfBounds.count, 1)

        let chMismatched = MeanderState.traceChannels(
            config: c, h: [0.1], hf: hf, area: area, receiver: badReceiver
        )
        XCTAssertTrue(chMismatched.isEmpty)

        var zeroConfig = c
        zeroConfig.world = 0
        XCTAssertTrue(MeanderState.traceChannels(
            config: zeroConfig, h: h, hf: hf, area: area, receiver: badReceiver
        ).isEmpty)

        var nanConfig = c
        nanConfig.meanderMinCells = Double.nan
        XCTAssertTrue(MeanderState.traceChannels(
            config: nanConfig, h: h, hf: hf, area: area, receiver: badReceiver
        ).isEmpty)

        var overflowConfig = c
        overflowConfig.n = Int.max
        XCTAssertTrue(MeanderState.traceChannels(
            config: overflowConfig, h: h, hf: hf, area: area, receiver: badReceiver
        ).isEmpty)
    }

    func testMeanderSpatialCutoffAndResampleHandleNonFiniteCoordinates() {
        let c = cfg(n: 16)
        let badNodes = [
            MeanderNode(x: Double.nan, z: 0),
            MeanderNode(x: 1, z: 1),
            MeanderNode(x: 2, z: 2),
            MeanderNode(x: Double.infinity, z: 3),
        ]
        let channel = RiverChannel(nodes: badNodes, discharge: [10, 20, 30, 40])
        let state = MeanderState()
        state.channels = [channel]

        var indexedConfig = c
        indexedConfig.meanderSpatialCutoffIndex = true
        state.migrate(dt: 10, config: indexedConfig)
        XCTAssertFalse(state.channels.isEmpty)

        var extremeConfig = indexedConfig
        extremeConfig.meanderNeckDist = 1e-300
        extremeConfig.meanderNodeSpacing = 1e-320
        state.migrate(dt: 10, config: extremeConfig)

        var nanSpacingConfig = indexedConfig
        nanSpacingConfig.meanderNodeSpacing = Double.nan
        state.migrate(dt: 10, config: nanSpacingConfig)
    }
}
