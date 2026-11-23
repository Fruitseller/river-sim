import XCTest

@testable import SimCore
@testable import SimRender

final class TimelapseTransitionTests: XCTestCase {

    private func valleyWorld(year: Double) -> Terrain {
        var c = renderConfig(n: 64)
        c.meanderBeltMinCells = 100
        c.meanderBeltAvulsionYears = 0
        let t = Terrain(allocating: c, seed: 1)
        var s = t.state
        let n = c.n
        for j in 0..<n {
            for i in 0..<n {
                s.h[j * n + i] = 0.6 - 0.002 * Double(i) + 0.003 * abs(Double(j) - 30)
            }
        }
        s.hf = s.h
        s.waterLevel = s.h
        s.years = year
        t.restore(s)
        t.computeFlow()
        return t
    }

    private func detourLine(_ t: Terrain) -> RiverChannel {
        var pts: [MeanderNode] = []
        for x in 4...20 { pts.append(MeanderNode(x: Double(x), z: 30)) }
        for z in 31...40 { pts.append(MeanderNode(x: 20.5, z: Double(z))) }
        for x in 21...50 { pts.append(MeanderNode(x: Double(x), z: 40)) }
        for z in stride(from: 39, through: 31, by: -1) { pts.append(MeanderNode(x: 50.5, z: Double(z))) }
        for x in 51...60 { pts.append(MeanderNode(x: Double(x), z: 30)) }
        return t.meander.resampled(RiverChannel(nodes: pts, discharge: Array(repeating: 50_000, count: pts.count)),
                                   config: t.cfg)
    }

    func testCouplingStampsTheBirthYearOnInsertedNodesOnly() {
        let t = valleyWorld(year: 5000)
        t.meander.channels = [detourLine(t)]
        t.coupleBeltForTests(dt: 100)
        XCTAssertEqual(t.meander.avulsions, 1)
        guard let main = t.meander.channels.max(by: { ($0.discharge.last ?? 0) < ($1.discharge.last ?? 0) }) else {
            return XCTFail("kein Lauf")
        }
        XCTAssertFalse(main.born.isEmpty, "die Avulsion hat Knoten eingesetzt")
        for (i, node) in main.nodes.enumerated() {
            if node.x > 5 && node.x < 17 {
                XCTAssertEqual(main.bornAt(i), -.infinity, "übernommener Oberlauf bei x = \(node.x) gilt als neu")
            }
            if node.x > 26 && node.x < 46 {
                XCTAssertEqual(main.bornAt(i), 5000, "eingesetzter Talweg bei x = \(node.x) ohne Geburtsjahr")
            }
        }
    }

    func testBirthYearsResampleWithoutNaNAndStayEmptyWhenMature() {
        let pts = (0..<12).map { MeanderNode(x: Double($0) * 0.7, z: 3) }
        let mature = RiverChannel(nodes: pts, discharge: Array(repeating: 500, count: 12),
                                  born: Array(repeating: -.infinity, count: 12))
        XCTAssertTrue(mature.born.isEmpty)
        XCTAssertEqual(mature.bornAt(5), -.infinity)
        var born = Array(repeating: -Double.infinity, count: 12)
        for i in 4...7 { born[i] = 100 + Double(i) }
        let young = RiverChannel(nodes: pts, discharge: Array(repeating: 500, count: 12), born: born)
        let out = MeanderState().resampled(young, config: renderConfig(n: 64))
        XCTAssertEqual(out.born.count, out.nodes.count)
        XCTAssertFalse(out.born.contains { $0.isNaN }, "NaN in den Geburtsjahren: \(out.born)")
        XCTAssertTrue(out.born.allSatisfy { $0 == -.infinity || (100...107).contains($0) }, "\(out.born)")
        XCTAssertTrue(out.born.contains { $0.isFinite }, "junges Stück ging verloren")
    }

    func testSettledWorldHasNoUnbornRibbonNodes() {
        let t = Terrain(config: .production, seed: RenderContract.defaultSeed,
                        settleYears: SimConfig.productionSettleYears)
        XCTAssertEqual(t.years, 0)
        for (ci, ch) in t.meander.channels.enumerated() {
            for i in ch.nodes.indices where ch.bornAt(i) > t.years - WaterRender.ribbonGrowYears {
                return XCTFail("Lauf \(ci) Knoten \(i): Geburtsjahr \(ch.bornAt(i)) nach dem Einlauf noch nicht ausgewachsen")
            }
        }
    }

    private func agedTerrain() -> Terrain {
        var config = SimConfig()
        config.n = 192
        config.world = calibrationWorld
        config.rangeLandform = calibrationRangeLandform
        config.meanderBelt = calibrationMeanderBelt
        return agedWorld(config, years: 4000)
    }

    private func bandedChannel(_ t: Terrain) -> (index: Int, range: Range<Int>)? {
        let renderer = RiverRibbonRenderer()
        renderer.build(t, hscale: RenderContract.heightScale, lift: RenderContract.riverLift)
        let banded = t.meander.channels.indices.filter {
            renderer.bandChannelFlags[$0] && t.meander.channels[$0].nodes.count >= 30
        }
        guard let ci = banded.max(by: {
            (t.meander.channels[$0].discharge.max() ?? 0) < (t.meander.channels[$1].discharge.max() ?? 0)
        }) else { return nil }
        let c = t.meander.channels[ci].nodes.count
        return (ci, (c / 3)..<(2 * c / 3))
    }

    private func coverage(_ cov: [Double], _ ch: RiverChannel, _ range: Range<Int>, n: Int) -> Double {
        var cells = Set<Int>()
        for i in range {
            let ci = Int(ch.nodes[i].x.rounded()), cj = Int(ch.nodes[i].z.rounded())
            for dj in -1...1 { for di in -1...1 {
                let x = ci + di, z = cj + dj
                if x >= 0, x < n, z >= 0, z < n { cells.insert(z * n + x) }
            }}
        }
        return cells.reduce(0) { $0 + cov[$1] }
    }

    func testInsertedStretchGrowsInOverSimYears() throws {
        let t = agedTerrain()
        let (ci, range) = try XCTUnwrap(bandedChannel(t), "kein Lauf mit Band")
        let n = t.cfg.n
        let base = t.state
        let reference = RiverRibbonRenderer()
        reference.build(t, hscale: RenderContract.heightScale, lift: RenderContract.riverLift)
        let ch0 = t.meander.channels[ci]
        let full = coverage(reference.bandCoverage, ch0, range, n: n)
        XCTAssertGreaterThan(full, 1)

        func grown(age: Double, after previous: RiverRibbonRenderer? = nil) -> (Double, [Double]) {
            t.restore(base)
            var born = Array(repeating: -Double.infinity, count: ch0.nodes.count)
            for i in range { born[i] = t.years - age }
            t.meander.channels[ci].born = born
            let r = previous ?? RiverRibbonRenderer()
            r.build(t, hscale: RenderContract.heightScale, lift: RenderContract.riverLift)
            return (coverage(r.bandCoverage, t.meander.channels[ci], range, n: n), r.bandCoverage)
        }
        let fresh = grown(age: 0).0
        let half = grown(age: 0.5 * WaterRender.ribbonGrowYears).0
        let (done, doneCov) = grown(age: WaterRender.ribbonGrowYears + 1)
        XCTAssertLessThan(fresh, 0.15 * full, "frisch eingesetzt schon fast voll: \(fresh) von \(full)")
        XCTAssertGreaterThan(half, fresh, "wächst nicht")
        XCTAssertLessThan(half, done, "wächst nicht weiter")
        XCTAssertEqual(doneCov, reference.bandCoverage, "ausgewachsen nicht gleich dem Lauf ohne Geburtsjahr")

        t.restore(base)
        let warm = RiverRibbonRenderer()
        warm.build(t, hscale: RenderContract.heightScale, lift: RenderContract.riverLift)
        let (exempt, _) = grown(age: 1, after: warm)
        XCTAssertEqual(exempt, full, accuracy: 0.01 * full, "Nachsetzung im fertigen Fluss schnürt ein")
    }

    func testRemovedRunFadesOutOverSimYears() throws {
        let t = agedTerrain()
        let (ci, range) = try XCTUnwrap(bandedChannel(t), "kein Lauf mit Band")
        let n = t.cfg.n
        let removed = t.meander.channels[ci]
        let base = t.state
        let render = RenderState(geometryMode: true)
        render.invalidate(t, .replaced)
        _ = render.frame(t, .settled, now: 0)
        let before = coverage(render.riverRibbonMesh.bandCoverage, removed, range, n: n)
        XCTAssertGreaterThan(before, 1)

        var s = t.state
        var channels = s.meanderChannels
        channels.remove(at: ci)
        let other = try XCTUnwrap(channels.indices.first { channels[$0].nodes.count > 3 })
        var born = Array(repeating: -Double.infinity, count: channels[other].nodes.count)
        born[0] = s.years
        channels[other].born = born
        s.meanderChannels = channels
        let coupled = s
        t.restore(s)
        render.invalidate(t, .advanced)
        _ = render.frame(t, .settled, now: 10)
        XCTAssertEqual(render.ribbonGhostCount, 1, "kein versiegender Stand nach der Kopplung")
        let ghost = coverage(render.riverRibbonMesh.bandCoverage, removed, range, n: n)
        XCTAssertGreaterThan(ghost, 0.5 * before, "der entfernte Lauf verschwand sofort")

        s.years += 0.5 * WaterRender.ribbonGhostYears
        t.restore(s)
        render.invalidate(t, .advanced)
        _ = render.frame(t, .settled, now: 20)
        let mid = coverage(render.riverRibbonMesh.bandCoverage, removed, range, n: n)
        XCTAssertLessThan(mid, ghost, "versiegt nicht")
        s.years += WaterRender.ribbonGhostYears
        t.restore(s)
        render.invalidate(t, .advanced)
        _ = render.frame(t, .settled, now: 30)
        XCTAssertEqual(render.ribbonGhostCount, 0)
        let fresh = RiverRibbonRenderer()
        fresh.build(t, hscale: RenderContract.heightScale, lift: RenderContract.riverLift)
        XCTAssertEqual(coverage(render.riverRibbonMesh.bandCoverage, removed, range, n: n),
                       coverage(fresh.bandCoverage, removed, range, n: n), accuracy: 1e-9,
                       "nach dem Versiegen bleibt etwas vom alten Lauf stehen")

        let edited = RenderState(geometryMode: true)
        t.restore(base)
        edited.invalidate(t, .replaced)
        _ = edited.frame(t, .settled, now: 0)
        t.restore(coupled)
        edited.invalidate(t, .advanced)
        _ = edited.frame(t, .settled, now: 10)
        XCTAssertEqual(edited.ribbonGhostCount, 1)
        edited.invalidate(t, .edited)
        XCTAssertEqual(edited.ribbonGhostCount, 0, "Pinsel lässt den alten Stand versiegen statt ihn zu zeigen")
    }

    func testForestRetreatsGraduallyUnlessWaterArrives() {
        let target: [UInt8] = [0, 0, 0]
        let wet = WetNow(bandCoverage: [CanopyRender.retreatInstantBandCoverage, 0, 0],
                         waterBytes: [], bandThreshold: CanopyRender.retreatInstantBandCoverage)
        var memory: [Float] = [1, 1, 1]
        let tau = CanopyRender.retreatYears
        let out = ForestCanopyMask.regrow(&memory, toward: target, dtYears: tau,
                                          tau: CanopyRender.regrowYears, wet: wet, retreatTau: tau)
        XCTAssertEqual(out[0], 0, "über Wasser bleibt Wald stehen")
        XCTAssertEqual(Double(memory[1]), exp(-1), accuracy: 1e-6, "Rückzug nicht über τ")
        var once: [Float] = [1, 1, 1], many: [Float] = [1, 1, 1]
        _ = ForestCanopyMask.regrow(&once, toward: target, dtYears: 2 * tau,
                                    tau: CanopyRender.regrowYears, wet: wet, retreatTau: tau)
        for _ in 0..<4 {
            _ = ForestCanopyMask.regrow(&many, toward: target, dtYears: 0.5 * tau,
                                        tau: CanopyRender.regrowYears, wet: wet, retreatTau: tau)
        }
        XCTAssertEqual(Double(once[1]), Double(many[1]), accuracy: 1e-5)
        var plain: [Float] = [1, 1, 1]
        let instant = ForestCanopyMask.regrow(&plain, toward: target, dtYears: 1, tau: CanopyRender.regrowYears)
        XCTAssertEqual(instant, target, "ohne `wet` nicht mehr sofort")
    }
}
