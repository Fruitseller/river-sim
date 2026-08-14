import XCTest
@testable import SimCore

/// Wächter für die Render-Kalibrierung des Wasserfelds (Issue #32, `WaterRender`).
///
/// Warum hier: die Kalibrierung wirkt in der GDExtension
/// (`SimNode.waterFieldBytes`) und im Shader (`game/shaders/terrain.gdshader`) —
/// beides ist headless nicht ausführbar (Extension-Build ~20 min, Shader läuft nur
/// auf der GPU). Die Zahlen selbst sind aber reine Arithmetik, und genau ihre
/// PAARUNGEN sind das Fragile: Komponenten-Fade ↔ Shader-Smoothstep ↔
/// Altarm-Stempel. Diese Tests pinnen die Paarungen, damit spätere Änderungen die
/// Kalibrierung nicht still verschieben.
final class WaterRenderTests: XCTestCase {

    // MARK: Kohärenz-Fade: reine Funktion der Komponentengröße

    func testComponentFadeWindow() {
        // Fenster 10 → 50 Zellen, linear; außerhalb geklemmt.
        XCTAssertEqual(WaterRender.componentFadeLoCells, 10.0)
        XCTAssertEqual(WaterRender.componentFadeHiCells, 50.0)
        XCTAssertEqual(WaterRender.componentFade(cells: 0), 0.0)
        XCTAssertEqual(WaterRender.componentFade(cells: 10), 0.0)
        XCTAssertEqual(WaterRender.componentFade(cells: 11), 0.025, accuracy: 1e-12)
        XCTAssertEqual(WaterRender.componentFade(cells: 30), 0.5, accuracy: 1e-12)
        XCTAssertEqual(WaterRender.componentFade(cells: 50), 1.0)
        XCTAssertEqual(WaterRender.componentFade(cells: 100_000), 1.0)
    }

    func testComponentFadeIsMonotonicAndBounded() {
        var previous = -1.0
        for cells in 0...200 {
            let fade = WaterRender.componentFade(cells: cells)
            XCTAssertGreaterThanOrEqual(fade, previous, "Fade darf nicht fallen")
            XCTAssertGreaterThanOrEqual(fade, 0.0)
            XCTAssertLessThanOrEqual(fade, 1.0)
            previous = fade
        }
    }

    func testFadeReplacesHardCutoffWithoutJump() {
        // Kern der Umstellung (#32): kein Sprung mehr an der alten harten Schwelle
        // 25 Zellen — dort PLOPPTEN wachsende Seen. Der größte Schritt zwischen
        // benachbarten Größen ist eine Zelle Fenster-Breite.
        let step = 1.0 / (WaterRender.componentFadeHiCells - WaterRender.componentFadeLoCells)
        for cells in 0..<200 {
            let delta = WaterRender.componentFade(cells: cells + 1)
                - WaterRender.componentFade(cells: cells)
            XCTAssertLessThanOrEqual(delta, step + 1e-12)
        }
        XCTAssertGreaterThan(WaterRender.componentFade(cells: 25), 0.0)
        XCTAssertLessThan(WaterRender.componentFade(cells: 25), 1.0,
                          "25 Zellen liegen MITTEN im Fade — nicht wieder als Kante")
    }

    // MARK: Wo die Shader-Fenster den Fade schneiden (Sichtbarkeits-Grenzen)

    func testLakeGateVisibilityThresholds() {
        // See-Kanal = GATE: smoothstep(0.04, 0.35, fade). Unsichtbar bis ~11,
        // voll ab 24 Zellen (Herleitung im WaterRender-Kommentar).
        XCTAssertLessThanOrEqual(WaterRender.componentFade(cells: 11), WaterRender.lakeGateLo)
        XCTAssertGreaterThan(WaterRender.componentFade(cells: 12), WaterRender.lakeGateLo)
        XCTAssertLessThan(WaterRender.componentFade(cells: 23), WaterRender.lakeGateHi)
        XCTAssertGreaterThanOrEqual(WaterRender.componentFade(cells: 24), WaterRender.lakeGateHi)
    }

    func testStreamChannelIsGatedNotFaded() {
        // Fluss-Kanal = GATE, kein weicher Fade: unter 28 Zellen trägt eine
        // Komponente nichts, ab 28 ihre volle Intensität. Das Gate sitzt bei
        // riverMaskHi — der Fade-Höhe, ab der ein voller Lauf schon deckt.
        XCTAssertEqual(WaterRender.streamGateFade, WaterRender.riverMaskHi)
        XCTAssertEqual(WaterRender.streamGateCells, 28)
        XCTAssertEqual(WaterRender.streamGate(componentFade: WaterRender.componentFade(cells: 27)), 0)
        XCTAssertEqual(WaterRender.streamGate(componentFade: WaterRender.componentFade(cells: 28)), 1)
        // Am Gate deckt ein voller Lauf sofort — nur so kann beim Einschalten
        // kein Saum ohne Wasser stehenbleiben.
        XCTAssertEqual(WaterRender.riverMask(stream: WaterRender.streamGateFade), 1.0, accuracy: 1e-12)
    }

    func testSmallStreamComponentPaintsNeitherWaterNorShore() {
        // REGRESSION (Review zu #32/#31): mit `sd *= fade` landete eine isolierte
        // 16-Zell-Komponente mit voller Intensität bei stream = 0.15 — riverMask 0
        // (kein Wasser), shore aber ≈ 0.94: ein sandbrauner Fleck, wo der alte
        // harte Cutoff exakt 0 lieferte. Über den ganzen kritischen Bereich prüfen,
        // nicht nur an einer Stelle.
        for cells in 0...(WaterRender.streamGateCells - 1) {
            let stream = 1.0 * WaterRender.streamGate(componentFade: WaterRender.componentFade(cells: cells))
            XCTAssertEqual(stream, 0.0, "\(cells) Zellen dürfen den Fluss-Kanal nicht speisen")
            XCTAssertEqual(WaterRender.riverMask(stream: stream), 0.0)
            XCTAssertEqual(WaterRender.shore(stream: stream, lakeGateChannel: 0, pond: 0), 0.0,
                           "\(cells) Zellen: kein Ufer-Saum ohne Wasser")
        }
    }

    func testFadingLakeShowsWaterBeforeShore() {
        // REGRESSION: der Saum sättigt bei Kanal 0.16, das See-Gate erst bei 0.35 —
        // ohne den `dry`-Faktor im Shader tönte eine halb eingeblendete Seefläche
        // ihren eigenen Grund sandbraun, bevor das Wasser sichtbar wird.
        // Im Seeinneren (Wassersäule über der Kontur) gibt es NIE Saum …
        let deepPond = WaterRender.pondContourHi + 0.01
        for cells in 0...60 {
            let gate = WaterRender.componentFade(cells: cells)
            XCTAssertEqual(WaterRender.shore(stream: 0, lakeGateChannel: gate, pond: deepPond), 0.0,
                           accuracy: 1e-12, "\(cells) Zellen: Saum im Wasser")
        }
        // … und auf dem trockenen Uferring bleibt der gemessene Saum erhalten
        // (docs/lake-shore-contour-measurements.md: Ring-Kanalwert ≈ 0.11 → 0.27).
        XCTAssertEqual(WaterRender.shore(stream: 0, lakeGateChannel: 0.1135, pond: 0), 0.27,
                       accuracy: 0.02)
    }

    func testGateSaturatesBeforeRiverMask() {
        // Verworfene Variante festhalten: die Gate-Kurve NICHT auch auf den
        // Fluss-Kanal legen. Sie sättigt früher (0.35 < 0.45) — kombiniert wären
        // 18-Zell-Fetzen voll sichtbar, genau die Sprenkel, die der Fade abwehrt.
        XCTAssertLessThan(WaterRender.lakeGateHi, WaterRender.riverMaskHi)
        XCTAssertLessThan(WaterRender.lakeGateLo, WaterRender.riverMaskLo)
    }

    func testShoreWindowSitsUnderTheWaterWindow() {
        // Der Grund, warum der Fluss-Kanal kein weiches Fade verträgt: sein
        // Saum-Fenster liegt KOMPLETT unter seinem Wasser-Fenster.
        XCTAssertLessThan(WaterRender.shoreLo, WaterRender.shoreHi)
        XCTAssertLessThanOrEqual(WaterRender.shoreHi, WaterRender.riverMaskLo)
        // Der Ribbon-Saum (#31) lebt genau in diesem Fenster: sichtbar als Nass-
        // Halo, aber nie als eigener Fluss unter dem Band.
        XCTAssertGreaterThan(WaterRender.ribbonHaloIntensity, WaterRender.shoreLo)
        XCTAssertLessThan(WaterRender.ribbonHaloIntensity, WaterRender.riverMaskLo)
    }

    // MARK: Uferkontur ↔ Altarm-Stempel

    func testPondWindowsStayInOrder() {
        // Drei Fenster lesen dieselbe Wassersäule; ihre Reihenfolge IST die
        // Kalibrierung: erst Farb-Kontur (die Farbe reicht bis fast an die echte
        // Uferlinie), dann der Geometrie-Hub, die Tiefen-Rampe füllt dazwischen.
        XCTAssertEqual(WaterRender.pondContourLo, 0.003)
        XCTAssertEqual(WaterRender.pondContourHi, 0.02)
        XCTAssertLessThan(WaterRender.pondContourLo, WaterRender.pondContourHi)
        XCTAssertLessThan(WaterRender.pondContourLo, WaterRender.geometryLiftLo)
        XCTAssertLessThan(WaterRender.geometryLiftLo, WaterRender.geometryLiftHi)
        XCTAssertLessThan(WaterRender.lakeDepthLo, WaterRender.geometryLiftLo)
        XCTAssertGreaterThan(WaterRender.lakeDepthSpan, 0)
    }

    func testShaderMatchesCalibration() throws {
        // Die Fenster stehen doppelt: hier als Zahl, im Shader als smoothstep/clamp.
        // Ohne diesen Vergleich driften sie stumm auseinander — der Shader hat keine
        // andere Testebene. Verglichen wird gegen den ECHTEN Quelltext von
        // game/shaders/terrain.gdshader.
        let shader = try repoFile("game/shaders/terrain.gdshader")
        assertContains(shader, "smoothstep(\(WaterRender.pondContourLo), "
            + "\(WaterRender.pondContourHi), pond)",
            hint: "Kontur-Fuß/Sattel der Uferlinie == WaterRender.pondContour*")
        assertContains(shader, "smoothstep(\(WaterRender.lakeGateLo), "
            + "\(WaterRender.lakeGateHi), texture(water_tex, uv).g)",
            hint: "See-GATE == WaterRender.lakeGate*")
        assertContains(shader, "smoothstep(\(WaterRender.riverMaskLo), "
            + "\(WaterRender.riverMaskHi), stream)",
            hint: "Fluss-INTENSITÄT == WaterRender.riverMask*")
        assertContains(shader, "smoothstep(\(WaterRender.shoreLo), "
            + "\(WaterRender.shoreHi), max(stream, lake_gate))",
            hint: "Ufer-Saum == WaterRender.shore*")
        assertContains(shader, "smoothstep(\(WaterRender.geometryLiftLo), "
            + "\(WaterRender.geometryLiftHi), pond)",
            hint: "Hub der Wasser-Geometrie == WaterRender.geometryLift*")
        assertContains(shader, "clamp((pond - \(WaterRender.lakeDepthLo)) "
            + "/ \(WaterRender.lakeDepthSpan), 0.0, 1.0)",
            hint: "See-Tiefenrampe == WaterRender.lakeDepth*")
    }

    // MARK: Geometrie-Wasser (Issue #34): Übergabe Band ↔ Raster

    func testGeometryHandsOverExactlyWhereTheRasterStarts() {
        // Der Kern von #34: das Band malt das Flachwasser, das der See-Kanal
        // NICHT malen darf, und hört auf, wo dieser übernimmt. Genau EINE Zahl
        // trennt beide — deshalb ist die Delta-Front die rawWet-Schwelle selbst
        // und keine zweite Kalibrierung daneben.
        XCTAssertEqual(WaterRender.lakeRawWetDepth, 0.03)
        XCTAssertEqual(WaterRender.deltaFrontDepth, WaterRender.lakeRawWetDepth)
        // Und sie liegt über dem Fuß der Uferkontur: dazwischen liegt das Band.
        XCTAssertLessThan(WaterRender.pondContourLo, WaterRender.deltaFrontDepth)
        // Kein Spalt: die Ausblende-Rampe des Bands beginnt am Kontur-Fuß, also
        // dort, wo der Shader die Uferlinie überhaupt erst zeichnet.
        XCTAssertLessThan(WaterRender.pondContourLo, WaterRender.pondContourHi)
        XCTAssertLessThanOrEqual(WaterRender.pondContourHi, WaterRender.deltaFrontDepth)
    }

    func testDeltaArmGeometryStaysASubordinatePlume() {
        // Ein Delta-Arm liegt IM Wasser des Beckens — er darf es tönen, nicht
        // ersetzen. Deckkraft deutlich unter 1, Fächer-Winkel unter 45°, und
        // eine sinnvolle Armlänge.
        XCTAssertGreaterThan(WaterRender.deltaArmOpacity, 0)
        XCTAssertLessThan(WaterRender.deltaArmOpacity, 0.5)
        XCTAssertGreaterThan(WaterRender.deltaArmSpread, 0)
        XCTAssertLessThan(WaterRender.deltaArmSpread, Double.pi / 4)
        XCTAssertLessThan(WaterRender.deltaMinArmCells, WaterRender.deltaMaxArmCells)
        XCTAssertGreaterThanOrEqual(WaterRender.deltaMinArmCells, 2)
        XCTAssertGreaterThan(WaterRender.mouthOverlapCells, 0)
    }

    func testBandsSitOnTheWaterSurfaceNotAboveIt() {
        // Das Meer ist eine eigene Ebene: darüber liegt nichts, sonst schwebt das
        // Band als Platte. Der See wird vom Terrain-Gitter getragen, das im
        // Apron noch UNTER dem Spiegel liegt: dort ein Hauch darüber.
        XCTAssertLessThan(WaterRender.ribbonSeaSurfaceSink, 0)
        XCTAssertGreaterThan(WaterRender.ribbonLakeSurfaceLift, 0)
        // Beide deutlich kleiner als der Land-Lift (`RenderContract.riverLift`,
        // == Main.gd RIVER_LIFT), sonst wäre die Wasser-Sonderbehandlung
        // wirkungslos. Die Schichten-Kopplung prüft `RenderContractTests`.
        XCTAssertLessThan(abs(WaterRender.ribbonSeaSurfaceSink), RenderContract.riverLift)
        XCTAssertLessThan(WaterRender.ribbonLakeSurfaceLift, RenderContract.riverLift)
    }

    func testRibbonKindsMapToTheShaderWeights() {
        // Der Typ-Kanal (UV2.x) trägt drei diskrete Werte, der Shader liest sie
        // als weiche Gewichte. Jeder Typ muss GENAU sein Gewicht bekommen —
        // sonst kräuselt ein Altarm wie ein Fluss oder ein Delta-Arm wird
        // tiefblau statt trüb.
        XCTAssertEqual(WaterRender.ribbonStillWeight(kind: WaterRender.ribbonKindRiver), 0)
        XCTAssertEqual(WaterRender.ribbonDeltaWeight(kind: WaterRender.ribbonKindRiver), 0)
        XCTAssertEqual(WaterRender.ribbonStillWeight(kind: WaterRender.ribbonKindDelta), 0)
        XCTAssertEqual(WaterRender.ribbonDeltaWeight(kind: WaterRender.ribbonKindDelta), 1)
        XCTAssertEqual(WaterRender.ribbonStillWeight(kind: WaterRender.ribbonKindOxbow), 1)
        XCTAssertEqual(WaterRender.ribbonDeltaWeight(kind: WaterRender.ribbonKindOxbow), 0)
    }

    func testWaterShaderMatchesRibbonContract() throws {
        // Wie beim Terrain-Shader: die Fenster stehen doppelt (hier als Zahl,
        // dort als smoothstep). Ohne Vergleich driften sie stumm auseinander.
        let shader = try repoFile("game/shaders/water.gdshader")
        assertContains(shader, "smoothstep(\(WaterRender.ribbonStillLo), "
            + "\(WaterRender.ribbonStillHi), v_kind)",
            hint: "Stillwasser-Gewicht == WaterRender.ribbonStill*")
        assertContains(shader, "smoothstep(\(WaterRender.ribbonDeltaLo), "
            + "\(WaterRender.ribbonDeltaHi), v_kind)",
            hint: "Delta-Gewicht == WaterRender.ribbonDelta*")
        assertContains(shader, "v_kind = UV2.x",
            hint: "Typ-Kanal des Vertex-Vertrags == UV2.x")
    }

    func testExtensionUsesSharedCalibration() throws {
        // Gegenstück: die GDExtension darf die Werte nicht als lokale Literale
        // zurückkopieren (dann wäre die Kalibrierung wieder ungetestet). Vor allem
        // die Altarm-Präsenz-Schwelle MUSS der Kontur-Fuß sein, sonst sind die
        // seichten Altarm-Enden unsichtbar (Doppel-Rampe: Stempel × Kontur), und
        // der Ribbon-Halo (#31) MUSS im Saum-Fenster bleiben.
        let simNode = try repoFile("Extension/Sources/RiverSimGD/SimNode.swift")
        assertContains(simNode, "WaterRender.componentFade(cells:",
                       hint: "Komponenten-Fade aus WaterRender beziehen")
        assertContains(simNode, "WaterRender.streamGate(componentFade:",
                       hint: "Fluss-Kanal über das gemeinsame Gate schalten")
        assertContains(simNode, "let minimumPondDepth = WaterRender.pondContourLo",
                       hint: "Altarm-Präsenz-Schwelle == Kontur-Fuß")
        assertContains(simNode, "let haloIntensity = WaterRender.ribbonHaloIntensity",
                       hint: "Ribbon-Halo == WaterRender.ribbonHaloIntensity")
        assertContains(simNode, "sd[k] >= WaterRender.riverMaskLo",
                       hint: "Kohärenz-Maske == Wasser-Schwelle des Shaders")
        // Issue #34: die Geometrie-Übergabe darf ebenso wenig als Literal in der
        // Extension liegen — sonst kann die Band-Ausblendung von der
        // Raster-See-Schwelle wegdriften, und genau dazwischen entsteht wieder
        // ein Spalt bzw. doppeltes Wasser.
        assertContains(simNode, "hf[k] - h[k] > WaterRender.lakeRawWetDepth",
                       hint: "Raster-See-Schwelle aus WaterRender beziehen")
        assertContains(simNode, "1 - smoothstep(WaterRender.pondContourLo, WaterRender.deltaFrontDepth, pond)",
                       hint: "See-Übergabe des Bands == Kontur-Fuß … Delta-Front")
        assertContains(simNode, "1 - smoothstep(0, WaterRender.mouthOverlapCells, submergedCells)",
                       hint: "Meer-Übergabe des Bands == mouthOverlapCells")
        assertContains(simNode, "kind: WaterRender.ribbonKindOxbow",
                       hint: "Altarm-Bänder tragen den Altarm-Typ")
        assertContains(simNode, "kind: WaterRender.ribbonKindDelta",
                       hint: "Delta-Arme tragen den Delta-Typ")
        assertContains(simNode, "onSea ? WaterRender.ribbonSeaSurfaceSink",
                       hint: "Höhen-Versatz auf Wasser aus WaterRender beziehen")
        // Issue #51: Track-Maske, Abstufung, Verbreiterung und die Kanalbreiten
        // lagen als Literale in `waterFieldBytes`/`buildRiverRibbons` — dort
        // konnte sie nur ein ~20-Minuten-Build prüfen.
        assertContains(simNode, "WaterRender.trackMask(streamMap:",
                       hint: "Track-Maske des Abfluss-Felds aus WaterRender beziehen")
        assertContains(simNode, "WaterRender.trackWeight(mask:",
                       hint: "Gewicht der Track-Maske aus WaterRender beziehen")
        assertContains(simNode, "WaterRender.streamIntensity(dischargeCells:",
                       hint: "Abfluss-Abstufung aus WaterRender beziehen")
        assertContains(simNode, "WaterRender.corridorMask(streamMap:",
                       hint: "Korridor-/Band-Kohärenzmaske aus WaterRender beziehen")
        assertContains(simNode, "WaterRender.corridorWeight(mask:",
                       hint: "Gewicht der Korridor-Maske aus WaterRender beziehen")
        assertContains(simNode, "WaterRender.continuityDecayPerCell",
                       hint: "Kontinuitäts-Propagation aus WaterRender beziehen")
        assertContains(simNode, "let widenThresh = WaterRender.widenThresholds",
                       hint: "Verbreiterungs-Schwellen aus WaterRender beziehen")
        assertContains(simNode, "let widenFalloff = WaterRender.widenFalloff",
                       hint: "Verbreiterungs-Abfall aus WaterRender beziehen")
        assertContains(simNode, "let barTol = WaterRender.widenBarTolerance",
                       hint: "Bank-Toleranz der Verbreiterung aus WaterRender beziehen")
        assertContains(simNode, "WaterRender.ribbonHalfWidthCells(dischargeCells:",
                       hint: "Band-Halbbreite aus WaterRender beziehen")
        assertContains(simNode, "WaterRender.stampHalfWidthCells(dischargeCells:",
                       hint: "Stempel-Halbbreite (Legacy-A/B) aus WaterRender beziehen")
        assertContains(simNode, "WaterRender.stampIntensity(dischargeCells:",
                       hint: "Stempel-Intensität (Legacy-A/B) aus WaterRender beziehen")
        assertContains(simNode, "WaterRender.ribbonHaloMarginCells",
                       hint: "Halo-Rand um das Band aus WaterRender beziehen")
        assertContains(simNode, "WaterRender.oxbowMinimumNodes",
                       hint: "Altarm-Filter aus WaterRender beziehen")
        assertContains(simNode, "WaterRender.oxbowHalfWidthCells",
                       hint: "Altarm-Breite aus WaterRender beziehen")
        assertContains(simNode, "WaterRender.mouthSearchCells",
                       hint: "Mündungs-Suchweite aus WaterRender beziehen")
        assertContains(simNode, "WaterRender.ribbonMinimumRank",
                       hint: "Hierarchie-Gate der Bänder aus WaterRender beziehen")
        assertContains(simNode, "WaterRender.ribbonRankDivisor",
                       hint: "Rang-Normierung des Vertex-Vertrags aus WaterRender beziehen")
        assertContains(simNode, "WaterRender.ribbonSupportLo",
                       hint: "Band-Kohärenzfenster aus WaterRender beziehen")
        assertContains(simNode, "WaterRender.ribbonSourceTaperCells",
                       hint: "Quellen-Taper aus WaterRender beziehen")
        assertContains(simNode, "WaterRender.ribbonTailTaperCells",
                       hint: "Enden-Taper aus WaterRender beziehen")
        assertContains(simNode, "WaterRender.ribbonMinimumAlpha",
                       hint: "Sichtbarkeits-Schwelle der Bänder aus WaterRender beziehen")
        assertContains(simNode, "WaterRender.deltaArmMinHalfWidthCells",
                       hint: "Delta-Arm-Breite aus WaterRender beziehen")
    }

    // MARK: Kanalbreiten (Issue #51)

    func testRibbonWidthFollowsDischarge() {
        // w ∝ √Q (Leopold/Maddock): am Referenz-Abfluss genau die Stempel-Optik,
        // darüber breiter, darunter schmaler — mit Boden und Deckel.
        let reference = 280.0
        XCTAssertEqual(WaterRender.ribbonHalfWidthAtReference, 0.8)
        XCTAssertEqual(WaterRender.ribbonHalfWidthFloorCells, 0.12)
        XCTAssertEqual(WaterRender.ribbonHalfWidthCapCells, 3.2)
        XCTAssertEqual(WaterRender.ribbonHalfWidthCells(dischargeCells: reference,
                                                        referenceCells: reference),
                       WaterRender.ribbonHalfWidthAtReference, accuracy: 1e-12)
        // Vierfacher Abfluss = doppelte Breite (der Exponent, nicht nur der Trend).
        XCTAssertEqual(WaterRender.ribbonHalfWidthCells(dischargeCells: 4 * reference,
                                                        referenceCells: reference),
                       2 * WaterRender.ribbonHalfWidthAtReference, accuracy: 1e-12)
        // Boden und Deckel greifen an beiden Enden — auch bei Unsinns-Eingaben.
        XCTAssertEqual(WaterRender.ribbonHalfWidthCells(dischargeCells: -5,
                                                        referenceCells: reference),
                       WaterRender.ribbonHalfWidthFloorCells)
        XCTAssertEqual(WaterRender.ribbonHalfWidthCells(dischargeCells: 1e9,
                                                        referenceCells: reference),
                       WaterRender.ribbonHalfWidthCapCells)
        // Der Altarm ist konstant breit und liegt im selben Fenster.
        XCTAssertEqual(WaterRender.oxbowHalfWidthCells, 1.0)
        XCTAssertGreaterThan(WaterRender.oxbowHalfWidthCells,
                             WaterRender.ribbonHalfWidthFloorCells)
        XCTAssertLessThan(WaterRender.oxbowHalfWidthCells,
                          WaterRender.ribbonHalfWidthCapCells)
    }

    func testHaloAlwaysCoversTheBand() {
        // Der Nass-Halo im Wasserfeld wird um die BAND-Halbbreite gestempelt.
        // Ohne Rand endete er an der Bandkante — dann steht das Band auf einer
        // harten Farbkante statt in einem Ufer (Rückbau-Ursache f3556c8).
        XCTAssertEqual(WaterRender.ribbonHaloMarginCells, 1.0)
        XCTAssertGreaterThan(WaterRender.ribbonHaloMarginCells, 0)
        XCTAssertEqual(WaterRender.ribbonHaloIntensity, 0.14)
    }

    func testDeltaArmIsWiderThanTheChannelItComesFrom() {
        // Der Strom verliert an der Mündung seine Tiefe, nicht sein Wasser.
        XCTAssertEqual(WaterRender.deltaArmMinHalfWidthCells, 1.5)
        XCTAssertGreaterThan(WaterRender.deltaArmWidthAtMouth, 1)
        // … und läuft zur Front hin schmaler aus, ohne je auf 0 zu fallen (das
        // macht der Taper am Ende, nicht das Breiten-Profil).
        XCTAssertGreaterThan(WaterRender.deltaArmWidthAtMouth
                             - WaterRender.deltaArmWidthTaper, 0)
        XCTAssertLessThan(WaterRender.deltaArmWidthAtMouth
                          - WaterRender.deltaArmWidthTaper, 1)
        XCTAssertLessThan(WaterRender.deltaArmRankFactor, 1)
        XCTAssertGreaterThan(WaterRender.deltaArmRankFactor, 0)
    }

    func testBandEndsAndGatesStayInOrder() {
        XCTAssertEqual(WaterRender.ribbonSourceTaperCells, 4.0)
        XCTAssertEqual(WaterRender.ribbonTailTaperCells, 2.0)
        // Die Quelle blendet länger ein, als das Ende ausblendet: ein Oberlauf
        // soll wachsen, ein Ende nur die Kante brechen.
        XCTAssertGreaterThan(WaterRender.ribbonSourceTaperCells,
                             WaterRender.ribbonTailTaperCells)
        XCTAssertEqual(WaterRender.ribbonMinimumAlpha, 0.02)
        // Strahler 4 rein, Strahler 3 raus — genau das ist die Hierarchie-Gate.
        XCTAssertEqual(WaterRender.ribbonRankDivisor, 6.0)
        XCTAssertLessThan(3 / WaterRender.ribbonRankDivisor, WaterRender.ribbonMinimumRank)
        XCTAssertLessThan(WaterRender.ribbonMinimumRank, 4 / WaterRender.ribbonRankDivisor)
        // Die Mündungs-Suche muss weiter reichen als die Überlappung, sonst
        // findet sie das Wasser nie tief genug (Band endet vor der Uferlinie).
        XCTAssertGreaterThan(Double(WaterRender.mouthSearchCells),
                             WaterRender.mouthOverlapCells)
    }

    func testOxbowFilterIsSharedAndSelfConsistent() {
        XCTAssertEqual(WaterRender.oxbowMinimumNodes, 10)
        XCTAssertEqual(WaterRender.oxbowMaximumTrimmedNodes, 3)
        XCTAssertEqual(WaterRender.oxbowEndFadeSteps, 3.0)
        XCTAssertEqual(WaterRender.oxbowMaximumOpacity, 0.7)
        // Eine gerade noch zugelassene Schleife muss nach dem Trimmen der
        // Hals-Enden noch einen Bogen übrig haben — sonst emittieren beide
        // Pfade (Geometrie und Stempel) nichts und der Filter wäre wirkungslos.
        XCTAssertGreaterThan(WaterRender.oxbowMinimumNodes,
                             2 * WaterRender.oxbowMaximumTrimmedNodes)
        // Ein Altarm ist trübes Stillwasser, nie volle Deckkraft.
        XCTAssertLessThan(WaterRender.oxbowMaximumOpacity, 1)
    }

    // MARK: Track-Maske, Abstufung, Verbreiterung (Issue #51)

    func testTrackMaskWindow() {
        XCTAssertEqual(WaterRender.trackMaskLo, 0.18)
        XCTAssertEqual(WaterRender.trackMaskSpan, 0.24)
        XCTAssertEqual(WaterRender.trackMask(streamMap: 0.18), 0)
        XCTAssertEqual(WaterRender.trackMask(streamMap: 0.0), 0)
        XCTAssertEqual(WaterRender.trackMask(streamMap: 0.3), 0.5, accuracy: 1e-12)
        XCTAssertEqual(WaterRender.trackMask(streamMap: 0.42), 1, accuracy: 1e-12)
        XCTAssertEqual(WaterRender.trackMask(streamMap: 9), 1)
        // Wer die Maske passiert, ist ein echter Lauf: das Gewicht startet auf
        // dem Sockel und erreicht bei voller Maske exakt 1.
        XCTAssertEqual(WaterRender.trackWeight(mask: 0), WaterRender.trackWeightFloor)
        XCTAssertEqual(WaterRender.trackWeight(mask: 1), 1, accuracy: 1e-12)
    }

    func testCorridorMaskSitsUnderTheTrackMask() {
        // Der Korridor IST per Definition ein echter Lauf (Zentrumslinie) — sein
        // Fenster liegt deshalb tiefer als das der freien Raster-Läufe, und sein
        // Sockel ebenfalls (er darf verblassen, nicht verschwinden).
        XCTAssertEqual(WaterRender.corridorTrackLo, 0.1)
        XCTAssertEqual(WaterRender.corridorTrackSpan, 0.2)
        XCTAssertLessThan(WaterRender.corridorTrackLo, WaterRender.trackMaskLo)
        XCTAssertEqual(WaterRender.corridorMask(streamMap: 0.2), 0.5, accuracy: 1e-12)
        XCTAssertEqual(WaterRender.corridorWeight(mask: 0), WaterRender.corridorWeightFloor)
        XCTAssertEqual(WaterRender.corridorWeight(mask: 1), 1, accuracy: 1e-12)
        XCTAssertLessThan(WaterRender.corridorWeightFloor, WaterRender.trackWeightFloor)
        // Band-Kohärenz liest dieselbe Maske, gemittelt über den ganzen Kanal.
        XCTAssertEqual(WaterRender.ribbonSupportLo, 0.35)
        XCTAssertEqual(WaterRender.ribbonSupportSpan, 0.3)
        XCTAssertLessThan(WaterRender.ribbonSupportLo + WaterRender.ribbonSupportSpan, 1)
    }

    func testStreamGradingIsMonotonicAndBounded() {
        let creek = 280.0
        XCTAssertEqual(WaterRender.streamIntensityBase, 0.4)
        XCTAssertEqual(WaterRender.streamIntensityLogDivisor, 4.0)
        var previous = 0.0
        for q in stride(from: creek, through: 400 * creek, by: creek) {
            let value = WaterRender.streamIntensity(dischargeCells: q, creekCells: creek)
            XCTAssertGreaterThanOrEqual(value, previous)
            XCTAssertLessThanOrEqual(value, 1)
            previous = value
        }
        // An der Render-Schwelle trägt ein Lauf schon sichtbar — sonst begänne
        // jeder Fluss als Saum-ohne-Wasser (s. `riverMaskLo`).
        XCTAssertGreaterThan(WaterRender.streamIntensity(dischargeCells: creek,
                                                         creekCells: creek),
                             WaterRender.riverMaskLo)
        XCTAssertEqual(WaterRender.streamPondTolerance, 0.01)
        // Das Fluss-Feld hält sich an nahezu ungeflutete Zellen; alles Tiefere
        // gehört dem See-Kanal.
        XCTAssertLessThan(WaterRender.streamPondTolerance, WaterRender.lakeRawWetDepth)
    }

    func testWideningKeepsTheHierarchy() {
        XCTAssertEqual(WaterRender.widenThresholds, [0.55, 0.8])
        XCTAssertEqual(WaterRender.widenFalloff, 0.09)
        XCTAssertEqual(WaterRender.widenBarTolerance, 0.004)
        // Aufsteigend und unter 1: jeder Pass verbreitert nur noch kräftigere
        // Läufe (Bäche bleiben fadendünn).
        XCTAssertEqual(WaterRender.widenThresholds, WaterRender.widenThresholds.sorted())
        for thresh in WaterRender.widenThresholds {
            XCTAssertGreaterThan(thresh, WaterRender.riverMaskLo)
            XCTAssertLessThan(thresh, 1)
        }
        // Ein verbreiterter Nachbar muss über der Wasser-Schwelle des Shaders
        // landen, sonst malte die Dilatation nur unsichtbaren Saum.
        XCTAssertGreaterThan(WaterRender.widenThresholds[0] - WaterRender.widenFalloff,
                             WaterRender.riverMaskLo)
        // Die Bank-Toleranz ist eine HÖHE (Wassersäule), kein Intensitätswert:
        // sie muss unter dem Fuß der Uferkontur bleiben, sonst übermalte die
        // Kosmetik-Breite echte Mittelbänke.
        XCTAssertLessThan(WaterRender.widenBarTolerance, WaterRender.pondContourHi)
    }

    func testContinuityChainStaysVisible() {
        XCTAssertEqual(WaterRender.continuityDecayPerCell, 0.015)
        XCTAssertEqual(WaterRender.continuityFloor, 0.3)
        // Die bergab propagierte Kette bricht ab, BEVOR sie unsichtbar wird —
        // sonst liefe ein Faden unter der Wasser-Schwelle weiter und malte nur
        // noch Saum ohne Wasser.
        XCTAssertGreaterThan(WaterRender.continuityFloor, WaterRender.riverMaskLo)
        // Und sie reicht über viele Zellen: der Zweck des Passes ist, dass ein
        // sichtbarer Fluss durchgängig bis Mündung/See läuft.
        XCTAssertGreaterThan(WaterRender.continuityDecayPerCell, 0)
        XCTAssertGreaterThan((1 - WaterRender.continuityFloor)
                             / WaterRender.continuityDecayPerCell, 30)
    }

    func testLegacyStampPathKeepsItsGrading() {
        let creek = 280.0
        XCTAssertEqual(WaterRender.stampHalfWidthCapCells, 1.0)
        // Der Stempel deckelt bei 1 Zelle Halbbreite (war 3 — Blob-Felder auf
        // den verknäulten Ebenen).
        XCTAssertEqual(WaterRender.stampHalfWidthCells(dischargeCells: 1e9,
                                                       creekCells: creek),
                       WaterRender.stampHalfWidthCapCells)
        XCTAssertGreaterThan(WaterRender.stampHalfWidthCells(dischargeCells: 0,
                                                             creekCells: creek), 0)
        // Eine Zentrumslinie IST ein Fluss: höherer Sockel als das Abfluss-Feld,
        // und über der Wasser-Schwelle des Shaders.
        XCTAssertGreaterThan(WaterRender.stampIntensityBase, WaterRender.streamIntensityBase)
        XCTAssertGreaterThan(WaterRender.stampIntensity(dischargeCells: 0, creekCells: creek),
                             WaterRender.riverMaskLo)
        XCTAssertLessThanOrEqual(WaterRender.stampIntensity(dischargeCells: 1e9,
                                                            creekCells: creek), 1)
    }

    // MARK: Gemeinsame Wasser-Optik beider Shader (Issue #51)

    func testBothWaterShadersShareTheSameWater() throws {
        // Raster-Wasser (terrain.gdshader) und Band-Geometrie (water.gdshader)
        // malen DASSELBE Wasser. Driften Farben oder Fresnel, zerfällt eine
        // Mündung sichtbar in zwei Wasser — deshalb dieselben Zahlen, gegen
        // BEIDE Quelltexte geprüft.
        let terrain = try repoFile("game/shaders/terrain.gdshader")
        let water = try repoFile("game/shaders/water.gdshader")
        for (name, shader) in [("terrain", terrain), ("water", water)] {
            assertContains(shader, "vec3 shallow = \(glsl(WaterRender.waterShallowColor));",
                           hint: "\(name): Seicht-Farbe == WaterRender.waterShallowColor")
            assertContains(shader, "vec3 deep = \(glsl(WaterRender.waterDeepColor));",
                           hint: "\(name): Tief-Farbe == WaterRender.waterDeepColor")
            assertContains(shader, "vec3 sky = \(glsl(WaterRender.skyReflectColor));",
                           hint: "\(name): Himmels-Ton == WaterRender.skyReflectColor")
            assertContains(shader, "pow(1.0 - ndv, \(glsl(WaterRender.fresnelExponent)))",
                           hint: "\(name): Fresnel-Exponent == WaterRender.fresnelExponent")
            assertContains(shader, "mix(water, sky, fresnel * \(glsl(WaterRender.fresnelSkyMix)))",
                           hint: "\(name): Himmels-Anteil == WaterRender.fresnelSkyMix")
            assertContains(shader, "mix(\(glsl(WaterRender.waterOpacityShallow)), "
                + "\(glsl(WaterRender.waterOpacityDeep)), depth)",
                hint: "\(name): Deckkraft == WaterRender.waterOpacity*")
            assertContains(shader, "mix(\(glsl(WaterRender.waterRoughnessSteep)), "
                + "\(glsl(WaterRender.waterRoughnessGrazing)), fresnel)",
                hint: "\(name): Rauheit == WaterRender.waterRoughness*")
            assertContains(shader, "mix(\(glsl(WaterRender.waterSpecularSteep)), "
                + "\(glsl(WaterRender.waterSpecularGrazing)), fresnel)",
                hint: "\(name): Specular == WaterRender.waterSpecular*")
            assertContains(shader, "flow * \(glsl(WaterRender.flowShimmerColor))",
                           hint: "\(name): Strömungs-Schimmer == WaterRender.flowShimmerColor")
        }
        // Nur die Band-Geometrie kennt Typen: Delta-Fahne und Altarm-Wasser.
        assertContains(water, glsl(WaterRender.deltaPlumeColor),
                       hint: "Trübungsfahne == WaterRender.deltaPlumeColor")
        assertContains(water, glsl(WaterRender.oxbowWaterColor),
                       hint: "Altarm-Wasser == WaterRender.oxbowWaterColor")
    }

    func testGodotGuardsPinTheSameContract() throws {
        // Die Godot-Wächter (GPU-frei, aber nur MIT gebauter Extension lauffähig)
        // tragen die Vertragswerte als eigene Konstanten. Driften sie, prüfen
        // sie gegen eine Kalibrierung, die es nicht mehr gibt.
        let geometry = try repoFile("game/tests/water_geometry.gd")
        assertContains(geometry, "const KIND_RIVER := \(glsl(WaterRender.ribbonKindRiver))",
                       hint: "Typ Fluss == WaterRender.ribbonKindRiver")
        assertContains(geometry, "const KIND_DELTA := \(glsl(WaterRender.ribbonKindDelta))",
                       hint: "Typ Delta == WaterRender.ribbonKindDelta")
        assertContains(geometry, "const KIND_OXBOW := \(glsl(WaterRender.ribbonKindOxbow))",
                       hint: "Typ Altarm == WaterRender.ribbonKindOxbow")
        assertContains(geometry, "const POND_CONTOUR_LO := \(glsl(WaterRender.pondContourLo))",
                       hint: "Kontur-Fuß == WaterRender.pondContourLo")
        assertContains(geometry, "const LAKE_RAW_WET := \(glsl(WaterRender.lakeRawWetDepth))",
                       hint: "Raster-See-Schwelle == WaterRender.lakeRawWetDepth")
        assertContains(geometry, "const MAX_OXBOW_OPACITY := \(glsl(WaterRender.oxbowMaximumOpacity))",
                       hint: "Altarm-Deckkraft == WaterRender.oxbowMaximumOpacity")
        assertContains(geometry, "const MOUTH_SEARCH_CELLS := \(WaterRender.mouthSearchCells)",
                       hint: "Mündungs-Suchweite == WaterRender.mouthSearchCells")
        let ribbons = try repoFile("game/tests/river_ribbons.gd")
        assertContains(ribbons, "const LAKE_SURFACE_LIFT := \(glsl(WaterRender.ribbonLakeSurfaceLift))",
                       hint: "See-Versatz == WaterRender.ribbonLakeSurfaceLift")
        assertContains(ribbons, "const SEA_SURFACE_SINK := \(glsl(WaterRender.ribbonSeaSurfaceSink))",
                       hint: "Meer-Versatz == WaterRender.ribbonSeaSurfaceSink")
        assertContains(ribbons, "const MIN_RANK := \(glsl(WaterRender.ribbonMinimumRank))",
                       hint: "Hierarchie-Gate == WaterRender.ribbonMinimumRank")
        assertContains(ribbons, "const KIND_DELTA_LO := \(glsl(WaterRender.ribbonDeltaLo))",
                       hint: "Typ-Trennung Fluss/Delta == WaterRender.ribbonDeltaLo")
    }

    // MARK: Hilfen

    /// Quelltext einer anderen Schicht — s. `RepoSource` (gemeinsam mit
    /// `RenderContractTests`).
    private func repoFile(_ relativePath: String) throws -> String {
        try RepoSource.file(relativePath)
    }
}
