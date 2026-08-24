import Foundation
import SwiftGodot
import SimCore

/// Entwicklungs-Diagnose des Geländes (Issue #53 aus `SimNode` ausgelagert):
/// Kennzahlen-Vertrag für die Anzeige und die Differenz-Karte gegen einen
/// gesetzten Vergleichspunkt.
///
/// Der Vergleichspunkt ist der einzige Zustand hier — er macht sichtbar, ob
/// Relief durch Abtragung nur freigelegt oder durch Hebung/Ablagerung wirklich
/// aufgebaut wird. Die REGEL-Formeln (Relief-Signal, Servo, Gratkrümmung)
/// kommen aus SimCore selbst: die Anzeige darf sie nicht duplizieren, sonst
/// zeigt sie etwas anderes als wirkt.
final class TerrainDiagnostics {

    private var referenceHeights: [Double] = []
    private var referenceYear = 0.0

    /// Setzt den Vergleichspunkt auf den aktuellen Zustand. Das ist besonders
    /// nach manuellem Einebnen nützlich: danach zeigt die Differenzkarte
    /// ausschließlich, was die Simulation selbst auf- oder abgebaut hat.
    func capture(_ terrain: Terrain) {
        referenceHeights = terrain.h
        referenceYear = terrain.years
    }

    /// Kompakter Diagnosevertrag für GDScript (alles Float32, damit kein Dictionary-
    /// Marshalling im Renderpfad anfällt):
    /// min, mean, max, Landrelief, deltaMean, deltaMax, Volumen unter Referenz,
    /// Volumen über Referenz, Nettovolumen, maxAbtrag, maxAufbau, Relief-Servo/100 J.,
    /// abklingende Hebung U(t)/100 J., Reliefziel, Referenzjahr, ungültige Zellen,
    /// robustes Relief-Signal (das REGELSIGNAL des Servo-Bodens, p95 − Median),
    /// mittlere Grat-Krümmung (Alterungs-Kennzahl: negativ = spitz, → 0 = rund),
    /// Talseitenrelief (Median − p05, die Gegenprobe zum Regelsignal).
    ///
    /// Die Indizes dieser Reihenfolge stehen als `DBG_*` in `Main.gd`, ihre Zahl
    /// als `DEBUG_STATS_COUNT`; Wächter: `SimCoreTests/DiagStatsContractTests.swift`.
    func stats(_ terrain: Terrain) -> PackedFloat32Array {
        if referenceHeights.count != terrain.h.count { capture(terrain) }
        let h = terrain.h
        let reference = referenceHeights
        guard !h.isEmpty else { return PackedFloat32Array() }

        var minimum = Double.greatestFiniteMagnitude
        var maximum = -Double.greatestFiniteMagnitude
        var referenceMaximum = -Double.greatestFiniteMagnitude
        var sum = 0.0, referenceSum = 0.0
        var belowReference = 0.0, aboveReference = 0.0
        var maxRemoved = 0.0, maxAdded = 0.0
        var valid = 0, invalid = 0
        for k in h.indices {
            let value = h[k], baseline = reference[k]
            guard value.isFinite && baseline.isFinite else { invalid += 1; continue }
            minimum = min(minimum, value)
            maximum = max(maximum, value)
            referenceMaximum = max(referenceMaximum, baseline)
            sum += value
            referenceSum += baseline
            valid += 1
            let delta = value - baseline
            if delta >= 0 {
                aboveReference += delta
                maxAdded = max(maxAdded, delta)
            } else {
                belowReference -= delta
                maxRemoved = max(maxRemoved, -delta)
            }
        }
        if valid == 0 {
            minimum = 0; maximum = 0; referenceMaximum = 0
        }
        let divisor = Double(max(1, valid))
        let cellArea = terrain.cfg.cellSize * terrain.cfg.cellSize
        let relief = terrain.landRelief()
        // Regelsignal, Talseiten-Gegenprobe und Servo-Wert kommen aus SimCore
        // selbst — die Anzeige darf die Formeln nicht duplizieren, sonst zeigt sie
        // etwas anderes als wirkt.
        //
        // Alle drei hängen am SELBEN Quantil-Tripel der Landhöhen (p05, Median,
        // p95), deshalb EIN Histogramm-Pass statt drei: `landReliefRobust()`,
        // `landReliefLow()` und `reliefServoRate()` zählten je einen eigenen und
        // warfen die andere Hälfte weg — dieselbe Verteilung dreimal für dieselbe
        // Anzeige, gemessen ~1.4 ms je Pass bei n = 832 (`Terrain.updateHeightBands`).
        // `Terrain.landHeightQuantiles` ist genau für diesen Fall gebaut; die
        // angezeigten Werte sind unverändert.
        let halves = Terrain.landHeightQuantiles(heights: h, sea: terrain.cfg.sea)
        let reliefSignal = halves.high
        // Talseiten-Gegenprobe (Issue #26): das Regelsignal ist die HOCHseite
        // (p95 − Median). Nach einer großflächigen Einebnung bleibt sie lange
        // bei ~0, während sich die Fläche längst nach UNTEN differenziert —
        // ohne die zweite Hälfte liest die Diagnose das als „keine Erholung".
        let reliefLow = halves.low
        let servo = terrain.reliefServoRate(reliefSignal: reliefSignal)
        return PackedFloat32Array([
            Float(minimum), Float(sum / divisor), Float(maximum), Float(relief),
            Float((sum - referenceSum) / divisor), Float(maximum - referenceMaximum),
            Float(belowReference * cellArea), Float(aboveReference * cellArea),
            Float((aboveReference - belowReference) * cellArea), Float(maxRemoved), Float(maxAdded),
            Float(servo), Float(terrain.upliftDecayRatePer100y()), Float(terrain.cfg.reliefTarget),
            Float(referenceYear), Float(invalid), Float(reliefSignal),
            Float(terrain.ridgeCurvature()), Float(reliefLow),
        ])
    }

    /// Blau = unter der Referenz, hellgrau = unverändert, Rot = darüber. `scale`
    /// ist die Höhenänderung, bei der die Farbe voll gesättigt ist.
    func differenceBytes(_ terrain: Terrain, scale: Double) -> PackedByteArray {
        if referenceHeights.count != terrain.h.count { capture(terrain) }
        let h = terrain.h, reference = referenceHeights
        let safeScale = max(scale, 1e-9)
        var out = [UInt8](repeating: 255, count: h.count * 4)
        h.withUnsafeBufferPointer { hb in
        reference.withUnsafeBufferPointer { rb in
        out.withUnsafeMutableBufferPointer { ob in
            let ph = hb.baseAddress!, pref = rb.baseAddress!, pout = ob.baseAddress!
            parallelChunks(h.count) { lo, hi in
                for k in lo..<hi {
                    let delta = ph[k] - pref[k]
                    let amount = delta.isFinite
                        ? sqrt(min(1, abs(delta) / safeScale))
                        : 1
                    let neutral = 0.78
                    let r: Double, g: Double, b: Double
                    if !delta.isFinite {
                        (r, g, b) = (1.0, 0.0, 1.0) // Magenta = ungültiger Höhenwert
                    } else if delta >= 0 {
                        (r, g, b) = (neutral + 0.17 * amount,
                                     neutral - 0.55 * amount,
                                     neutral - 0.58 * amount)
                    } else {
                        (r, g, b) = (neutral - 0.58 * amount,
                                     neutral - 0.25 * amount,
                                     neutral + 0.17 * amount)
                    }
                    let o = k * 4
                    pout[o] = UInt8(min(max(r, 0), 1) * 255)
                    pout[o + 1] = UInt8(min(max(g, 0), 1) * 255)
                    pout[o + 2] = UInt8(min(max(b, 0), 1) * 255)
                }
            }
        }}}
        return PackedByteArray(out)
    }
}
