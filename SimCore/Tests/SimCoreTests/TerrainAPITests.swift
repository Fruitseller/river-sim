import XCTest
@testable import SimCore

/// Wächter für öffentliche `Terrain`-API, die bisher nur INDIREKT (über die
/// Godot-Extension bzw. als Nebenwirkung anderer Tests) abgedeckt war:
/// die Generierung `generate(seed:)`, die Pinsel `smooth`/`roughen` und die
/// Abkling-Rate der Hebung `upliftDecayRatePer100y()`.
///
/// Alle Läufe headless und in kleiner Auflösung — geprüft werden die
/// ZUSICHERUNGEN dieser Funktionen (Determinismus, Wirkrichtung, Reichweite,
/// geschlossene Form), nicht die Kalibrierung der Landschaft.
final class TerrainAPITests: XCTestCase {

    /// Produktionsphysik, nur `n` gesenkt. `world` bleibt, damit Pinselradien
    /// in Welteinheiten dieselbe Bedeutung haben wie im Spiel.
    private func cfg(n: Int = 96) -> SimConfig {
        var c = SimConfig(); c.n = n; c.world = calibrationWorld; return c
    }

    // MARK: - generate(seed:)

    /// Gleicher Seed → BIT-gleiche Welt (AGENTS.md: „Determinismus ist eine
    /// getestete Invariante"), anderer Seed → andere Welt. Geprüft auf dem
    /// Höhenfeld und den Feldern, die `generate` selbst einschwingen lässt
    /// (Entwässerung, Klima, Vegetation, Stream-Map).
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

    /// `generate` auf einem BESTEHENDEN, gealterten Terrain (im Spiel: neuer
    /// Seed auf demselben `SimNode`) liefert dieselbe LANDSCHAFT wie ein frisches
    /// Terrain mit diesem Seed. Das ist die Zusicherung, an der die Aufräum-
    /// Zeilen in `generate` hängen (Kryo-Felder, Becken-Bilanz, Baustellen,
    /// Zähler) — bliebe eines davon stehen, entschiede nicht mehr der Seed
    /// allein über Relief und Entwässerung.
    ///
    /// AUSGENOMMEN ist bewusst `veg` (und die daraus abgeleiteten `vegClass`/
    /// `riparian`): der Sukzessions-Pass liest über den Samen-Druck
    /// (`vegDispersalRadius`) das VORHANDENE Feld, und `generate` leert es nicht
    /// — die Neugenerierung startet also mit dem Samen-Druck der alten Welt
    /// (gemessen n=96, Seed 1337 → 7: 1049 von 9216 Zellen unterschiedlich).
    /// Höhen, Sediment, Regen und Stream-Map sind davon unberührt (alle
    /// bit-gleich); der Unterschied lebt erst ab dem nächsten Schritt über
    /// `vegDamp` weiter. Nicht hier repariert: das wäre eine
    /// Verhaltensänderung, dieser Test dokumentiert sie nur.
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

    /// Was eine frische Welt IST: endliche Höhen im erlaubten Band, eine Insel
    /// (Land UND Meer), gefüllte Felder in Gitterlänge und ein Wasserstand, der
    /// nirgends unter dem Gelände liegt.
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
            // Und die Insel hat Relief — eine flache Platte über dem Meer wäre
            // formal „Land", aber keine generierte Landschaft.
            XCTAssertGreaterThan(t.landRelief(), 0.1, "Seed \(seed): Insel ohne Relief")
        }
    }

    // MARK: - smooth (Pinsel)

    /// Der Glättungs-Pinsel senkt die lokale Zerklüftung im Pinselkreis und
    /// lässt alles außerhalb UNANGETASTET (bit-genau) — die Reichweite ist der
    /// Radius, nicht die Karte.
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

        // Kein Überschießen: der Pinsel zieht Richtung 3×3-Mittel, er darf im
        // Kreis weder ein neues Maximum noch ein neues Minimum erzeugen.
        let cells = brushCells(center: (gx, gz), radiusWorld: radius, cfg: c)
        let loBefore = cells.map { before[$0] }.min()!, hiBefore = cells.map { before[$0] }.max()!
        for k in cells {
            XCTAssertGreaterThanOrEqual(t.h[k], loBefore - 1e-12, "neues Minimum bei \(k)")
            XCTAssertLessThanOrEqual(t.h[k], hiBefore + 1e-12, "neues Maximum bei \(k)")
        }
    }

    /// Stärke 0 ist ein No-Op (`pull = 0.30 · 0`): ein Strich ohne Druck darf
    /// das Gelände nicht anfassen — sonst driftet die Welt bei jedem
    /// UI-Mausrutscher.
    func testSmoothWithZeroStrengthChangesNothing() {
        let c = cfg()
        let t = Terrain(config: c, seed: 1337)
        let before = t.h
        t.smooth(gx: 40, gz: 40, radiusWorld: 12, strength: 0)
        XCTAssertEqual(t.h, before, "Glätten mit Stärke 0 hat das Gelände verändert")
    }

    // MARK: - roughen (Pinsel)

    /// Der Aufrau-Pinsel prägt ein VORZEICHENBEHAFTETES Rauschmuster ein: jede
    /// Zelle im Kreis bewegt sich, nach oben wie nach unten (kein Anheben durch
    /// die Hintertür), und zwar höchstens um die dokumentierte Amplitude
    /// `0.005 · strength`. Außerhalb bleibt alles stehen.
    ///
    /// Bewusst KEINE „Zerklüftung steigt"-Zusicherung: gemessen (n=96, Seed
    /// 1337, Radius 12 Welteinheiten ≈ 8,8 Zellen) verschiebt ein Strich die
    /// mittlere 3×3-Abweichung nur in der vierten Stelle und je nach
    /// Pinselgröße in beide Richtungen — das Rauschen hat auf Zellskala zu
    /// wenig Amplitude gegen das erodierte Relief. Der Pinsel wirkt über
    /// WIEDERHOLTE Striche (s. `testRoughenRepeatsTheSamePattern`).
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

    /// Aufrauen ist deterministisch UND vertieft dasselbe Muster: der Pinsel
    /// zieht sein Rauschen aus dem terrain-eigenen Feld, also trägt der zweite
    /// Strich je Zelle exakt dieselbe Änderung ein wie der erste (im Inneren,
    /// wo der Deckel `applyDelta` nicht greift).
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

        // …und ein zweites Terrain mit demselben Seed bekommt dasselbe Muster.
        let twin = Terrain(config: c, seed: 1337)
        twin.roughen(gx: gx, gz: gz, radiusWorld: radius, strength: 1.0)
        XCTAssertEqual(twin.h, h1, "Aufrauen ist nicht reproduzierbar")
    }

    // MARK: - Abkling-Rate der Hebung

    /// `U(t) = U_floor + (U₀ − U_floor)·e^(−t/τ)` (docs/research-terrain-aging.md
    /// §3): die Anzeige-Rate folgt der geschlossenen Form über die ganze
    /// Alterung, startet bei U₀ und fällt monoton gegen U_floor.
    func testUpliftDecayRateFollowsTheClosedForm() {
        var c = cfg(n: 48)
        c.hydraulicEnabled = false          // reine Zeitachse, kein teurer Tropfenpfad
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
        // Nach 4 τ ist der Überschuss auf e⁻⁴ ≈ 1,8 % abgeklungen — die Tektonik
        // liegt praktisch auf ihrer Untergrenze.
        XCTAssertLessThan(prev - uFloor, (u0 - uFloor) * 0.02,
                          "nach 4 τ noch \(prev) statt ~\(uFloor)")
    }

    /// τ = 0 heißt „kein Abklingen": die Rate bleibt bei U₀. Der Zweig ist der
    /// Ausschalter des Passes und wird sonst nirgends gelesen.
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

    /// Anzeige-Rate und die im Schritt EXAKT integrierte Hebung
    /// (`upliftDecayAmount`) beschreiben dieselbe Kurve: die mittlere Rate über
    /// einen Sprung liegt zwischen Anfangs- und Endrate. Ohne diese Kopplung
    /// könnte die Diagnose etwas anderes anzeigen, als die Sim einträgt.
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

    // MARK: - recomputeFlowAfterEdit()

    /// Der Nach-Strich-Auffrischer ist die feste Aufruf-Reihenfolge, die bis
    /// Issue #93 in der GDExtension stand. Sie gehört hierher, weil sie
    /// ausschließlich `Terrain`-Pässe taktet — und weil nur hier prüfbar ist,
    /// dass sie GENAU diese Reihenfolge fährt: das Ergebnis muss bit-gleich zu
    /// den vier Aufrufen von Hand sein (Fingerabdruck über das ganze
    /// Zustands-Inventar, s. `Terrain.fingerprint`).
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

    /// Und die Zusicherungen einzeln, damit ein Fehlschlag sagt, WELCHER Pass
    /// fehlt: Entwässerung neu, Seespiegel gesnappt, Höhenbänder nachgezogen —
    /// aber Sim-Zeit und Schneebilanz unangetastet (der Strich ist kein
    /// Zeitschritt, `dt = 0` lässt die Bilanz exakt stehen).
    func testRecomputeFlowAfterEditLeavesTimeAndSnowBalanceAlone() {
        let t = Terrain(config: cfg(), seed: 1337)
        t.step(dtYears: 500)
        let snowBefore = t.snow
        let yearsBefore = t.years
        // Ein Strich, der Entwässerung und Höhenverteilung sichtbar verstellt.
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

    // Die Pinsel-Helfer (`brushCells`, `roughness`, `assertUntouchedOutside`)
    // liegen seit #79 geteilt in `BrushTestSupport.swift` — `ToolContractTests`
    // braucht dieselbe Kreisgeometrie.
}
