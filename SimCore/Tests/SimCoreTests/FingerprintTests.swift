import XCTest
@testable import SimCore

/// Wächter des Zustands-Fingerabdrucks (Issue #78): `TerrainState.fingerprint()`
/// muss auf JEDES Feld des Inventars reagieren, sonst meldet `simperf --hash`
/// bzw. `testDeterminism` „identisch", obwohl ein Refactor den Zustand
/// verändert hat — genau die Lücke, die #78 schließt (vorher: 8 handgepflegte
/// Felder).
///
/// Iteriert die Feldtabellen aus `WorldSnapshot` selbst, keine zweite Liste:
/// ein neu ins Inventar aufgenommenes Feld ist damit automatisch mitgeprüft.
/// Für die NICHT tabellierten Bestandteile (Skalare, Höhenbänder, Mäander)
/// sichert `testEveryStoredPropertyIsAccountedFor` die Vollständigkeit.
final class FingerprintTests: XCTestCase {

    private func makeTerrain() -> Terrain {
        var c = SimConfig()
        c.n = 96; c.world = calibrationWorld
        let t = Terrain(config: c, seed: 99)
        // Ein Schritt, damit die Pässe möglichst viele Felder füllen; leere
        // Felder (abgeschaltete Physik) behandelt der Feld-Helfer unten.
        t.step(dtYears: 1000)
        return t
    }

    /// Kleinste mögliche Abweichung: ein Bit im Mantissen-LSB (ulp-Empfindlichkeit).
    private func ulpFlip(_ v: Double) -> Double { Double(bitPattern: v.bitPattern ^ 1) }

    private func assertDetects(_ name: String, base: TerrainState,
                               baseline: UInt64,
                               file: StaticString = #filePath, line: UInt = #line,
                               _ perturb: (inout TerrainState) -> Void) {
        var s = base
        perturb(&s)
        XCTAssertNotEqual(s.fingerprint(), baseline,
                          "Fingerprint ist blind für \(name)",
                          file: file, line: line)
    }

    /// Ein tabelliertes Feld stören: Element 0 kippen — oder, bei abgeschalteter
    /// Physik (leeres Feld), das Feld „anschalten": beides muss der Hasher
    /// sehen (Längen-Präfix).
    private func assertDetectsField<T>(_ f: WorldSnapshot.FieldSpec<T>,
                                       base: TerrainState, baseline: UInt64,
                                       seed: T, flip: (T) -> T,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) {
        assertDetects(f.name, base: base, baseline: baseline,
                      file: file, line: line) { s in
            if s[keyPath: f.path].isEmpty { s[keyPath: f.path] = [seed] }
            else { s[keyPath: f.path][0] = flip(s[keyPath: f.path][0]) }
        }
    }

    func testFingerprintCoversEveryInventoryField() {
        let t = makeTerrain()
        let base = t.state
        let baseline = base.fingerprint()
        // Der öffentliche Zugang für simperf ist genau dieser Fingerabdruck,
        // keine eigene Rechnung.
        XCTAssertEqual(t.fingerprint(), baseline)

        for f in WorldSnapshot.doubleFields {
            assertDetectsField(f, base: base, baseline: baseline, seed: 1.0, flip: ulpFlip)
        }
        for f in WorldSnapshot.int32Fields {
            assertDetectsField(f, base: base, baseline: baseline, seed: 1) { $0 ^ 1 }
        }
        for f in WorldSnapshot.uint8Fields {
            assertDetectsField(f, base: base, baseline: baseline, seed: 1) { $0 ^ 1 }
        }
        for f in WorldSnapshot.boolFields {
            assertDetectsField(f, base: base, baseline: baseline, seed: true) { !$0 }
        }
    }

    /// Die Bestandteile, die NICHT in den Feldtabellen stehen: Skalar-Block,
    /// Höhenbänder und der Mäander-Block (dieselbe Abdeckung wie `encode()`).
    func testFingerprintCoversScalarsAndMeander() {
        var base = makeTerrain().state
        // Für die Mäander-Proben muss es einen Lauf/Altarm mit Knoten geben;
        // baut die Test-Config keinen, wird einer eingesetzt.
        if base.meanderChannels.first?.nodes.isEmpty != false {
            base.meanderChannels = [RiverChannel(nodes: [MeanderNode(x: 1, z: 2)],
                                                 discharge: [3])]
        }
        if base.oxbows.first?.isEmpty != false {
            base.oxbows = [[MeanderNode(x: 1, z: 2)]]
            base.oxbowAge = [1]
        }
        let baseline = base.fingerprint()

        assertDetects("seed", base: base, baseline: baseline) { $0.seed ^= 1 }
        assertDetects("years", base: base, baseline: baseline) { $0.years = ulpFlip($0.years) }
        assertDetects("dropsEmitted", base: base, baseline: baseline) { $0.dropsEmitted ^= 1 }
        assertDetects("dropCarry", base: base, baseline: baseline) { $0.dropCarry = ulpFlip($0.dropCarry) }
        assertDetects("flowStepCount", base: base, baseline: baseline) { $0.flowStepCount ^= 1 }
        assertDetects("disturbActive", base: base, baseline: baseline) { $0.disturbActive.toggle() }
        assertDetects("heightBands", base: base, baseline: baseline) {
            $0.heightBands.vegFull = ulpFlip($0.heightBands.vegFull)
        }
        assertDetects("meanderChannels", base: base, baseline: baseline) {
            $0.meanderChannels[0].nodes[0].x = ulpFlip($0.meanderChannels[0].nodes[0].x)
        }
        // `discharge` GETRENNT stören: es geht als eigener Block in den Hash,
        // eine Knoten-Störung allein beweist seine Abdeckung nicht.
        assertDetects("meanderDischarge", base: base, baseline: baseline) {
            $0.meanderChannels[0].discharge[0] = ulpFlip($0.meanderChannels[0].discharge[0])
        }
        assertDetects("oxbows", base: base, baseline: baseline) {
            $0.oxbows[0][0].x = ulpFlip($0.oxbows[0][0].x)
        }
        assertDetects("oxbowAge", base: base, baseline: baseline) {
            $0.oxbowAge[0] = ulpFlip($0.oxbowAge[0])
        }
    }

    /// Vollständigkeits-Wächter für die Hand-Listen: JEDE gespeicherte
    /// Eigenschaft von `TerrainState` ist entweder in den vier Feldtabellen
    /// tabelliert oder hier als Skalar-/Mäander-Bestandteil benannt (beide
    /// Gruppen gehen in `fingerprint()` UND `encode()` ein). Ein neues Feld,
    /// das nirgends einsortiert wird, fällt damit HIER auf, statt still am
    /// Fingerprint und am Speicherformat vorbeizulaufen — sonst überlebte die
    /// #78-Lücke auf der untabellierten Hälfte.
    func testEveryStoredPropertyIsAccountedFor() {
        let tabled = Set(WorldSnapshot.doubleFields.map(\.name)
            + WorldSnapshot.int32Fields.map(\.name)
            + WorldSnapshot.uint8Fields.map(\.name)
            + WorldSnapshot.boolFields.map(\.name))
        // Die nicht tabellierten Bestandteile — genau sie tragen die
        // Hand-Listen in `encode()`, `fingerprint()` und dem Skalar-Test oben.
        let scalars: Set<String> = [
            "years", "seed", "dropsEmitted", "dropCarry", "flowStepCount",
            "disturbActive", "heightBands",
            "meanderChannels", "oxbows", "oxbowAge",
        ]
        for child in Mirror(reflecting: TerrainState()).children {
            guard let label = child.label else { continue }
            XCTAssertTrue(tabled.contains(label) || scalars.contains(label),
                          "TerrainState.\(label) ist weder tabelliert noch als "
                          + "Skalar-/Mäander-Bestandteil erfasst — Fingerprint und "
                          + "Speicherformat wären blind dafür (s. WorldSnapshot.swift)")
        }
    }
}
