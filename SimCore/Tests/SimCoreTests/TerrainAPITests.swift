import XCTest
@testable import SimCore

final class TerrainAPITests: XCTestCase {

    private func cfg(n: Int = 96) -> SimConfig { renderConfig(n: n) }

    func testGenerateIsDeterministicPerSeed() {
        let c = cfg()
        let a = Terrain(config: c, seed: 1337)
        let b = Terrain(config: c, seed: 1337)
        let other = Terrain(config: c, seed: 7)

        for (name, x, y) in [("h", a.h, b.h), ("hf", a.hf, b.hf), ("area", a.area, b.area),
                             ("veg", a.veg, b.veg), ("snow", a.snow, b.snow),
                             ("streamMap", a.streamMap, b.streamMap)] {
            XCTAssertEqual(x.count, y.count, "\(name): Feldlänge")
            for k in x.indices where x[k].bitPattern != y[k].bitPattern {
                XCTFail("\(name)[\(k)]: gleicher Seed, \(y[k]) statt \(x[k])")
                break
            }
        }
        XCTAssertNotEqual(a.h, other.h, "verschiedene Seeds → gleiche Insel")
    }

    func testGenerateResetsAnAgedTerrain() {
        let c = cfg()
        let reused = Terrain(config: c, seed: 1337)
        for _ in 0..<4 { reused.step(dtYears: 500) }
        reused.generate(seed: 7)

        let fresh = Terrain(config: c, seed: 7)
        XCTAssertEqual(reused.years, 0, "Jahreszähler nicht zurückgesetzt")
        XCTAssertEqual(reused.h, fresh.h, "Höhenfeld hängt am Vorleben des Terrains")
        XCTAssertEqual(reused.rock, fresh.rock, "Fels hängt am Vorleben des Terrains")
        XCTAssertEqual(reused.sed, fresh.sed, "Sediment hängt am Vorleben des Terrains")
        XCTAssertEqual(reused.hf, fresh.hf, "Füllstand hängt am Vorleben des Terrains")
        XCTAssertEqual(reused.rain, fresh.rain, "Regen hängt am Vorleben des Terrains")
        XCTAssertEqual(reused.upliftBase, fresh.upliftBase, "Tektonik hängt am Vorleben")
        XCTAssertEqual(reused.streamMap, fresh.streamMap, "Stream-Map hängt am Vorleben")
    }

    func testGenerateProducesAFiniteIsland() {
        let c = cfg()
        for seed: UInt32 in [1, 1337, 4242] {
            let t = Terrain(config: c, seed: seed)
            XCTAssertEqual(t.h.count, c.count, "Seed \(seed): Feldlänge")
            XCTAssertEqual(t.hf.count, c.count, "Seed \(seed): Feldlänge hf")
            var land = 0
            for k in 0..<c.count {
                XCTAssertTrue(t.h[k].isFinite, "Seed \(seed): h[\(k)] nicht endlich")
                XCTAssertGreaterThanOrEqual(t.h[k], c.floor, "Seed \(seed): h[\(k)] unter dem Boden")
                XCTAssertLessThanOrEqual(t.h[k], 1.4, "Seed \(seed): h[\(k)] über der Decke")
                XCTAssertGreaterThanOrEqual(t.hf[k], t.h[k] - 1e-12,
                                            "Seed \(seed): Füllstand unter Gelände bei \(k)")
                if t.h[k] > c.sea { land += 1 }
            }
            let landFraction = Double(land) / Double(c.count)
            XCTAssertGreaterThan(landFraction, 0.05, "Seed \(seed): kein Land (\(landFraction))")
            XCTAssertLessThan(landFraction, 0.95, "Seed \(seed): kein Meer (\(landFraction))")
            XCTAssertGreaterThan(t.landRelief(), 0.1, "Seed \(seed): Insel ohne Relief")
        }
    }

    func testSmoothFlattensInsideTheBrushOnly() {
        let c = cfg()
        let t = Terrain(config: c, seed: 1337)
        let before = t.h
        let gx = Double(c.n / 2), gz = Double(c.n / 2), radius = 12.0

        let roughBefore = roughness(t.h, center: (gx, gz), radiusWorld: radius, cfg: c)
        t.smooth(gx: gx, gz: gz, radiusWorld: radius, strength: 1.0)
        let roughAfter = roughness(t.h, center: (gx, gz), radiusWorld: radius, cfg: c)

        XCTAssertLessThan(roughAfter, roughBefore,
                          "Glätten hat die Zerklüftung nicht gesenkt (\(roughBefore) → \(roughAfter))")
        assertUntouchedOutside(t.h, before: before, center: (gx, gz), radiusWorld: radius, cfg: c)

        let cells = brushCells(center: (gx, gz), radiusWorld: radius, cfg: c)
        let loBefore = cells.map { before[$0] }.min()!, hiBefore = cells.map { before[$0] }.max()!
        for k in cells {
            XCTAssertGreaterThanOrEqual(t.h[k], loBefore - 1e-12, "neues Minimum bei \(k)")
            XCTAssertLessThanOrEqual(t.h[k], hiBefore + 1e-12, "neues Maximum bei \(k)")
        }
    }

    func testSmoothWithZeroStrengthChangesNothing() {
        let c = cfg()
        let t = Terrain(config: c, seed: 1337)
        let before = t.h
        t.smooth(gx: 40, gz: 40, radiusWorld: 12, strength: 0)
        XCTAssertEqual(t.h, before, "Glätten mit Stärke 0 hat das Gelände verändert")
    }

    func testRoughenImprintsSignedNoiseInsideTheBrushOnly() {
        let c = cfg()
        let t = Terrain(config: c, seed: 1337)
        let before = t.h
        let gx = Double(c.n / 2), gz = Double(c.n / 2), radius = 12.0, strength = 1.0

        t.roughen(gx: gx, gz: gz, radiusWorld: radius, strength: strength)

        var up = 0, down = 0
        for k in brushCells(center: (gx, gz), radiusWorld: radius, cfg: c) {
            let d = t.h[k] - before[k]
            XCTAssertNotEqual(d, 0, "Zelle \(k) im Pinsel unberührt")
            XCTAssertLessThanOrEqual(abs(d), 0.005 * strength + 1e-12,
                                     "Zelle \(k) über die Amplitude hinaus bewegt (\(d))")
            if d > 0 { up += 1 } else { down += 1 }
        }
        XCTAssertGreaterThan(up, 0, "nur abgesenkt statt aufgeraut")
        XCTAssertGreaterThan(down, 0, "nur angehoben statt aufgeraut")
        assertUntouchedOutside(t.h, before: before, center: (gx, gz), radiusWorld: radius, cfg: c)
    }

    func testRoughenRepeatsTheSamePattern() {
        let c = cfg()
        let t = Terrain(config: c, seed: 1337)
        let gx = Double(c.n / 2), gz = Double(c.n / 2), radius = 12.0

        let h0 = t.h
        t.roughen(gx: gx, gz: gz, radiusWorld: radius, strength: 1.0)
        let h1 = t.h
        t.roughen(gx: gx, gz: gz, radiusWorld: radius, strength: 1.0)

        var touched = 0
        for k in brushCells(center: (gx, gz), radiusWorld: radius, cfg: c) {
            let d1 = h1[k] - h0[k], d2 = t.h[k] - h1[k]
            if d1 != 0 { touched += 1 }
            XCTAssertEqual(d2, d1, accuracy: 1e-15,
                           "zweiter Strich trägt bei \(k) etwas anderes ein (\(d1) vs \(d2))")
        }
        XCTAssertGreaterThan(touched, 0, "der Pinsel hat gar nichts verändert")

        let twin = Terrain(config: c, seed: 1337)
        twin.roughen(gx: gx, gz: gz, radiusWorld: radius, strength: 1.0)
        XCTAssertEqual(twin.h, h1, "Aufrauen ist nicht reproduzierbar")
    }

    func testUpliftDecayRateFollowsTheClosedForm() {
        var c = cfg(n: 48)
        c.hydraulicEnabled = false
        let t = Terrain(config: c, seed: 4242)
        let u0 = c.upliftDecayStartPer100y, uFloor = c.upliftDecayFloorPer100y
        let tau = c.upliftDecayYears

        XCTAssertEqual(t.upliftDecayRatePer100y(), u0, accuracy: 1e-15,
                       "die frische Welt startet nicht bei U₀")
        var prev = t.upliftDecayRatePer100y()
        while t.years < 4 * tau {
            t.step(dtYears: 10_000)
            let expected = uFloor + (u0 - uFloor) * exp(-t.years / tau)
            let rate = t.upliftDecayRatePer100y()
            XCTAssertEqual(rate, expected, accuracy: u0 * 1e-12,
                           "Jahr \(t.years): \(rate) statt \(expected)")
            XCTAssertLessThan(rate, prev, "Jahr \(t.years): Rate steigt")
            XCTAssertGreaterThan(rate, uFloor, "Jahr \(t.years): unter die Untergrenze gefallen")
            prev = rate
        }
        XCTAssertLessThan(prev - uFloor, (u0 - uFloor) * 0.02,
                          "nach 4 τ noch \(prev) statt ~\(uFloor)")
    }

    func testUpliftDecayRateWithoutTimeConstantStaysAtStart() {
        var c = cfg(n: 48)
        c.hydraulicEnabled = false
        c.upliftDecayYears = 0
        let t = Terrain(config: c, seed: 4242)
        XCTAssertEqual(t.upliftDecayRatePer100y(), c.upliftDecayStartPer100y)
        t.step(dtYears: 10_000)
        XCTAssertEqual(t.upliftDecayRatePer100y(), c.upliftDecayStartPer100y,
                       "ohne τ klingt die Hebung trotzdem ab")
    }

    func testUpliftDecayRateBracketsTheIntegratedAmount() {
        var c = cfg(n: 48)
        c.hydraulicEnabled = false
        let t = Terrain(config: c, seed: 4242)
        let tau = c.upliftDecayYears
        for span in [100.0, 10_000.0, 40_000.0] {
            let rateStart = t.upliftDecayRatePer100y()
            let mean = t.upliftDecayAmount(dt: span) / span * 100
            let rateEnd = c.upliftDecayFloorPer100y
                + (c.upliftDecayStartPer100y - c.upliftDecayFloorPer100y)
                * exp(-(t.years + span) / tau)
            XCTAssertLessThan(mean, rateStart, "Mittel über \(span) J. über der Startrate")
            XCTAssertGreaterThan(mean, rateEnd, "Mittel über \(span) J. unter der Endrate")
            t.step(dtYears: span)
        }
    }

    func testStepWithNonPositiveOrNonFiniteDtIsNoOp() {
        let t = Terrain(config: cfg(n: 16), seed: 1337)
        let stateBefore = t.fingerprint()
        let yearsBefore = t.years

        for badDt in [0.0, -0.0, -1.0, -500.0, Double.nan, Double.infinity, -Double.infinity] {
            t.step(dtYears: badDt)
            XCTAssertEqual(t.years, yearsBefore, "dt = \(badDt) darf die Simulationszeit nicht verändern")
            XCTAssertEqual(t.fingerprint(), stateBefore, "dt = \(badDt) muss strikter No-op sein")
        }
    }

    func testDropletErodeHandlesNonFiniteValuesSafely() {
        let c = cfg(n: 16)
        let t = Terrain(config: c, seed: 1337)
        let h = t.h, rock = t.rock, sed = t.sed
        var trk = [Double](repeating: 0, count: c.count)

        for badFloor in [Double.nan, .infinity, -.infinity] {
            var hCopy = h, rockCopy = rock, sedCopy = sed
            Hydraulic.erode(h: &hCopy, rock: &rockCopy, sed: &sedCopy, n: c.n, count: 50, seed: 7,
                            floor: badFloor, p: c.hydraulic, track: &trk)
            XCTAssertEqual(hCopy, h, "Nicht-endlicher floor darf das Terrain nicht verändern")
        }

        for badSea in [Double.nan, .infinity, -.infinity] {
            var hCopy = h, rockCopy = rock, sedCopy = sed
            Hydraulic.erode(h: &hCopy, rock: &rockCopy, sed: &sedCopy, n: c.n, count: 50, seed: 7,
                            floor: c.floor, p: c.hydraulic, seaLevel: badSea, track: &trk)
            XCTAssertEqual(hCopy, h, "Nicht-endliches seaLevel darf das Terrain nicht verändern")
        }

        let nanIdx = c.n / 2 * c.n + c.n / 2
        var hWithNaN = h
        hWithNaN[nanIdx] = .nan
        var rockNaN = rock, sedNaN = sed
        Hydraulic.erode(h: &hWithNaN, rock: &rockNaN, sed: &sedNaN, n: c.n, count: 100, seed: 7,
                        floor: c.floor, p: c.hydraulic, track: &trk)
        XCTAssertFalse(hWithNaN.enumerated().contains { $0.offset != nanIdx && !$0.element.isFinite },
                       "NaN im Höhenfeld darf nicht auf benachbarte Zellen streuen")
        XCTAssertTrue(rockNaN.allSatisfy(\.isFinite), "Rock-Feld muss endlich bleiben")
        XCTAssertTrue(sedNaN.allSatisfy(\.isFinite), "Sediment-Feld muss endlich bleiben")

        var pBad = c.hydraulic
        pBad.inertia = .nan
        var hInertia = h, rockInertia = rock, sedInertia = sed
        Hydraulic.erode(h: &hInertia, rock: &rockInertia, sed: &sedInertia, n: c.n, count: 50, seed: 7,
                        floor: c.floor, p: pBad, track: &trk)
        XCTAssertEqual(hInertia, h, "Nicht-endliche Parameter dürfen das Höhenfeld nicht verändern")
        XCTAssertEqual(rockInertia, rock, "Nicht-endliche Parameter dürfen das Gesteinsfeld nicht verändern")
        XCTAssertEqual(sedInertia, sed, "Nicht-endliche Parameter dürfen das Sedimentfeld nicht verändern")

        var pDeposit = c.hydraulic
        pDeposit.depositRate = .nan
        var hDeposit = h, rockDeposit = rock, sedDeposit = sed
        Hydraulic.erode(h: &hDeposit, rock: &rockDeposit, sed: &sedDeposit, n: c.n, count: 50, seed: 7,
                        floor: c.floor, p: pDeposit, track: &trk)
        XCTAssertEqual(hDeposit, h, "Nicht-endlicher depositRate darf das Höhenfeld nicht verändern")
        XCTAssertEqual(rockDeposit, rock, "Nicht-endlicher depositRate darf das Gesteinsfeld nicht verändern")
        XCTAssertEqual(sedDeposit, sed, "Nicht-endlicher depositRate darf das Sedimentfeld nicht verändern")
    }

    func testRecomputeFlowAfterEditMatchesTheHandWrittenSequence() {
        let c = cfg()
        let auto = Terrain(config: c, seed: 1337)
        let byHand = Terrain(config: c, seed: 1337)
        for t in [auto, byHand] {
            t.step(dtYears: 500)
            t.sculpt(gx: 48, gz: 48, radiusWorld: 12, dir: 1, strength: 20)
        }
        XCTAssertEqual(auto.fingerprint(), byHand.fingerprint(),
                       "Vorbedingung: beide Welten stehen gleich")

        auto.recomputeFlowAfterEdit()
        byHand.computeFlow()
        byHand.snapWaterLevel()
        byHand.updateClimate(dt: 0)
        byHand.updateHeightBands()

        XCTAssertEqual(auto.fingerprint(), byHand.fingerprint(),
                       "recomputeFlowAfterEdit fährt eine andere Reihenfolge als "
                       + "die vier Pässe, die es bündelt")
    }

    func testRecomputeFlowAfterEditLeavesTimeAndSnowBalanceAlone() {
        let t = Terrain(config: cfg(), seed: 1337)
        t.step(dtYears: 500)
        let snowBefore = t.snow
        let yearsBefore = t.years
        t.sculpt(gx: 48, gz: 48, radiusWorld: 14, dir: 1, strength: 30)
        let areaBefore = t.area
        let bandsBefore = t.heightBands

        t.recomputeFlowAfterEdit()

        XCTAssertNotEqual(t.area, areaBefore, "Entwässerung nicht neu berechnet")
        XCTAssertEqual(t.waterLevel, t.hf, "Seespiegel nicht auf den Strich gesnappt")
        XCTAssertNotEqual(t.heightBands.rockStart, bandsBefore.rockStart,
                          "Höhenbänder nicht nachgezogen")
        XCTAssertEqual(t.years, yearsBefore, "Ein Strich ist kein Zeitschritt")
        XCTAssertEqual(t.snow, snowBefore, "Schneebilanz hängt am Pinsel")
    }

    func testGenerateSettleRunsRealPhysicsAndResetsTheClock() {
        let c = cfg()
        let raw = Terrain(config: c, seed: 1337)
        let settled = Terrain(config: c, seed: 1337, settleYears: 200)
        let settledAgain = Terrain(config: c, seed: 1337, settleYears: 200)

        XCTAssertEqual(settled.years, 0, "Der Einlauf ist älter als das Spieljahr 0")
        XCTAssertNotEqual(settled.h, raw.h, "200 Jahre Einlauf verändern die Welt")
        XCTAssertEqual(settled.h, settledAgain.h, "Einlauf ist deterministisch je Seed")
        XCTAssertEqual(settled.waterLevel, settled.hf,
                       "Startzustands-Doktrin gilt auch nach dem Einlauf")

        let explicitZero = Terrain(config: c, seed: 1337, settleYears: 0)
        XCTAssertEqual(explicitZero.h, raw.h, "settleYears 0 == bisheriges Verhalten")
    }
}
