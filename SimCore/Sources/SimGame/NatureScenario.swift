import Foundation
import SimCore

/// Die Versuchskarte des Mutter-Natur-Prototyps (Issue #223): ein entworfenes,
/// kleines Flusstal statt eines gesuchten Seeds. Gleicher Aufruf → bit-gleicher
/// Startzustand (Determinismus pro Maschine wie die übrige Sim); „Neustart"
/// baut genau diesen Zustand neu.
///
/// Aufbau (Norden oben, `i` = Ost, `j` = Süd, Zellen):
/// - Im Norden ein Bergkessel, der in das HAUPTTAL (Mitte `mainX`) entwässert.
/// - Westlich daneben, getrennt nur durch einen schmalen Rücken, ein TIEFERES
///   Nebental (`westX`). Der Rücken hat zwei Sättel: einen niedrigen bei
///   `lowSaddleJ` (wenige Hiebe genügen) und einen höheren weiter oben bei
///   `highSaddleJ` (teurer, aber außer Reichweite der Talheimer Ausbesserer).
///   Ein Durchstich lenkt den Hauptfluss ins Nebental um — die D8-Entwässerung
///   der Sim tut das von selbst, sobald der Durchstich tiefer liegt als das
///   Bett daneben.
/// - Unterhalb der Sättel liegt das Haupttal schmal zwischen Rücken und einer
///   östlichen Kammlinie; was östlich davon fällt, entwässert über den
///   Kartenrand (der Sim-Rand ist Auslass, `priorityFlood`). So hat das Haupttal
///   unterhalb der Sättel nur ein kleines eigenes Einzugsgebiet, und eine
///   Umleitung trocknet es spürbar aus.
/// - Im Süden das Meer.
///
/// Drei Siedlungen: Oberau (oberhalb beider Sättel, bleibt versorgt),
/// Talheim (Ziel, unterhalb der Sättel am Hauptfluss) und Westfurt (im
/// Nebental, hat seinen eigenen Bach).
public enum NatureScenario {
    /// Rastergröße der Karte. `world` wächst mit, damit `cellSize` die
    /// kalibrierte Produktions-Zellgröße bleibt (AGENTS.md: `n` und `world`
    /// nur zusammen ändern).
    public static let n = 128
    public static let seed: UInt32 = 223
    /// Einlauf in echten Sim-Jahren, damit der Fluss sein Bett schon
    /// eingeschnitten hat und die Vegetation steht, bevor Jahr 0 beginnt.
    public static let settleYears = 200.0

    /// Produktions-Physik (`SimConfig.production`) auf der kleinen Karte.
    public static var config: SimConfig {
        var c = SimConfig.production
        let cell = SimConfig().cellSize
        c.n = n
        c.world = cell * Double(n - 1)
        return c
    }

    // MARK: Geometrie (Zellen)

    static let mainX = 80.0
    /// Abstand der Talachsen bei den Sätteln (Zellen).
    static let valleyGap = 14.0
    static let lowSaddleJ = 52.0
    static let highSaddleJ = 40.0
    /// Kammhöhe über der Haupttalsohle an den Sätteln bzw. sonst.
    static let lowSaddleCrest = 0.012
    static let highSaddleCrest = 0.030
    static let ridgeCrest = 0.08

    static func westX(_ j: Double) -> Double {
        // Nah am Haupttal entlang der Sättel, ab ~j 70 nach Westen ausholend.
        mainX - valleyGap - 22 * smoothstep(66, 84, j)
    }

    /// Haupttalsohle: fällt von Nord nach Süd, im Süden unter den Meeresspiegel.
    /// Bewusst niedrig (≤ ~0,5): darüber friert das Produktions-Klima die
    /// Niederschläge als Schnee ein, und die Täler bekämen kaum Abfluss.
    static func mainFloor(_ j: Double) -> Double {
        let t = j / Double(n - 1)
        let mountain = 0.14 * pow(max(0, 1 - t / 0.22), 2)
        let coast = 0.10 * smoothstep(0.86, 0.98, t)
        return 0.36 - 0.20 * t + mountain - coast
    }

    /// Nebentalsohle: 0,025 tiefer als das Haupttal, nach Norden ansteigend
    /// (Talschluss bei ~j 22).
    static func westFloor(_ j: Double) -> Double {
        mainFloor(j) - 0.025 + 0.008 * max(0, 24 - j)
    }

    /// Querprofil: flache Sohle (±4 Zellen, leichtes V), dann Hang.
    static func bank(_ d: Double) -> Double {
        let e = max(0, d - 4)
        return 0.0008 * min(d, 4) + 0.16 * (1 - exp(-e / 18)) + 0.001 * e
    }

    /// Das Grundrelief der Karte, row-major `n×n`.
    public static func relief() -> [Double] {
        var h = [Double](repeating: 0, count: n * n)
        for j in 0..<n {
            let jd = Double(j)
            let fm = mainFloor(jd), fw = westFloor(jd)
            let wx = westX(jd)
            let mid = (mainX + wx) / 2
            // Kammlinie zwischen den Tälern: niedrig an den Sätteln, sonst hoch.
            let lowGap = exp(-pow((jd - lowSaddleJ) / 2.5, 2))
            let highGap = exp(-pow((jd - highSaddleJ) / 2.5, 2))
            let crestAbove = ridgeCrest
                - (ridgeCrest - lowSaddleCrest) * lowGap
                - (ridgeCrest - highSaddleCrest) * highGap
            // Östliche Kammlinie (ab j ~36): dahinter fällt das Land zum Rand.
            let eastFall = smoothstep(34, 42, jd)
            for i in 0..<n {
                let x = Double(i)
                let dm = abs(x - mainX), dw = abs(x - wx)
                var sm = fm + bank(dm)
                if x > mainX + 9 {
                    let crest = fm + bank(9)
                    let fall = crest + 0.01 - 0.003 * (x - mainX - 9)
                    sm = sm * (1 - eastFall) + max(fall, fm + 0.03) * eastFall
                }
                let sw = fw + bank(dw)
                var v = min(sm, sw)
                // Schmaler Rücken zwischen den Tälern (Dreiecksprofil ±3 Zellen).
                if x > wx + 2 && x < mainX - 2 {
                    let tri = max(0, 1 - abs(x - mid) / 3)
                    v = max(v, (fm + crestAbove) * tri + v * (1 - tri))
                }
                // Leise Unebenheit, deterministisch (kein Seed-Rauschen nötig).
                v += 0.0002 * hashNoise(i, j)
                h[j * n + i] = v
            }
        }
        return h
    }

    // MARK: Siedlungen

    /// Siedlungs-Layout: Häuser und Felder als Zell-Indizes.
    public static func settlements() -> [SettlementLayout] {
        [
            layout(name: "Oberau", centerJ: 30, fieldRows: 27...33, x: mainX, target: false),
            layout(name: "Talheim", centerJ: 66, fieldRows: 60...72, x: mainX, target: true),
            layout(name: "Westfurt", centerJ: 100, fieldRows: 94...106,
                   x: westX(100), target: false),
        ]
    }

    /// Felder beidseits der Talachse (1…3 Zellen neben dem Fluss), Häuser
    /// östlich am Hangfuß (6…7 Zellen), über dem Talboden.
    static func layout(name: String, centerJ: Int, fieldRows: ClosedRange<Int>,
                       x: Double, target: Bool) -> SettlementLayout {
        let cx = Int(x.rounded())
        var fields: [Int] = [], houses: [Int] = []
        for j in fieldRows {
            for di in [-3, -2, 2, 3] { fields.append(j * n + cx + di) }
        }
        for j in (centerJ - 2)...(centerJ + 2) {
            for di in [6, 7] where (j + di) % 2 == 0 || j == centerJ {
                houses.append(j * n + cx + di)
            }
        }
        return SettlementLayout(name: name, centerI: cx + 6, centerJ: centerJ,
                                houses: houses, fields: fields, isTarget: target)
    }

    // MARK: Reproduzierbare Eingriffe (Versuche, docs/nature-prototype.md)

    /// Versuch A: Durchstich des niedrigen Sattels mit der Spitzhacke, vom
    /// Haupttal nach Westen (Werkzeug, Zelle x, Zelle z).
    public static var lowSaddleCut: [(BrushTool, Double, Double)] {
        cut(atJ: lowSaddleJ, hitsPerSpot: 1)
    }

    /// Versuch B: Durchstich des hohen Sattels — teurer, aber außerhalb der
    /// Reichweite der Talheimer Ausbesserer.
    public static var highSaddleCut: [(BrushTool, Double, Double)] {
        cut(atJ: highSaddleJ, hitsPerSpot: 2)
    }

    static func cut(atJ j: Double, hitsPerSpot: Int) -> [(BrushTool, Double, Double)] {
        var hits: [(BrushTool, Double, Double)] = []
        for _ in 0..<hitsPerSpot {
            for x in stride(from: mainX - 2, through: mainX - valleyGap + 2, by: -2) {
                hits.append((.pickaxe, x, j))
            }
        }
        return hits
    }

    /// Versuch C: Damm quer durchs Haupttal unterhalb von Talheim (Anheben).
    public static var damBelowTalheim: [(BrushTool, Double, Double)] {
        var hits: [(BrushTool, Double, Double)] = []
        for _ in 0..<2 {
            for x in stride(from: mainX - 6, through: mainX + 8, by: 2) {
                hits.append((.raise, x, 78))
            }
        }
        return hits
    }

    // MARK: Hilfen

    static func smoothstep(_ a: Double, _ b: Double, _ v: Double) -> Double {
        let t = min(max((v - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Ganzzahl-Hash → [−1, 1].
    static func hashNoise(_ i: Int, _ j: Int) -> Double {
        var x = UInt32(truncatingIfNeeded: i &* 374_761_393 &+ j &* 668_265_263)
        x = (x ^ (x >> 13)) &* 1_274_126_177
        x ^= x >> 16
        return Double(x & 0xFFFF) / 32767.5 - 1
    }
}

/// Wo eine Siedlung steht: Häuser und Felder als Zell-Indizes (row-major).
public struct SettlementLayout: Sendable {
    public let name: String
    public let centerI: Int
    public let centerJ: Int
    public let houses: [Int]
    public let fields: [Int]
    /// Zielsiedlung: ihre Aufgabe beendet den Versuch.
    public let isTarget: Bool
}
