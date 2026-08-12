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
        // Beide deutlich kleiner als der Land-Lift (Main.RIVER_LIFT = 0.35),
        // sonst wäre die Wasser-Sonderbehandlung wirkungslos.
        XCTAssertLessThan(abs(WaterRender.ribbonSeaSurfaceSink), 0.35)
        XCTAssertLessThan(WaterRender.ribbonLakeSurfaceLift, 0.35)
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
    }

    // MARK: Hilfen

    /// Datei relativ zur Repo-Wurzel lesen.
    ///
    /// `XCTSkip` NUR, wenn die Repo-Wurzel selbst nicht erreichbar ist (das
    /// Package woanders ausgecheckt) — dann kann der Vergleich prinzipiell nicht
    /// laufen. Steht die Wurzel und fehlt die Datei, ist sie umbenannt oder
    /// verschoben worden: dann MUSS der Test rot werden, sonst überspringt sich
    /// genau die Drift weg, die er abfangen soll.
    private func repoFile(_ relativePath: String) throws -> String {
        // #filePath = <repo>/SimCore/Tests/SimCoreTests/WaterRenderTests.swift
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let marker = root.appendingPathComponent("AGENTS.md")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw XCTSkip("Repo-Wurzel nicht erreichbar (\(root.path) ohne AGENTS.md)")
        }
        let url = root.appendingPathComponent(relativePath)
        return try XCTUnwrap(try? String(contentsOf: url, encoding: .utf8),
                             "\(relativePath) fehlt oder ist umbenannt — die "
                             + "Kalibrierung wäre damit ungeprüft")
    }

    private func assertContains(_ haystack: String, _ needle: String, hint: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(haystack.contains(needle),
                      "\(hint) — erwartet im Quelltext: \(needle)", file: file, line: line)
    }
}
