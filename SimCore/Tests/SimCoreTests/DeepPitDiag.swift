import XCTest
@testable import SimCore

/// Regression „dunkle Stellen": Zellen, die tief unter den Meeresspiegel geraten
/// (obwohl sie anfangs Land/Flachwasser waren) und dann für immer dort bleiben —
/// alle Prozesse (Erosion, Verfüllung, Deposition) überspringen h <= sea, die
/// Unterwasser-Farbrampe rendert sie als dunkle Flecken.
final class DeepPitDiag: XCTestCase {
    private func prodConfig() -> SimConfig {
        var c = SimConfig()
        c.hydraulicSkipWaterSpawns = true
        c.meanderSpatialCutoffIndex = true
        return c
    }

    /// Anzahl der Zellen, die bei t0 flach/Land waren (h0 > sea-0.02) und jetzt
    /// deutlich unter dem Meeresspiegel liegen (h < sea-0.10).
    private func newDeepPits(_ t: Terrain, _ h0: [Double]) -> Int {
        let sea = t.cfg.sea
        var count = 0
        for k in 0..<t.cfg.count where h0[k] > sea - 0.02 && t.h[k] < sea - 0.10 {
            count += 1
        }
        return count
    }

    /// Anzahl der Zellen mit NEU entstandener tiefer Wassersäule (hf−h): ab 0.13
    /// rendert der Shader volles Dunkelblau — das sind die „dunklen Stellen".
    private func newDeepPonds(_ t: Terrain, _ pond0: [Double]) -> Int {
        var count = 0
        for k in 0..<t.cfg.count where t.hf[k] > t.cfg.sea
            && t.hf[k] - t.h[k] > 0.16 && pond0[k] < 0.05 {
            count += 1
        }
        return count
    }


    /// Die reine Simulation (ohne Spieler-Eingriff) darf keine Tiefen-Löcher graben.
    /// Seeds = die „Neues Terrain"-Kette des Spiels (LCG ab 1337).
    func testSimulationCreatesNoDeepPits() {
        var seed = 1337
        for _ in 0..<4 {
            let t = Terrain(config: prodConfig(), seed: UInt32(seed))
            let h0 = t.h
            var pond0 = [Double](repeating: 0, count: t.cfg.count)
            for k in 0..<t.cfg.count { pond0[k] = max(0, t.hf[k] - t.h[k]) }
            var years = 0.0
            while years < 24000 { t.step(dtYears: 240); years += 240 } // wie 60-J/s-Zeitraffer
            XCTAssertEqual(newDeepPits(t, h0), 0, "Sim gräbt dauerhafte Tiefen-Löcher (seed \(seed))")
            XCTAssertEqual(newDeepPonds(t, pond0), 0, "Sim gräbt neue TIEFE Seen (seed \(seed))")
            seed = (seed * 16807 + 1) % 2147483647
        }
    }

    /// Spieler-Absenken darf KEINE ewige Absenkungszone hinterlassen: früher
    /// koppelte sculpt(dir<0) die Tektonik bis −2 — die Kraterränder sanken dann
    /// über Jahrtausende unter den Meeresspiegel (dunkle Flecken, die nie heilen).
    func testSculptLowerLeavesNoEternalSubsidence() {
        let t = Terrain(config: prodConfig(), seed: 1337)
        // Hohe Land-Zelle suchen und dort einen tiefen Krater graben (hält der
        // Spieler „Absenken" ein paar Sekunden, entspricht das ~200 Strichen).
        let sea = t.cfg.sea
        var spot = -1
        for k in 0..<t.cfg.count where t.h[k] > 0.45 { spot = k; break }
        XCTAssertGreaterThanOrEqual(spot, 0)
        let gx = Double(spot % t.cfg.n), gz = Double(spot / t.cfg.n)
        for _ in 0..<200 {
            t.sculpt(gx: gx, gz: gz, radiusWorld: 10.0, dir: -1, strength: 3)
        }
        let h0 = t.h // Referenz NACH dem Graben: nur simulations-getriebenes Absacken zählt
        var years = 0.0
        while years < 18000 { t.step(dtYears: 240); years += 240 }
        XCTAssertEqual(newDeepPits(t, h0), 0,
            "Kraterränder sacken durch Tektonik-Kopplung unter den Meeresspiegel")
    }
}
