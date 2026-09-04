import XCTest

@testable import SimCore

/// Quereinschnitt der Flussbetten (Issue #108).
///
/// Der Nutzer meldete: auf gealterten Welten liegt das Wasser ohne sichtbaren
/// Taleinschnitt auf dem Hang — der Boden hat keine Rinne, wo der Fluss läuft.
/// Die Diagnose des Issues lief als Godot-Skript über `SimNode`; hier steht
/// dieselbe Kennzahl headless in SimCore, weil Agenten die GDExtension nicht
/// bauen (AGENTS.md § Verifikation über CI) und die Kennzahl ohnehin eine
/// Sim-Aussage ist, keine Render-Aussage.
///
/// KENNZAHL: mittlerer Quereinschnitt = Mittel der Höhen ±2..3 Zellen SENKRECHT
/// zur D8-Fließrichtung minus der Zellhöhe, über alle Landzellen mit ≥ 1000
/// Zellen Einzugsgebiet. Positiv = das Bett liegt tiefer als seine Flanken (=
/// Rinne), 0 = das Bett liegt auf Umgebungsniveau (= der gemeldete Fehler).
/// In Welt-Y umgerechnet wird mit `RenderContract.heightScale`.
enum ChannelIncision {
    /// Ein Messpunkt der Kennzahl. `cells` ist die Stichprobengröße; sinkt sie
    /// stark, vergleicht man nicht mehr dasselbe Flussnetz.
    struct Sample {
        var cells: Int
        var incision: Double
        var channelH: Double
        var neighbourH: Double
    }

    /// Misst die Kennzahl auf dem aktuellen Zustand von `t`.
    /// Bewusst 1:1 die Formel aus dem Issue (gleiche Schwellen, gleiche Offsets),
    /// damit Vorher/Nachher gegen die dort dokumentierte Tabelle vergleichbar ist.
    static func measure(_ t: Terrain) -> Sample {
        let n = t.cfg.n
        let cs = t.cfg.cellSize
        let cellArea = cs * cs
        var sum = 0.0, chSum = 0.0, nbSum = 0.0, count = 0
        for k in 0..<t.cfg.count {
            if t.h[k] <= t.cfg.sea { continue }
            if t.area[k] / cellArea < 1000 { continue }
            let r = Int(t.receiver[k])
            if r < 0 || r == k { continue }
            // Senkrechte zur Fließrichtung: (qi, qj) ist die um 90° gedrehte
            // Verbindung Zelle → Empfänger.
            let qi = -((r / n) - (k / n))
            let qj = (r % n) - (k % n)
            let i = k % n, j = k / n
            var acc = 0.0, m = 0
            for s in [-3, -2, 2, 3] {
                let xi = i + qi * s, xj = j + qj * s
                if xi < 0 || xi >= n || xj < 0 || xj >= n { continue }
                acc += t.h[xj * n + xi]; m += 1
            }
            if m < 2 { continue }
            sum += acc / Double(m) - t.h[k]
            chSum += t.h[k]
            nbSum += acc / Double(m)
            count += 1
        }
        let d = Double(max(count, 1))
        return Sample(cells: count, incision: sum / d, channelH: chSum / d, neighbourH: nbSum / d)
    }

    /// Produktions-Config aus `SimConfig.productionDefaults()` (Single Source of Truth,
    /// synchron mit `SimNode.productionConfig()`).
    static func productionConfig() -> SimConfig {
        SimConfig.productionDefaults()
    }

    /// Einlauf der Generierung aus `SimConfig.productionSettleYears` (PR #106).
    static let settleYears = SimConfig.productionSettleYears
}

final class ChannelIncisionTests: XCTestCase {
    /// WÄCHTER (Issue #108): die beiden Hebel halten die Rinne offen, in der der
    /// Fluss läuft — gegen denselben Seed ohne sie (= Stand vor #108).
    ///
    /// Gemessen wird über die Zeit gemittelt und nicht als Schnappschuss: die
    /// Läufe wandern, und ein Einzelbild rauscht (dieselbe Bauform wie
    /// `testChannelBedSurvivesDroplets`). Kleines Grid, damit der Wächter in die
    /// Pflichtsuite passt; die Produktions-Messreihe steht im Diagnostic darunter
    /// und in `docs/channel-incision-measurements.md`.
    func testLeversKeepTheChannelIncised() {
        var sumOn = 0.0, sumOff = 0.0
        for seed in [UInt32(1337), 7, 99] {
            // ZELLGRÖSSE der Produktion, nicht `calibrationWorld`: die Schwelle
            // der Hebel zählt in ZELLEN Einzugsgebiet (`channelFlowMinCells`),
            // ihre physische Bedeutung hängt also an `cellSize`. Mit der
            // Suiten-Paarung (130/256 → 0.51 statt 0.156) deckt dieselbe
            // Zellzahl die vierfache Fläche ab, und der Effekt verschwindet im
            // Rauschen (gemessen ×1.38 / ×1.20 / ×1.00 über die drei Seeds).
            // Deshalb wandert hier `world` mit `n`, wie es AGENTS.md verlangt.
            var cOn = SimConfig(); cOn.n = 256
            cOn.world = SimConfig().cellSize * Double(cOn.n - 1)
            var cOff = cOn
            cOff.channelDiffusionDamp = 1.0   // Kanal-Schutz der Diffusion aus
            cOff.flowDepositDamp = 1.0        // Abfluss-Dämpfer der Deposition aus
            let tOn = Terrain(config: cOn, seed: seed)
            let tOff = Terrain(config: cOff, seed: seed)
            var on = 0.0, off = 0.0, samples = 0.0
            while tOn.years < 20_000 - 1e-6 {
                tOn.step(dtYears: 1000); tOff.step(dtYears: 1000)
                if Int(tOn.years) % 4000 != 0 { continue }
                on += ChannelIncision.measure(tOn).incision
                off += ChannelIncision.measure(tOff).incision
                samples += 1
            }
            on /= samples; off /= samples
            print(String(format: "[INCISION] Wächter n=256 seed=%d: an=%.5f aus=%.5f (×%.2f)",
                         seed, on, off, on / max(off, 1e-12)))
            sumOn += on; sumOff += off
            // Terrain bleibt gesund (dieselben Schwellen wie LongRunCollapse).
            XCTAssertLessThan(tOn.maxHeight(), 1.0, "Terrain-Runaway unter den Kanal-Hebeln")
            // Relief RELATIV zum Arm ohne Hebel: die absolute Schwelle von
            // `LongRunCollapse` gilt für die Produktions-Weltgröße, hier läuft
            // ein Ausschnitt davon (s. `world` oben). Die Aussage, die dieser
            // Wächter braucht, ist ohnehin die relative: die Hebel dürfen das
            // Terrain nicht einebnen.
            XCTAssertGreaterThan(tOn.landRelief(), tOff.landRelief() * 0.9,
                                 "Terrain eingeebnet unter den Kanal-Hebeln")
        }
        // 1) Überhaupt eine Rinne: das Bett liegt unter seinen Flanken.
        XCTAssertGreaterThan(sumOn, 0, "Flussbetten liegen auf Umgebungsniveau (Issue #108)")
        // 2) …und deutlich tiefer als ohne die Hebel: über die drei Seeds
        //    zusammen gemessen ×1.33 (einzeln 1.57 / 1.27 / 1.00 — Seed 99 hat auf
        //    diesem Ausschnitt keine große Rinne, deshalb wird die SUMME geprüft
        //    und nicht jeder Seed). Auf dem Produktionsgrid über 100k Jahre steht
        //    der Faktor bei 1.5…3.0 (Diagnostic darunter). Die Schranke soll
        //    „Hebel wirkt nicht mehr" fangen, nicht den Arbeitspunkt festnageln.
        XCTAssertGreaterThan(sumOn, sumOff * 1.20, "die Kanal-Hebel wirken nicht")
    }

    /// MESSLAUF (Issue #108): Quereinschnitt über 100k Jahre, Produktions-Config,
    /// Seed 1337 — die Vorher/Nachher-Tabelle des Issues und des PRs.
    /// Laufzeit ~6 min (n = 720, 100 Schritte à 1000 Jahre plus Einlauf).
    func testCrossIncisionOverTimeDiagnostic() throws {
        try skipUnlessMeasuring()
        let seed = UInt32(ProcessInfo.processInfo.environment["RS_SEED"].flatMap { UInt32($0) } ?? 1337)
        let years = Double(ProcessInfo.processInfo.environment["RS_YEARS"].flatMap { Double($0) } ?? 100_000)
        let t = Terrain(config: ChannelIncision.productionConfig(), seed: seed,
                        settleYears: ChannelIncision.settleYears)
        let scale = RenderContract.heightScale
        func line(_ label: String) {
            let s = ChannelIncision.measure(t)
            print(String(format: "[INCISION] seed=%d %@ zellen=%d quereinschnitt=%.5f welt_y=%.3f kanal_h=%.4f nachbar_h=%.4f",
                         seed, label, s.cells, s.incision, s.incision * scale, s.channelH, s.neighbourH))
        }
        line("jahr0")
        var stepped = 0.0
        while stepped < years - 1e-6 {
            t.step(dtYears: 1000)
            stepped += 1000
            if Int(stepped) % 25_000 == 0 { line(String(format: "jahr%dk", Int(stepped) / 1000)) }
        }
    }

    /// MESSLAUF (Issue #108): der A/B-Sweep über die drei Hebel gegen das
    /// zugeschüttete Bett. Jede Zeile ist ein Arm über 100k Jahre; „aus" heißt
    /// jeweils der Stand vor #108 (bit-identische Arithmetik). Das ist die
    /// Tabelle im PR und die Quelle der Kalibrier-Kommentare in `Config.swift`.
    /// Laufzeit ~3 min.
    func testIncisionLeverSweepDiagnostic() throws {
        try skipUnlessMeasuring()
        // (Label, Kanal-Schutz der Diffusion, Depositions-Dämpfer, Pfützen-Ausschluss)
        let arms: [(String, Double, Double, Bool)] = [
            ("beide aus (= vor #108) ", 1.0, 1.0, false),
            ("nur Diffusions-Schutz  ", 0.15, 1.0, false),
            ("nur Depositions-Dämpfer", 1.0, 0.15, false),
            ("beide an (= Produktion)", 0.15, 0.15, false),
            ("+ Pfützen (geparkt)    ", 0.15, 0.15, true),
        ]
        for (label, diff, dep, puddle) in arms {
            var c = ChannelIncision.productionConfig()
            c.channelDiffusionDamp = diff
            c.flowDepositDamp = dep
            c.puddleFillSkipsFlowCells = puddle
            let t = Terrain(config: c, seed: 1337, settleYears: ChannelIncision.settleYears)
            var out: [String] = []
            func take(_ y: Int) {
                let s = ChannelIncision.measure(t)
                out.append(String(format: "%dk:%.3f", y / 1000, s.incision * RenderContract.heightScale))
            }
            take(0)
            var stepped = 0
            while stepped < 100_000 {
                t.step(dtYears: 1000); stepped += 1000
                if stepped % 25_000 == 0 { take(stepped) }
            }
            print(String(format: "[SWEEP] %@ welt_y %@ | grat=%.4f relief=%.3f maxH=%.3f",
                         label, out.joined(separator: " "), t.ridgeCurvature(),
                         t.landRelief(), t.maxHeight()))
        }
    }
}
