import XCTest
@testable import SimCore

extension MeanderState {
    func beltMaxRate(config: SimConfig, heightAt: (MeanderNode) -> Double) -> Double {
        var m = 0.0
        for ci in channels.indices { m = max(m, beltMaxRate(channel: ci, config: config, heightAt: heightAt)) }
        return m
    }

    func migrateBelt(dt: Double, time: Double, config: SimConfig, heightAt: (MeanderNode) -> Double) {
        for age in oxbowAge.indices { oxbowAge[age] += dt }
        for ci in channels.indices where Self.migrates(channels[ci], config) {
            migrateBeltChannel(ci, dt: dt, time: time, config: config, heightAt: heightAt)
        }
    }
}

final class MeanderBeltTests: XCTestCase {
    private let q = 20_000.0

    private func straightRuns(_ seed: UInt32 = 7, discharges: [Double]? = nil) -> MeanderState {
        let m = MeanderState()
        var rng = Mulberry32(seed: seed)
        for (ri, z0) in [150.0, 360, 570].enumerated() {
            var nodes: [MeanderNode] = []
            for i in 0..<400 { nodes.append(MeanderNode(x: 60 + Double(i) * 1.5, z: z0 + (rng.next() - 0.5) * 0.4)) }
            m.channels.append(RiverChannel(nodes: nodes, discharge: Array(repeating: discharges?[ri] ?? q, count: 400)))
        }
        return m
    }

    private let flat: (MeanderNode) -> Double = { 0.3 - $0.x * 1e-6 }

    static func maxLocalSinuosity(_ ch: RiverChannel, config c: SimConfig) -> Double {
        let nodes = ch.nodes
        guard nodes.count > 2 else { return 1 }
        let b = MeanderState.beltWidthCells(discharge: ch.discharge.max() ?? 0, config: c)
        let m = max(2, Int((c.meanderBeltSinuosityWidths * b / c.meanderNodeSpacing).rounded()))
        var cum = [Double](repeating: 0, count: nodes.count)
        for i in 1..<nodes.count { cum[i] = cum[i - 1] + dist(nodes[i - 1], nodes[i]) }
        var best = 1.0
        for i in stride(from: 0, to: nodes.count - 2 * m, by: max(1, m / 4)) {
            let chord = dist(nodes[i], nodes[i + 2 * m])
            if chord > 1e-9 { best = max(best, (cum[i + 2 * m] - cum[i]) / chord) }
        }
        return best
    }

    static func selfCrossings(_ ch: RiverChannel) -> Int {
        let p = ch.nodes
        guard p.count > 3 else { return 0 }
        func cross(_ a: MeanderNode, _ b: MeanderNode, _ c: MeanderNode) -> Double {
            (b.x - a.x) * (c.z - a.z) - (b.z - a.z) * (c.x - a.x)
        }
        var n = 0
        for i in 0..<(p.count - 1) {
            let a = p[i], b = p[i + 1]
            let (lo, hi) = (min(a.x, b.x), max(a.x, b.x)), (zl, zh) = (min(a.z, b.z), max(a.z, b.z))
            for j in stride(from: i + 2, to: p.count - 1, by: 1) {
                let c = p[j], d = p[j + 1]
                if max(c.x, d.x) < lo || min(c.x, d.x) > hi || max(c.z, d.z) < zl || min(c.z, d.z) > zh { continue }
                if cross(a, b, c) * cross(a, b, d) < 0 && cross(c, d, a) * cross(c, d, b) < 0 { n += 1 }
            }
        }
        return n
    }

    private func run(_ m: MeanderState, years: Double, dt: Double, _ c: SimConfig) {
        var y = 0.0
        while y < years - 1e-9 {
            let step = min(dt, years - y)
            let rate = m.beltMaxRate(config: c, heightAt: flat)
            let nsub = max(1, min(256, Int((rate * step / (0.5 * c.meanderNodeSpacing)).rounded(.up))))
            for si in 0..<nsub { m.migrateBelt(dt: step / Double(nsub), time: y + Double(si) * step / Double(nsub), config: c, heightAt: flat) }
            y += step
        }
    }

    func testKernelSelectsMeanderWavelength() {
        let c = SimConfig.production
        let m = straightRuns()
        run(m, years: 3000, dt: 1000, c)
        let b = MeanderState.beltWidthCells(discharge: q, config: c)
        var lams: [Double] = []
        for ch in m.channels {
            let curv = ZielbildMetrics.smoothedCurvature(ch.nodes, window: max(2, Int((b / c.meanderNodeSpacing).rounded())))
            let lam = ZielbildMetrics.bends(ch.nodes, curv: curv, width: b, minAmplitudeWidths: 0).wavelength
            guard lam > 0 else { continue }
            lams.append(lam / b)
        }
        let mean = lams.reduce(0, +) / Double(max(1, lams.count))
        print(String(format: "[BELT-KERN] λ/b je Lauf %@ Mittel %.1f", lams.map { String(format: "%.1f", $0) }.joined(separator: " "), mean))
        XCTAssertEqual(lams.count, 3, "nicht jeder Lauf hat Bögen gebildet")
        XCTAssertGreaterThan(mean, 7, "Kern wählt zu kurze Wellen (Zacken statt Bögen)")
        XCTAssertLessThan(mean, 16, "Kern wählt zu lange Wellen")
    }

    func testMigrationIsStepSizeInvariant() {
        var c = SimConfig.production
        c.meanderBeltRate = 0.02
        c.meanderBeltKernelWidths = 1.5
        let a = straightRuns(), b = straightRuns()
        run(a, years: 3000, dt: 50, c)
        run(b, years: 3000, dt: 1500, c)
        let w = MeanderState.beltWidthCells(discharge: q, config: c)
        var acc = 0.0, cnt = 0.0, moved = 0.0
        for (ca, cb) in zip(a.channels, b.channels) {
            for p in ca.nodes {
                acc += cb.nodes.map { dist($0, p) }.min()!; cnt += 1
                moved = max(moved, abs(p.z - (ca.nodes.first?.z ?? p.z)))
            }
        }
        let mean = acc / cnt
        print(String(format: "[BELT-DT] mittlerer Abstand dt 50 ↔ 1500 nach 3000 J.: %.3f Zellen (Breite %.1f, größte Auslenkung %.1f)", mean, w, moved))
        XCTAssertGreaterThan(moved, 1, "Testaufbau: nichts ist gewandert")
        XCTAssertLessThan(mean, 0.15 * w, "Gürtel-Migration hängt an der Schrittweite")
    }

    func testSelfCrossingsSeparatesKnotFromOmega() {
        func ch(_ pts: [(Double, Double)]) -> RiverChannel {
            RiverChannel(nodes: pts.map { MeanderNode(x: $0.0, z: $0.1) }, discharge: Array(repeating: q, count: pts.count))
        }
        let omega = ch([(-5, 0), (-1, 0), (-2, 1), (-2, 3), (0, 4), (2, 3), (2, 1), (1, 0), (5, 0)])
        let knot = ch([(-5, 0), (-1, 0), (-2, 1), (-2, 3), (0, 4), (2, 3), (2, 1), (-3, 0.5), (-6, 0.5)])
        XCTAssertEqual(Self.selfCrossings(omega), 0)
        XCTAssertEqual(Self.selfCrossings(knot), 1)
    }

    func testLongRunStaysBoundedWithBothCutoffs() {
        let c = SimConfig.production
        let m = straightRuns(discharges: [q, q, 0.75 * c.meanderChuteMinCells])
        run(m, years: 60_000, dt: 1000, c)
        for ch in m.channels {
            XCTAssertTrue(ch.nodes.allSatisfy { $0.x.isFinite && $0.z.isFinite }, "Knoten nicht endlich")
            let loc = Self.maxLocalSinuosity(ch, config: c)
            XCTAssertEqual(Self.selfCrossings(ch), 0, "Lauf verknäult: Zentrumslinie kreuzt sich selbst")
            XCTAssertLessThan(loc, 10, "Lauf verknäult: örtliche Sinuosität \(loc)")
            XCTAssertGreaterThan(loc, 1.5, "Lauf nach 60.000 Jahren gerade (örtliche Sinuosität \(loc))")
        }
        print("[BELT-LANG] Cutoffs Hals \(m.neckCutoffs), Chute \(m.chuteCutoffs), örtliche Sinuosität \(m.channels.map { String(format: "%.2f", Self.maxLocalSinuosity($0, config: c)) })")
        XCTAssertGreaterThan(m.neckCutoffs, 0, "kein Hals-Cutoff")
        XCTAssertGreaterThan(m.chuteCutoffs, 0, "kein Chute-Cutoff")
    }
}
