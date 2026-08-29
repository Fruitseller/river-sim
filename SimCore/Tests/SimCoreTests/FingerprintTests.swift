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
final class FingerprintTests: XCTestCase {

    private func makeState() -> TerrainState {
        var c = SimConfig()
        c.n = 96; c.world = calibrationWorld
        let t = Terrain(config: c, seed: 99)
        // Ein Schritt, damit die Pässe möglichst viele Felder füllen; leere
        // Felder (abgeschaltete Physik) behandelt der Test unten trotzdem.
        t.step(dtYears: 1000)
        return t.state
    }

    /// Stört ein Element um genau ein Bit — die kleinste mögliche Abweichung,
    /// die der Fingerabdruck sehen muss (ulp-Empfindlichkeit).
    private func assertDetects(_ name: String, base: TerrainState,
                               baseline: UInt64,
                               _ perturb: (inout TerrainState) -> Void,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        var s = base
        perturb(&s)
        XCTAssertNotEqual(s.fingerprint(), baseline,
                          "Fingerprint ist blind für \(name)",
                          file: file, line: line)
    }

    func testFingerprintCoversEveryInventoryField() {
        let base = makeState()
        let baseline = base.fingerprint()

        for f in WorldSnapshot.doubleFields {
            assertDetects(f.name, base: base, baseline: baseline) { s in
                if s[keyPath: f.path].isEmpty {
                    // Abgeschaltete Physik: „Feld vorhanden" muss sich vom
                    // leeren Feld unterscheiden (Längen-Präfix im Hasher).
                    s[keyPath: f.path] = [1.0]
                } else {
                    let v = s[keyPath: f.path][0]
                    s[keyPath: f.path][0] = Double(bitPattern: v.bitPattern ^ 1)
                }
            }
        }
        for f in WorldSnapshot.int32Fields {
            assertDetects(f.name, base: base, baseline: baseline) { s in
                if s[keyPath: f.path].isEmpty { s[keyPath: f.path] = [1] }
                else { s[keyPath: f.path][0] ^= 1 }
            }
        }
        for f in WorldSnapshot.uint8Fields {
            assertDetects(f.name, base: base, baseline: baseline) { s in
                if s[keyPath: f.path].isEmpty { s[keyPath: f.path] = [1] }
                else { s[keyPath: f.path][0] ^= 1 }
            }
        }
        for f in WorldSnapshot.boolFields {
            assertDetects(f.name, base: base, baseline: baseline) { s in
                if s[keyPath: f.path].isEmpty { s[keyPath: f.path] = [true] }
                else { s[keyPath: f.path][0].toggle() }
            }
        }
    }

    /// Die Bestandteile, die NICHT in den Feldtabellen stehen: Skalar-Block,
    /// Höhenbänder und der Mäander-Block (dieselbe Abdeckung wie `encode()`).
    func testFingerprintCoversScalarsAndMeander() {
        let base = makeState()
        let baseline = base.fingerprint()

        assertDetects("seed", base: base, baseline: baseline) { $0.seed ^= 1 }
        assertDetects("years", base: base, baseline: baseline) {
            $0.years = Double(bitPattern: $0.years.bitPattern ^ 1)
        }
        assertDetects("dropsEmitted", base: base, baseline: baseline) { $0.dropsEmitted ^= 1 }
        assertDetects("dropCarry", base: base, baseline: baseline) {
            $0.dropCarry = Double(bitPattern: $0.dropCarry.bitPattern ^ 1)
        }
        assertDetects("flowStepCount", base: base, baseline: baseline) { $0.flowStepCount ^= 1 }
        assertDetects("disturbActive", base: base, baseline: baseline) { $0.disturbActive.toggle() }
        assertDetects("heightBands", base: base, baseline: baseline) {
            $0.heightBands.vegFull = Double(bitPattern: $0.heightBands.vegFull.bitPattern ^ 1)
        }
        assertDetects("meanderChannels", base: base, baseline: baseline) { s in
            if var ch = s.meanderChannels.first, !ch.nodes.isEmpty {
                ch.nodes[0].x = Double(bitPattern: ch.nodes[0].x.bitPattern ^ 1)
                s.meanderChannels[0] = ch
            } else {
                s.meanderChannels.append(RiverChannel(
                    nodes: [MeanderNode(x: 1, z: 2)], discharge: [3]))
            }
        }
        // `discharge` GETRENNT stören: es geht als eigener Block in den Hash,
        // eine Knoten-Störung allein beweist seine Abdeckung nicht.
        assertDetects("meanderDischarge", base: base, baseline: baseline) { s in
            if var ch = s.meanderChannels.first, !ch.discharge.isEmpty {
                ch.discharge[0] = Double(bitPattern: ch.discharge[0].bitPattern ^ 1)
                s.meanderChannels[0] = ch
            } else {
                s.meanderChannels.append(RiverChannel(
                    nodes: [MeanderNode(x: 1, z: 2)], discharge: [3]))
            }
        }
        assertDetects("oxbows", base: base, baseline: baseline) { s in
            if !s.oxbows.isEmpty, !s.oxbows[0].isEmpty {
                s.oxbows[0][0].x = Double(bitPattern: s.oxbows[0][0].x.bitPattern ^ 1)
            } else {
                s.oxbows.append([MeanderNode(x: 1, z: 2)])
            }
        }
        assertDetects("oxbowAge", base: base, baseline: baseline) { s in
            if s.oxbowAge.isEmpty { s.oxbowAge = [1] }
            else { s.oxbowAge[0] = Double(bitPattern: s.oxbowAge[0].bitPattern ^ 1) }
        }
    }

    /// `Terrain.fingerprint()` (der öffentliche Zugang für simperf) ist genau
    /// der Fingerabdruck des Zustands-Inventars, keine eigene Rechnung.
    func testTerrainWrapperMatchesStateFingerprint() {
        var c = SimConfig()
        c.n = 96; c.world = calibrationWorld
        let t = Terrain(config: c, seed: 7)
        t.step(dtYears: 500)
        XCTAssertEqual(t.fingerprint(), t.state.fingerprint())
    }
}
