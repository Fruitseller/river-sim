import XCTest
@testable import SimCore
@testable import SimRender

/// Wächter zum Befund des Eigners 2026-10-18 (Messreihe
/// `docs/zielbild-measurements.md` § Durchgehende Flüsse): ein Fluss, der
/// sichtbar weiterfließt, reißt nicht ab, und ein Zubringer endet im
/// Hauptlauf statt als Keil davor. Kunstwelt statt gealterter Welt: welche
/// Abzweige eine gealterte Welt trägt, hängt an der System-libm (auf dem
/// Linux-Runner trugen die Testwelten keinen, der Wächter prüfte dort nichts).
final class RiverContinuityTests: XCTestCase {

    /// V-Tal entlang Zeile 30, Gefälle nach Osten (wie `BeltCoupling`), ab
    /// x = 58 Meer. Die Render-Schwelle so, dass das Abfluss-Vertrauen bis zur
    /// Küste nicht greift (3 × 950 Zellen über dem Abfluss an der Küste, rund
    /// 2.700): ohne Abzweig malt das Raster das Tal nicht.
    private func valleyWorld() -> Terrain {
        var c = renderConfig(n: 64)
        c.renderMinCells = 950
        let t = Terrain(allocating: c, seed: 1)
        var s = t.state
        let n = c.n
        for j in 0..<n {
            for i in 0..<n {
                s.h[j * n + i] = i >= 58 ? 0.1 : 0.6 - 0.002 * Double(i) + 0.003 * abs(Double(j) - 30)
            }
        }
        s.hf = s.h
        s.waterLevel = s.h
        t.restore(s)
        t.computeFlow()
        return t
    }

    /// Lauf A folgt dem Tal bis x = 27 und biegt dann nach Zeile 40 ab (die
    /// Linie von gestern); der D8-Lauf fließt im Tal weiter bis ins Meer.
    /// `returns`: die Linie kehrt bei x = 50 ins Tal zurück (Abkürzung über
    /// die Bank).
    private func rasterAlongValley(returns: Bool) -> (water: [UInt8], terrain: Terrain) {
        let t = valleyWorld()
        let n = t.cfg.n
        var line: [MeanderNode] = (4...27).map { MeanderNode(x: Double($0), z: 30) }
        line += (31...40).map { MeanderNode(x: 27.5, z: Double($0)) }
        if returns {
            line += (28...49).map { MeanderNode(x: Double($0), z: 40) }
            line += stride(from: 39, through: 31, by: -1).map { MeanderNode(x: 49.5, z: Double($0)) }
            line += (50...56).map { MeanderNode(x: Double($0), z: 30) }
        } else {
            line += (28...56).map { MeanderNode(x: Double($0), z: 40) }
        }
        t.meander.channels = [RiverChannel(nodes: line, discharge: Array(repeating: 50_000, count: line.count))]
        var cov = [Double](repeating: 0, count: n * n), own = [Int32](repeating: -1, count: n * n)
        for p in line {
            let x = Int(p.x.rounded()), z = Int(p.z.rounded())
            for j in max(0, z - 2)...min(n - 1, z + 2) {
                for i in max(0, x - 2)...min(n - 1, x + 2) { cov[j * n + i] = 1; own[j * n + i] = 0 }
            }
        }
        let water = WaterFieldRenderer().bytes(t, blend: 1, geometryMode: true,
                                               bandChannelFlags: [true], bandCoverage: cov,
                                               bandOwner: own, deferTail: true)
        return (water, t)
    }

    /// Verlässt der D8-Lauf ein Band und kehrt nicht zu ihm zurück, ist er
    /// bis ins Meer Wasser. Vorher malte dort niemand: das Vertrauen schweigt
    /// unter dem dreifachen Referenz-Abfluss, die Kette hat unter dem Band
    /// keine Quelle.
    func testDepartureIsWaterAllTheWayToTheSea() {
        let (water, t) = rasterAlongValley(returns: false)
        let n = t.cfg.n
        let dry = (31...57).filter { water[(30 * n + $0) * 4] < byte01(WaterRender.riverMaskLo) }
        XCTAssertEqual(dry, [], "Abzweig ohne Wasser bei x = \(dry)")
    }

    /// Kehrt der D8-Lauf zum SELBEN Band zurück, ist er die Abkürzung über die
    /// Bank: dort malt das Band den Fluss, das Raster nicht.
    func testShortcutBackToTheSameBandStaysDry() {
        let (water, t) = rasterAlongValley(returns: true)
        let n = t.cfg.n
        let wet = (31...46).filter { water[(30 * n + $0) * 4] >= byte01(WaterRender.riverMaskLo) }
        XCTAssertEqual(wet, [], "Abkürzung als Raster-Fluss bei x = \(wet)")
    }

    /// Ein Lauf, der vor dem Band eines größeren endet, folgt seinem
    /// D8-Empfänger bis in dieses Band; ohne Band in Reichweite läuft er aus.
    func testTributaryEndFollowsItsReceiverIntoTheMainBand() throws {
        let t = valleyWorld()
        let n = t.cfg.n
        var cov = [Double](repeating: 0, count: n * n)
        for j in 0..<n { for i in 30...34 { cov[j * n + i] = 1 } }   // Hauptlauf quer bei x = 30…34
        let path = try XCTUnwrap(RiverRibbonRenderer.joinPath(fromX: 25, fromZ: 30, coverage: cov, terrain: t),
                                 "Zubringer findet den Hauptlauf 5 Zellen stromab nicht")
        XCTAssertEqual(path.last.map { Int($0.x) }, 30, "endet nicht am Ufer des Hauptlaufs: \(path)")
        XCTAssertNil(RiverRibbonRenderer.joinPath(fromX: 10, fromZ: 30, coverage: cov, terrain: t),
                     "Hauptlauf 20 Zellen entfernt gilt als erreichbar")
        XCTAssertEqual(RiverRibbonRenderer.joinPath(fromX: 31, fromZ: 30, coverage: cov, terrain: t)?.count, 0)
    }
}
