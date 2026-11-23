import XCTest
@testable import SimCore

final class WorldSnapshotTests: XCTestCase {
    func testSnapshotKeepsThePartialBeltCouplingClock() throws {
        var c = renderConfig(n: 128)
        c.meanderBeltMinCells = 100
        let original = Terrain(config: c, seed: 1337)
        original.step(dtYears: 375)
        XCTAssertEqual(original.state.beltCouplingCarry, 375)
        let loaded = try WorldSnapshot.decode(WorldSnapshot.encode(original))
        for dt in [15.0, 100, 1000, 15, 100, 1000] {
            original.step(dtYears: dt)
            loaded.step(dtYears: dt)
            XCTAssertEqual(original.fingerprint(), loaded.fingerprint())
        }
    }

    private func cfg(n: Int = 256) -> SimConfig {
        var c = SimConfig()
        c.n = n; c.world = calibrationWorld
        c.meanderBeltMinCells = 100
        return c
    }

    private func tempPath(_ name: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).\(WorldSnapshot.fileExtension)")
            .path
    }

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
        XCTAssertEqual(a.beltCouplingCarry.bitPattern, b.beltCouplingCarry.bitPattern,
                       "\(ctx): beltCouplingCarry", file: file, line: line)
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

    private func usedWorld(_ config: SimConfig, seed: UInt32) -> Terrain {
        let t = Terrain(config: config, seed: seed)
        t.step(dtYears: 300)
        t.step(dtYears: 300)
        let mid = Double(config.n / 2)
        t.pickaxe(gx: mid, gz: mid, radiusWorld: 8, strength: 2)
        t.flatten(gx: mid * 0.6, gz: mid * 1.2, radiusWorld: 10,
                  targetHeight: config.sea + 0.25, strength: 2)
        t.computeFlow()
        t.snapWaterLevel()
        t.step(dtYears: 200)
        return t
    }

    func testRoundTripContinuesBitIdentically() throws {
        let config = cfg()
        let t = usedWorld(config, seed: 4711)

        XCTAssertTrue(t.disturb.contains { $0 > 0 }, "Störungszustand (#26) ist leer")
        XCTAssertFalse(t.meander.channels.isEmpty, "keine Mäander-Zentrumslinien")
        XCTAssertTrue(t.streamMap.contains { $0 > 0.01 }, "Stream-Map ist leer")
        XCTAssertTrue(t.sed.contains { $0 > 0 }, "kein Sediment")
        XCTAssertTrue(t.snow.contains { $0 > 0.01 }, "Schneefeld ist leer")
        XCTAssertNotEqual(t.snow.min(), t.snow.max(), "Schneefeld ist konstant")
        XCTAssertNotEqual(t.temperature.min(), t.temperature.max(),
                          "Temperaturfeld ist konstant")

        print("[SNAPSHOT] Kanäle=\(t.meander.channels.count) "
              + "Altarme=\(t.meander.oxbows.count)")

        let before = t.state
        let path = tempPath("roundtrip")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let size = try WorldSnapshot.write(t, to: path)
        XCTAssertGreaterThan(size, 0)

        let loaded = try WorldSnapshot.read(from: path)
        assertSameState(before, loaded.state, "direkt nach dem Laden")
        XCTAssertEqual(loaded.cfg, config, "Config muss mitreisen")

        for dt in [150.0, 40.0, 700.0] {
            t.step(dtYears: dt)
            loaded.step(dtYears: dt)
        }
        assertSameState(t.state, loaded.state, "nach 3 weiteren Schritten")
        XCTAssertEqual(t.years, loaded.years)
    }

    func testMeanderHistorySurvivesRoundTrip() throws {
        var config = cfg(n: 96)
        config.meanderBelt = calibrationMeanderBelt
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

    func testSaveLoadSaveIsByteIdentical() throws {
        let t = usedWorld(cfg(n: 128), seed: 99)
        let first = try WorldSnapshot.encode(t)
        let reloaded = try WorldSnapshot.decode(first)
        let second = try WorldSnapshot.encode(reloaded)
        XCTAssertEqual(first, second, "Speichern → Laden → Speichern muss byte-identisch sein")
    }

    func testWaterLevelIsImmediatelyCorrectAfterLoad() throws {
        let config = cfg()
        let t = Terrain(config: config, seed: 1337)
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
        assertBitEqual(t.state.lakeBalance, loaded.state.lakeBalance, "lakeBalance",
                       "nach dem Laden")
    }

    func testOlderFormatVersionIsRejected() throws {
        let t = Terrain(config: cfg(n: 96), seed: 7)
        var data = try WorldSnapshot.encode(t)
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
        XCTAssertThrowsError(try WorldSnapshot.peekVersion(at: path))
    }

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

    func testPeekConfigGuardsCorruptedOrOversizedConfigLength() throws {
        let t = Terrain(config: cfg(n: 96), seed: 7)
        var data = try WorldSnapshot.encode(t)
        let badLengthBytes: [UInt8] = [0xFF, 0xFF, 0xFF, 0x7F]
        data.replaceSubrange(28..<32, with: badLengthBytes)

        let path = tempPath("badconfiglen")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try data.write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(try WorldSnapshot.peekConfig(at: path)) { error in
            guard case SnapshotError.truncated = error else {
                XCTFail("erwartet truncated bei übergroßer Config-Länge, bekam \(error)")
                return
            }
        }
    }

    func testPeekRejectsNonExistentFile() {
        let path = tempPath("nonexistent")
        XCTAssertThrowsError(try WorldSnapshot.peekVersion(at: path)) { error in
            guard case SnapshotError.readFailed = error else {
                XCTFail("erwartet readFailed, bekam \(error)")
                return
            }
        }
        XCTAssertThrowsError(try WorldSnapshot.peekConfig(at: path)) { error in
            guard case SnapshotError.readFailed = error else {
                XCTFail("erwartet readFailed, bekam \(error)")
                return
            }
        }
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

        XCTAssertThrowsError(try WorldSnapshot.decode(data[0..<(data.count / 2)])) { error in
            guard case SnapshotError.truncated = error else {
                XCTFail("erwartet truncated, bekam \(error)")
                return
            }
        }

        var corruptLength = data
        let maxLenBytes: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        corruptLength.replaceSubrange(12..<20, with: maxLenBytes)
        XCTAssertThrowsError(try WorldSnapshot.decode(corruptLength)) { error in
            guard case SnapshotError.truncated = error else {
                XCTFail("erwartet truncated bei UInt64.max Nutzdatenlänge, bekam \(error)")
                return
            }
        }

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

    func testDeviatingConfigAndSeedTravelWithTheWorld() throws {
        var config = cfg(n: 128)
        config.world = 40
        config.lithologyEnabled = false
        config.rainWeightedFlow = false
        config.climateEnabled = false
        config.meanderEnabled = false
        config.braidingEnabled = false
        config.outletErode = 7.5e-5
        config.heightBandsOverride = .legacyAbsolute
        let seed: UInt32 = 0xC0FF_EE01

        let t = Terrain(config: config, seed: seed)
        t.step(dtYears: 250)
        XCTAssertTrue(t.state.lithHardness.isEmpty, "Testaufbau: Lithologie ist nicht aus")
        XCTAssertTrue(t.state.rainWeight.isEmpty, "Testaufbau: Regen-Gewichtung ist nicht aus")
        XCTAssertTrue(t.state.temperature.isEmpty && t.state.snow.isEmpty
                      && t.state.ice.isEmpty, "Testaufbau: Klima ist nicht aus")

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
        XCTAssertTrue(a.state.temperature.isEmpty && a.state.snow.isEmpty
                      && a.state.ice.isEmpty, "leeres Kryo-Feld kam nicht leer zurück")

        a.step(dtYears: 400)
        b.step(dtYears: 400)
        assertSameState(a.state, b.state, "zwei Ladungen derselben Welt")
        t.step(dtYears: 400)
        assertSameState(t.state, a.state, "geladen gegen durchgehend simuliert")
    }

    func testConfigSurvivesEncodingExactly() throws {
        var config = SimConfig()
        config.kRock = 1.0 / 3.0
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

    func testConfigWithoutTheSillCutKeyDoesNotDecode() throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let config = SimConfig()
        var blob = try PropertyListSerialization.propertyList(
            from: try encoder.encode(config), options: [], format: nil) as! [String: Any]
        XCTAssertNotNil(blob.removeValue(forKey: "meanderBeltSillCutDepths"),
                      "Schlüssel fehlt im Plist — Feldname geändert?")
        let stripped = try PropertyListSerialization.data(
            fromPropertyList: blob, format: .binary, options: 0)
        XCTAssertThrowsError(try PropertyListDecoder().decode(SimConfig.self, from: stripped)) { error in
            XCTAssertTrue("\(error)".contains("meanderBeltSillCutDepths"),
                          "Dekodierungs-Fehler nennt den fehlenden Schlüssel nicht: \(error)")
        }
    }

    func testEveryPreErosionParameterIsSerialisedAndCompared() throws {
        let disturbances: [(field: String, apply: (inout ErosionFilter.Params) -> Void)] = [
            ("strength", { $0.strength = 0.37 }),
            ("gullyWeight", { $0.gullyWeight = 0.41 }),
            ("detail", { $0.detail = 2.75 }),
            ("rounding", { $0.rounding = (0.31, 0.43, 0.57, 3.25) }),
            ("onset", { $0.onset = (2.25, 3.5, 4.75, 5.5) }),
            ("assumedSlope", { $0.assumedSlope = (0.35, 0.65) }),
            ("scale", { $0.scale = 0.135 }),
            ("octaves", { $0.octaves = 7 }),
            ("lacunarity", { $0.lacunarity = 2.75 }),
            ("gain", { $0.gain = 0.375 }),
            ("cellScale", { $0.cellScale = 0.45 }),
            ("normalization", { $0.normalization = 0.875 }),
        ]
        let base = ErosionFilter.Params()
        let fields = Mirror(reflecting: base).children.compactMap { $0.label }
        let listed = Set(disturbances.map { $0.field })
        for field in fields {
            XCTAssertTrue(listed.contains(field),
                          "ErosionFilter.Params.\(field) hat keine Störung in diesem "
                          + "Wächter — die handgeschriebene Serialisierung wäre "
                          + "dafür blind")
        }
        XCTAssertEqual(disturbances.count, fields.count,
                       "Störtabelle und Feldbestand sind auseinandergelaufen")

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        for (field, apply) in disturbances {
            var disturbed = base
            apply(&disturbed)
            XCTAssertNotEqual(disturbed, base,
                              "\(field): `==` vergleicht das Feld nicht — ein Verlust "
                              + "beim Speichern bliebe unsichtbar")
            let back = try PropertyListDecoder().decode(
                ErosionFilter.Params.self, from: try encoder.encode(disturbed))
            XCTAssertEqual(back, disturbed,
                           "\(field): überlebt den Round-Trip nicht — fehlt in "
                           + "CodingKeys/`init(from:)`/`encode(to:)`")
        }
    }

    func testConstantFieldsAreStoredCompactly() throws {
        let config = cfg(n: 128)
        let t = Terrain(config: config, seed: 3)
        let size = try WorldSnapshot.encode(t).count
        let cells = config.count
        print(String(format: "[SNAPSHOT] n=%d: %d Byte = %.1f Byte/Zelle "
                     + "→ n=832 ≈ %.0f MB",
                     config.n, size, Double(size) / Double(cells),
                     Double(size) / Double(cells) * 832 * 832 / (1024 * 1024)))
        XCTAssertLessThan(size, cells * 210, "konstante Felder wurden nicht verdichtet")
        XCTAssertGreaterThan(size, cells * 120, "verdächtig klein — fehlen Felder?")
    }
}
