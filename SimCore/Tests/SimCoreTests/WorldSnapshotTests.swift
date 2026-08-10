import XCTest
@testable import SimCore

/// Wächter des Welt-Speicherformats (Issue #8). Die stärkste Abnahme-Invariante
/// ist **Determinismus**: ein geladener Zustand muss bit-identisch weiterlaufen
/// wie eine durchgehend simulierte Welt. Fehlt ein Feld im Inventar
/// (`TerrainState` in Terrain.swift), divergieren die beiden Läufe — genau das
/// prüft `testRoundTripContinuesBitIdentically`.
///
/// Verglichen wird über die Feldtabellen aus `WorldSnapshot` selbst, nicht über
/// eine zweite Liste hier: ein neu aufgenommenes Feld ist damit automatisch Teil
/// des Wächters.
final class WorldSnapshotTests: XCTestCase {

    /// Produktionsphysik in Testauflösung. Bewusst ALLE Zustands-tragenden
    /// Systeme an (Mäander, Braiding, Lithologie, Regen-Gewichtung, Becken-
    /// Wasserhaushalt) — jedes davon führt eigenen Zustand, und nur wenn er
    /// mitreist, bleibt der Weiterlauf identisch.
    private func cfg(n: Int = 256) -> SimConfig {
        var c = SimConfig()
        c.n = n
        return c
    }

    private func tempPath(_ name: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).\(WorldSnapshot.fileExtension)")
            .path
    }

    // MARK: - Vergleichs-Helfer

    private func assertBitEqual(_ a: [Double], _ b: [Double], _ name: String,
                                _ ctx: String, file: StaticString = #filePath,
                                line: UInt = #line) {
        guard a.count == b.count else {
            XCTFail("\(ctx): \(name) hat \(b.count) statt \(a.count) Elemente",
                    file: file, line: line)
            return
        }
        for k in a.indices where a[k].bitPattern != b[k].bitPattern {
            XCTFail("\(ctx): \(name)[\(k)] = \(b[k]) statt \(a[k]) "
                    + "(Bitmuster \(b[k].bitPattern) statt \(a[k].bitPattern))",
                    file: file, line: line)
            return
        }
    }

    /// Vergleicht ZWEI Zustände vollständig — alle Felder des Inventars plus
    /// Zähler, Höhenbänder und Mäander-Zustand.
    private func assertSameState(_ a: TerrainState, _ b: TerrainState, _ ctx: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        for f in WorldSnapshot.doubleFields {
            assertBitEqual(a[keyPath: f.path], b[keyPath: f.path], f.name, ctx,
                           file: file, line: line)
        }
        for f in WorldSnapshot.int32Fields {
            XCTAssertEqual(a[keyPath: f.path], b[keyPath: f.path], "\(ctx): \(f.name)",
                           file: file, line: line)
        }
        for f in WorldSnapshot.uint8Fields {
            XCTAssertEqual(a[keyPath: f.path], b[keyPath: f.path], "\(ctx): \(f.name)",
                           file: file, line: line)
        }
        for f in WorldSnapshot.boolFields {
            XCTAssertEqual(a[keyPath: f.path], b[keyPath: f.path], "\(ctx): \(f.name)",
                           file: file, line: line)
        }
        XCTAssertEqual(a.years.bitPattern, b.years.bitPattern, "\(ctx): years",
                       file: file, line: line)
        XCTAssertEqual(a.seed, b.seed, "\(ctx): seed", file: file, line: line)
        XCTAssertEqual(a.dropsEmitted, b.dropsEmitted, "\(ctx): dropsEmitted",
                       file: file, line: line)
        XCTAssertEqual(a.dropCarry.bitPattern, b.dropCarry.bitPattern,
                       "\(ctx): dropCarry", file: file, line: line)
        XCTAssertEqual(a.flowStepCount, b.flowStepCount, "\(ctx): flowStepCount",
                       file: file, line: line)
        XCTAssertEqual(a.disturbActive, b.disturbActive, "\(ctx): disturbActive",
                       file: file, line: line)
        XCTAssertEqual(a.heightBands, b.heightBands, "\(ctx): heightBands",
                       file: file, line: line)

        XCTAssertEqual(a.meanderChannels.count, b.meanderChannels.count,
                       "\(ctx): Kanalzahl", file: file, line: line)
        for (i, ch) in a.meanderChannels.enumerated() where i < b.meanderChannels.count {
            let other = b.meanderChannels[i]
            XCTAssertEqual(ch.nodes, other.nodes, "\(ctx): Kanal \(i) Knoten",
                           file: file, line: line)
            assertBitEqual(ch.discharge, other.discharge, "Kanal \(i) Abfluss", ctx,
                           file: file, line: line)
        }
        XCTAssertEqual(a.oxbows.count, b.oxbows.count, "\(ctx): Altarmzahl",
                       file: file, line: line)
        for (i, ox) in a.oxbows.enumerated() where i < b.oxbows.count {
            XCTAssertEqual(ox, b.oxbows[i], "\(ctx): Altarm \(i)", file: file, line: line)
        }
        assertBitEqual(a.oxbowAge, b.oxbowAge, "oxbowAge", ctx, file: file, line: line)
    }

    /// Bringt eine Welt in einen „gebrauchten" Zustand: gealtert, mit
    /// Spieler-Eingriff (Störungs-/Regenerations-Zustand aus #26) und noch
    /// offener Regeneration.
    private func usedWorld(_ config: SimConfig, seed: UInt32) -> Terrain {
        let t = Terrain(config: config, seed: seed)
        t.step(dtYears: 300)
        t.step(dtYears: 300)
        // Eingriff mitten in die Insel: setzt disturb/regenPending und wirft den
        // Mäander-Zustand der alten Landschaft dort weg.
        let mid = Double(config.n / 2)
        t.pickaxe(gx: mid, gz: mid, radiusWorld: 8, strength: 2)
        t.flatten(gx: mid * 0.6, gz: mid * 1.2, radiusWorld: 10,
                  targetHeight: config.sea + 0.25, strength: 2)
        t.computeFlow()
        t.snapWaterLevel()
        t.step(dtYears: 200) // Regeneration angebrochen, aber nicht abgeschlossen
        return t
    }

    // MARK: - Abnahmepunkt 3: Round-Trip läuft bit-identisch weiter

    func testRoundTripContinuesBitIdentically() throws {
        let config = cfg()
        let t = usedWorld(config, seed: 4711)

        // Der Test wäre wertlos, wenn die interessanten Zustände leer wären.
        XCTAssertTrue(t.disturb.contains { $0 > 0 }, "Störungszustand (#26) ist leer")
        XCTAssertFalse(t.meander.channels.isEmpty, "keine Mäander-Zentrumslinien")
        XCTAssertTrue(t.streamMap.contains { $0 > 0.01 }, "Stream-Map ist leer")
        XCTAssertTrue(t.sed.contains { $0 > 0 }, "kein Sediment")

        print("[SNAPSHOT] Kanäle=\(t.meander.channels.count) "
              + "Altarme=\(t.meander.oxbows.count)")

        let before = t.state
        let path = tempPath("roundtrip")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let size = try WorldSnapshot.write(t, to: path)
        XCTAssertGreaterThan(size, 0)

        let loaded = try WorldSnapshot.read(from: path)
        // 1) Der geladene Zustand IST der gespeicherte (feldweise, bit-genau).
        assertSameState(before, loaded.state, "direkt nach dem Laden")
        XCTAssertEqual(loaded.cfg, config, "Config muss mitreisen")

        // 2) Und er läuft identisch weiter — mit ungleichen Schrittweiten, damit
        //    auch die dt-abhängigen Gedächtnis-Pfade (EWMA, Regeneration,
        //    Bilanz-Spiegel) durchlaufen.
        for dt in [150.0, 40.0, 700.0] {
            t.step(dtYears: dt)
            loaded.step(dtYears: dt)
        }
        assertSameState(t.state, loaded.state, "nach 3 weiteren Schritten")
        XCTAssertEqual(t.years, loaded.years)
    }

    /// Eigener Round-Trip für die **Mäander-Historie** (Abnahmepunkt 3 nennt sie
    /// ausdrücklich): der Produktionspfad braucht bei Testauflösung sehr lange
    /// bis zum ersten Cutoff (gemessen: 60 Läufe, 0 Altarme nach 800 Jahren bei
    /// n=256). Deshalb dieselbe gepinnte Kopplungs-Config wie die
    /// Mäander-Kernwächter (`meanderCfg()` in SimCoreTests: schnellere Migration,
    /// engerer Hals, Grid-Erosion statt Tropfen) — hier zählt nicht die
    /// Kalibrierung, sondern dass Altarme MIT ALTER mitreisen und weiter altern.
    func testMeanderHistorySurvivesRoundTrip() throws {
        var config = cfg(n: 96)
        config.hydraulicEnabled = false
        config.meanderMigration = 5.0e-5
        config.meanderNeckDist = 1.2
        config.meanderCohesion = 0
        config.upliftPer100y = 0.0015
        config.upliftDecayStartPer100y = 0
        config.upliftDecayFloorPer100y = 0
        config.lithologyEnabled = false
        config.heightBandsOverride = .legacyAbsolute

        let t = Terrain(config: config, seed: 111)
        var guardN = 0
        while t.meander.oxbows.count < 2 && guardN < 260 { t.step(dtYears: 500); guardN += 1 }
        XCTAssertGreaterThanOrEqual(t.meander.oxbows.count, 2,
                                    "Testaufbau: zu wenige Altarme entstanden")
        // Zwei Schritte weiter: das Altarm-ALTER wird erst im nächsten
        // Migrationsschritt hochgezählt, und es soll mit in die Datei.
        t.step(dtYears: 500)
        t.step(dtYears: 500)
        XCTAssertTrue(t.meander.oxbowAge.contains { $0 > 0 }, "Testaufbau: Altarme ohne Alter")

        let before = t.state
        let path = tempPath("meander")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try WorldSnapshot.write(t, to: path)
        let loaded = try WorldSnapshot.read(from: path)
        assertSameState(before, loaded.state, "Mäander-Historie nach dem Laden")

        for _ in 0..<4 {
            t.step(dtYears: 500)
            loaded.step(dtYears: 500)
        }
        assertSameState(t.state, loaded.state, "Mäander-Historie nach 4 Schritten")
    }

    /// Zweiter Round-Trip aus dem geladenen Zustand: eine Welt darf beliebig oft
    /// gespeichert und geladen werden, ohne zu driften (Datei → Datei ist
    /// byte-identisch).
    func testSaveLoadSaveIsByteIdentical() throws {
        let t = usedWorld(cfg(n: 128), seed: 99)
        let first = try WorldSnapshot.encode(t)
        let reloaded = try WorldSnapshot.decode(first)
        let second = try WorldSnapshot.encode(reloaded)
        XCTAssertEqual(first, second, "Speichern → Laden → Speichern muss byte-identisch sein")
    }

    // MARK: - Abnahmepunkt 5: Seespiegel ist sofort korrekt

    /// Der Darstellungs-Seespiegel `waterLevel` folgt `hf` nur ratenbegrenzt und
    /// ist damit ECHTER Zustand. Würde er beim Laden fehlen (0) oder auf `hf`
    /// geschnappt, sprängen die Seeflächen im ersten Frame bzw. schwängen über
    /// hunderte Jahre ein. Geprüft wird beides: der Pegel selbst UND dass sein
    /// Abstand zu `hf` (das Gedächtnis) erhalten bleibt.
    func testWaterLevelIsImmediatelyCorrectAfterLoad() throws {
        let config = cfg()
        let t = Terrain(config: config, seed: 1337)
        // Frisch nach der Generierung ist waterLevel == hf; ein Schritt mit
        // Auslass-Inzision zieht sie auseinander (genau das ist der Zustand).
        t.step(dtYears: 500)
        let gapBefore = zip(t.waterLevel, t.hf).map { abs($0 - $1) }.max() ?? 0
        XCTAssertGreaterThan(gapBefore, 0, "Testaufbau: waterLevel liegt nicht hinter hf")

        let path = tempPath("waterlevel")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try WorldSnapshot.write(t, to: path)
        let loaded = try WorldSnapshot.read(from: path)

        assertBitEqual(t.waterLevel, loaded.waterLevel, "waterLevel", "nach dem Laden")
        assertBitEqual(t.hf, loaded.hf, "hf", "nach dem Laden")
        let gapAfter = zip(loaded.waterLevel, loaded.hf).map { abs($0 - $1) }.max() ?? 0
        XCTAssertEqual(gapBefore, gapAfter, "Seespiegel-Gedächtnis verändert")
        // Auch der Bilanz-Spiegel abflussloser Becken (Issue #11) ist ein
        // ratenbegrenzter Zustand — er darf beim Laden nicht neu einschwingen.
        assertBitEqual(t.state.lakeBalance, loaded.state.lakeBalance, "lakeBalance",
                       "nach dem Laden")
    }

    // MARK: - Abnahmepunkt 2: Version und Integrität

    func testOlderFormatVersionIsRejected() throws {
        let t = Terrain(config: cfg(n: 96), seed: 7)
        var data = try WorldSnapshot.encode(t)
        // Version im Kopf auf 0 (= „ältere Version") setzen. Die Prüfsumme im Kopf
        // bleibt gültig, damit der Test wirklich die VERSION prüft.
        data.replaceSubrange(8..<12, with: [0, 0, 0, 0])
        let path = tempPath("oldversion")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try data.write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(try WorldSnapshot.read(from: path)) { error in
            guard case let SnapshotError.unsupportedVersion(found, expected) = error else {
                XCTFail("erwartet unsupportedVersion, bekam \(error)")
                return
            }
            XCTAssertEqual(found, 0)
            XCTAssertEqual(expected, WorldSnapshot.version)
            XCTAssertTrue("\(error)".contains("Version"), "Meldung nennt die Version nicht")
        }
        // Die Vorprüfung meldet dasselbe, ohne die Nutzdaten zu lesen.
        XCTAssertThrowsError(try WorldSnapshot.peekVersion(at: path))
    }

    /// Vorprüfung ohne Vollladen: Version und Config stehen am Dateianfang, damit
    /// ein Frontend entscheiden kann, ob es die Welt darstellen kann (`Main.gd`
    /// prüft so die Gitterauflösung, bevor es die laufende Welt ersetzt).
    func testPeekReadsHeaderWithoutLoadingFields() throws {
        var config = cfg(n: 96)
        config.outletErode = 4.25e-5
        let t = Terrain(config: config, seed: 21)
        let path = tempPath("peek")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try WorldSnapshot.write(t, to: path)

        XCTAssertEqual(try WorldSnapshot.peekVersion(at: path), WorldSnapshot.version)
        XCTAssertEqual(try WorldSnapshot.peekConfig(at: path), config)
    }

    func testForeignFileIsRejected() throws {
        let path = tempPath("foreign")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data("kein Spielstand, nur Text".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try WorldSnapshot.read(from: path)) { error in
            guard case SnapshotError.badMagic = error else {
                XCTFail("erwartet badMagic, bekam \(error)")
                return
            }
        }
    }

    func testTruncatedAndCorruptedFilesAreRejected() throws {
        let t = Terrain(config: cfg(n: 96), seed: 7)
        let data = try WorldSnapshot.encode(t)

        // Abgebrochen geschrieben (halbe Datei).
        XCTAssertThrowsError(try WorldSnapshot.decode(data[0..<(data.count / 2)])) { error in
            guard case SnapshotError.truncated = error else {
                XCTFail("erwartet truncated, bekam \(error)")
                return
            }
        }

        // Ein gekipptes Bit mitten in den Feldern.
        var flipped = data
        let mid = flipped.startIndex + flipped.count / 2
        flipped[mid] ^= 0x01
        XCTAssertThrowsError(try WorldSnapshot.decode(flipped)) { error in
            guard case SnapshotError.checksumMismatch = error else {
                XCTFail("erwartet checksumMismatch, bekam \(error)")
                return
            }
        }
    }

    // MARK: - Abnahmepunkt 4: Config und Seed reisen mit

    /// Eine Welt mit ABWEICHENDER Config lädt reproduzierbar: die Datei-Config
    /// ist autoritativ (s. `WorldSnapshot`-Doku), auch wenn sie von
    /// `SimConfig()` abweicht — inklusive der Feld-Inventar-Kanten, die
    /// abgeschaltete Physik erzeugt (leere Lithologie-/Regen-Gewichts-Felder).
    func testDeviatingConfigAndSeedTravelWithTheWorld() throws {
        var config = cfg(n: 128)
        config.world = 40                  // cellSize weicht bewusst vom Default ab
        config.lithologyEnabled = false    // → lithHardness/lithErodeK/… bleiben leer
        config.rainWeightedFlow = false    // → rainWeight bleibt leer
        config.meanderEnabled = false
        config.braidingEnabled = false
        config.outletErode = 7.5e-5
        config.heightBandsOverride = .legacyAbsolute
        let seed: UInt32 = 0xC0FF_EE01

        let t = Terrain(config: config, seed: seed)
        t.step(dtYears: 250)
        XCTAssertTrue(t.state.lithHardness.isEmpty, "Testaufbau: Lithologie ist nicht aus")
        XCTAssertTrue(t.state.rainWeight.isEmpty, "Testaufbau: Regen-Gewichtung ist nicht aus")

        let path = tempPath("config")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try WorldSnapshot.write(t, to: path)

        let a = try WorldSnapshot.read(from: path)
        let b = try WorldSnapshot.read(from: path)
        XCTAssertEqual(a.cfg, config, "die Datei-Config muss vollständig zurückkommen")
        XCTAssertNotEqual(a.cfg, SimConfig(), "Testaufbau: Config weicht nicht ab")
        XCTAssertEqual(a.state.seed, seed, "Seed muss mitreisen")
        XCTAssertEqual(a.cfg.heightBandsOverride, .legacyAbsolute,
                       "optionale Config-Felder müssen mitreisen")
        XCTAssertTrue(a.state.lithHardness.isEmpty, "leeres Feld kam nicht leer zurück")
        XCTAssertTrue(a.state.rainWeight.isEmpty, "leeres Feld kam nicht leer zurück")

        // Reproduzierbar: zwei Ladungen derselben Datei laufen identisch weiter.
        a.step(dtYears: 400)
        b.step(dtYears: 400)
        assertSameState(a.state, b.state, "zwei Ladungen derselben Welt")
        // …und identisch zur durchgehend simulierten Welt.
        t.step(dtYears: 400)
        assertSameState(t.state, a.state, "geladen gegen durchgehend simuliert")
    }

    /// Die Config-Serialisierung ist Codable-synthetisiert; dieser Wächter zeigt,
    /// dass dabei kein Feld verloren geht und `Double` bit-genau überlebt
    /// (binäres Plist speichert IEEE-754, nicht Dezimaltext).
    func testConfigSurvivesEncodingExactly() throws {
        var config = SimConfig()
        config.kRock = 1.0 / 3.0            // nicht binär darstellbare Dezimalzahl
        config.hydraulic.evaporate = .pi / 100
        config.preErodeParams.rounding = (0.1, 1e-17, -0.25, 2.0)
        config.preErodeParams.assumedSlope = (0.7, 1.0 / 7.0)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let back = try PropertyListDecoder().decode(SimConfig.self,
                                                    from: try encoder.encode(config))
        XCTAssertEqual(back, config)
        XCTAssertEqual(back.kRock.bitPattern, config.kRock.bitPattern)
        XCTAssertEqual(back.preErodeParams.rounding.1.bitPattern,
                       config.preErodeParams.rounding.1.bitPattern)
    }

    /// Die Datei bleibt auch für eine Welt ohne jeden Eingriff kompakt: Felder,
    /// die überall denselben Wert tragen (`disturb`, `regenPending` …), werden
    /// als EIN Wert gespeichert. Kein Rundungs-Kompromiss — nur weniger Bytes.
    func testConstantFieldsAreStoredCompactly() throws {
        let config = cfg(n: 128)
        let t = Terrain(config: config, seed: 3)
        let size = try WorldSnapshot.encode(t).count
        let cells = config.count
        // Messwert für docs/world-save-format.md (Hochrechnung auf n=832).
        print(String(format: "[SNAPSHOT] n=%d: %d Byte = %.1f Byte/Zelle "
                     + "→ n=832 ≈ %.0f MB",
                     config.n, size, Double(size) / Double(cells),
                     Double(size) / Double(cells) * 832 * 832 / (1024 * 1024)))
        // 23 Double-Felder + 3 Int32 + 2 UInt8 + 2 Bool wären ~200 Byte/Zelle;
        // die konstanten Felder (mind. disturb, regenPending) müssen fehlen.
        XCTAssertLessThan(size, cells * 200, "konstante Felder wurden nicht verdichtet")
        XCTAssertGreaterThan(size, cells * 100, "verdächtig klein — fehlen Felder?")
    }
}
