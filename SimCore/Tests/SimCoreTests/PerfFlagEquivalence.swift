import XCTest
@testable import SimCore

/// A/B-Wächter für den Produktions-Perf-Schalter `hydraulicSkipWaterSpawns`
/// (Issue #90): `SimNode.productionConfig()` schaltet ihn an, und AGENTS.md
/// sagte pauschal Verhaltensgleichheit der Perf-Schalter zu — belegt war sie
/// nur für `meanderSpatialCutoffIndex` (`testSpatialCutoffIndexMatchesReferenceOrder`).
///
/// Der A/B hier hat die Zusage widerlegt, nicht bestätigt: der Schalter
/// verwirft einen Tropfen, dessen Startzelle unter dem Meeresspiegel liegt
/// (`Hydraulic.erode`, `h[start] <= seaLevel`), GANZ — ohne ihn läuft derselbe
/// Tropfen los und erodiert Schelf und Meeresboden (nur im TIEFEN Wasser,
/// `hf−h > poolDepth`, stirbt er wirkungslos im Pool-Zweig). Schon der
/// Stream-Map-Spin-up der Generierung reicht den Schalter durch, und über das
/// veränderte Abflussfeld erreicht die Abweichung sofort auch das Land.
/// GEMESSEN (n=256, world=130, Seed 1337, 2026-08-31): nach der Generierung
/// 29 881 von 65 536 Zellen mit anderem `h` (davon 11 392 Land, max |Δh|
/// 0.085), nach 5 000 Jahren alle 65 536 — eine ANDERE Welt-Realisierung.
/// Ihr CHARAKTER bleibt gleichwertig: meanLand wich relativ um 2.8e-5
/// (Generierung) bis 4.4e-4 (10 000 Jahre) ab, die Landzellenzahl um ≤ 1.5e-3.
///
/// AGENTS.md und das Kalibrier-Logbuch (`SimConfig.hydraulicSkipWaterSpawns`)
/// sind mit #90 entsprechend korrigiert. Dieser Test pinnt BEIDE Richtungen
/// des Befunds; er wird nicht zu einem Gleichheits-Test aufgeweicht, solange
/// der Schalter Tropfen verwirft.
final class PerfFlagEquivalence: XCTestCase {

    func testSkipWaterSpawnsChangesTheRealizationNotTheCharacter() {
        var reference = SimConfig()
        reference.n = 256; reference.world = calibrationWorld
        var skipping = reference
        skipping.hydraulicSkipWaterSpawns = true

        let a = Terrain(config: reference, seed: 1337)
        let b = Terrain(config: skipping, seed: 1337)
        // Wird dieser Vergleich GLEICH, ist der Schalter neutral geworden:
        // dann diesen Test auf Fingerprint-Gleichheit umstellen und die
        // Korrekturen in AGENTS.md/Config.swift zurücknehmen.
        XCTAssertNotEqual(a.fingerprint(), b.fingerprint(),
                          "hydraulicSkipWaterSpawns war zur Generierung bisher "
                          + "NICHT bit-neutral (s. Kopfkommentar)")

        for _ in 1...10 {
            a.step(dtYears: 1000)
            b.step(dtYears: 1000)
        }
        XCTAssertNotEqual(a.fingerprint(), b.fingerprint(),
                          "hydraulicSkipWaterSpawns war nach 10 000 Jahren bisher "
                          + "NICHT bit-neutral (s. Kopfkommentar)")

        // Statistische Gleichwertigkeit: der Schalter darf die Realisierung
        // würfeln, aber nicht den Welt-Charakter verschieben. Schranke 0.005
        // = eine Größenordnung über der gemessenen Abweichung (s. o.), weit
        // unter dem Effekt eines echten Etat-Fehlers (der Tropfen-Etat auf
        // Land ist die Kalibrier-Basis, s. `SimConfig`-Logbuch zu #10).
        let (meanA, landA) = landStats(a)
        let (meanB, landB) = landStats(b)
        XCTAssertEqual(meanA, meanB, accuracy: 0.005 * meanA,
                       "meanLand driftet — der Schalter verschiebt die Physik, "
                       + "nicht nur die Realisierung")
        XCTAssertEqual(Double(landA), Double(landB), accuracy: 0.005 * Double(landA),
                       "Landzellenzahl driftet — der Schalter verschiebt die "
                       + "Küste, nicht nur die Realisierung")
    }

    /// Mittlere Landhöhe + Landzellenzahl (dieselbe Kennzahl wie die
    /// Baseline-Metriken, s. AGENTS.md „Erst headless messen").
    private func landStats(_ t: Terrain) -> (meanLand: Double, cells: Int) {
        var sum = 0.0, count = 0
        for k in 0..<t.cfg.count where t.h[k] > t.cfg.sea {
            sum += t.h[k]; count += 1
        }
        return (sum / Double(max(1, count)), count)
    }
}
