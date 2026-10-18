import Foundation
import SimCore

/// Verbreiterung kräftiger Raster-Läufe als Scheibenstempel (Issue #174,
/// „Kästen"). Begründung, Messreihe und Kalibrierung: `WaterRender`
/// § „Verbreiterung als Scheibe" und `docs/geometry-water-measurements.md` § H.
///
/// Reine Funktion über Felder (kein Zustand): jede Linienzelle mit Intensität
/// über `widenThresholds[0]` stempelt eine Scheibe mit dem Radius
/// `WaterRender.widenRadius(intensity:)`, verjüngt am Kopf der Linie, moduliert
/// von Breiten-Rauschen und einem Mittelpunkts-Versatz. Das Rauschen hängt nur
/// von der Zellposition ab (statisch, kein Flackern im Zeitraffer), das
/// Ergebnis ist deterministisch, und geschrieben wird per Maximum: die
/// Reihenfolge der Stempel ist gleichgültig.
enum RiverWidening {
    /// Glattes Gitter-Rauschen in −1…1 aus einem Ganzzahl-Hash der Gitterpunkte
    /// (bilinear mit glatter Blende). Ein festes Render-Rauschen, unabhängig vom
    /// Welt-Seed: gleiche Linie, gleiche Form, auch nach einem Neu-Generieren
    /// derselben Welt. Bewusst nicht `SimplexNoise`: pro kräftiger Zelle drei
    /// Abfragen. Die Ganzzahl-Fassung braucht dafür keine Sim-Rauschquelle.
    @inline(__always)
    private static func noise(_ x: Double, _ y: Double, _ salt: UInt32) -> Double {
        let fx = x.rounded(.down), fy = y.rounded(.down)
        let ix = Int32(truncatingIfNeeded: Int(fx)), iy = Int32(truncatingIfNeeded: Int(fy))
        let tx = x - fx, ty = y - fy
        let u = tx * tx * (3 - 2 * tx), v = ty * ty * (3 - 2 * ty)
        @inline(__always) func lattice(_ a: Int32, _ b: Int32) -> Double {
            var h = UInt32(bitPattern: a) &* 0x9E3779B1 ^ UInt32(bitPattern: b) &* 0x85EBCA77 ^ salt
            h ^= h >> 15; h = h &* 0x2C1B3C6D
            h ^= h >> 12; h = h &* 0x297A2D39
            h ^= h >> 15
            return Double(h) / 2147483648.0 - 1   // −1 … 1
        }
        let a = lattice(ix, iy), b = lattice(ix &+ 1, iy)
        let c = lattice(ix, iy &+ 1), d = lattice(ix &+ 1, iy &+ 1)
        return (a + (b - a) * u) + ((c + (d - c) * u) - (a + (b - a) * u)) * v
    }

    /// Schreibt die verbreiterte Fassung von `sd` nach `out` (gleiche Länge `n·n`).
    /// `h` und `hf` sind Bett und Wasserspiegel: Wasser breitet sich nur auf Zellen
    /// aus, deren Bett nahe am Spiegel der Linienzelle liegt (Bank-Schranke
    /// `widenBarTolerance`, fest und symmetrisch auch bei großem Abstand).
    /// `receiver` ist der D8-Empfänger
    /// (−1 = Senke): er liefert, wie viele kräftige Zellen stromauf folgen, und
    /// damit die Verjüngung am Kopf.
    static func widen(_ sd: [Double], into out: inout [Double],
                      h: [Double], hf: [Double], receiver: [Int32], n: Int) {
        let cnt = n * n
        precondition(sd.count == cnt && out.count == cnt && h.count == cnt
                     && hf.count == cnt && receiver.count == cnt)
        let t0 = WaterRender.widenThresholds[0]
        let falloff = WaterRender.widenFalloff
        let tolerance = WaterRender.widenBarTolerance
        let jitter = WaterRender.widenWidthJitter
        let wander = WaterRender.widenWanderRadii
        let frequency = 1.0 / WaterRender.widenWavelengthCells
        let taperCells = WaterRender.widenHeadTaperCells
        let shoulder = WaterRender.widenShoulderCells

        // Kräftige Zellen stromauf (höchstens `taperCells` Schritte weit): ein Lauf-
        // Kopf hat 0, ab `taperCells` Zellen Lauf dahinter ist die Verjüngung vorbei.
        var upstream = [UInt8](repeating: 0, count: cnt)
        var strong: [Int32] = []
        strong.reserveCapacity(8192)
        sd.withUnsafeBufferPointer { sb in
            for k in 0..<cnt where sb[k] > t0 { strong.append(Int32(k)) }
        }
        for k32 in strong {
            let k = Int(k32)
            var r = receiver[k]
            var steps = 0
            while r >= 0 && Int(r) < cnt && steps < taperCells {
                let v = Int(r)
                if sd[v] > t0 && upstream[v] < UInt8(taperCells) { upstream[v] += 1 }
                r = receiver[v]
                steps += 1
            }
        }

        // Dichte kräftiger Zellen im Umkreis: eine Linie allein füllt einen kleinen
        // Teil des Fensters, ein Flächenabfluss (viele parallele Linien) den größten.
        // Dort schrumpft der Radius, damit die Linien als einzelne Stränge lesbar
        // bleiben statt zu EINER dunklen Fläche zu verschmelzen.
        let crowd = WaterRender.widenCrowdCells
        var strongMask = [Bool](repeating: false, count: cnt)
        for k32 in strong { strongMask[Int(k32)] = true }

        sd.withUnsafeBufferPointer { sb in
        out.withUnsafeMutableBufferPointer { ob in
        h.withUnsafeBufferPointer { hb in
        hf.withUnsafeBufferPointer { fb in
        upstream.withUnsafeBufferPointer { ub in
            let ps = sb.baseAddress!, po = ob.baseAddress!
            let ph = hb.baseAddress!, pf = fb.baseAddress!, pu = ub.baseAddress!
            po.update(from: ps, count: cnt)
            for k32 in strong {
                let k = Int(k32)
                let i = k % n, j = k / n
                let s = ps[k]
                let taper = WaterRender.widenHeadTaper(upstreamCells: Int(pu[k]))
                var around = 0
                for dj in max(0, j - crowd)...min(n - 1, j + crowd) {
                    let row = dj * n
                    for di in max(0, i - crowd)...min(n - 1, i + crowd) where strongMask[row + di] { around += 1 }
                }
                let side = 2 * crowd + 1
                let share = Double(around) / Double(side * side)
                let base = WaterRender.widenRadius(intensity: s) * taper * WaterRender.widenCrowdFactor(share: share)
                let x = Double(i), z = Double(j)
                let radius = base * (1 + jitter * noise(x * frequency, z * frequency, 0x1A5))
                let shift = wander * base
                let cx = x + shift * noise(x * frequency, z * frequency, 0x2B6)
                let cz = z + shift * noise(x * frequency, z * frequency, 0x3C7)
                let reach = radius + shoulder
                let iLo = max(0, Int((cx - reach).rounded(.down)))
                let iHi = min(n - 1, Int((cx + reach).rounded(.up)))
                let jLo = max(0, Int((cz - reach).rounded(.down)))
                let jHi = min(n - 1, Int((cz + reach).rounded(.up)))
                if iLo > iHi || jLo > jHi { continue }
                let level = pf[k]
                let core = s - falloff * radius
                for tj in jLo...jHi {
                    for ti in iLo...iHi {
                        let dx = Double(ti) - cx, dz = Double(tj) - cz
                        let d = (dx * dx + dz * dz).squareRoot()
                        if d >= reach { continue }
                        let t = tj * n + ti
                        if t != k && abs(ph[t] - level) >= tolerance { continue }
                        // Kern mit dem alten Gefälle je Zelle Abstand, dahinter eine
                        // Zelle Schulter bis 0: die Kontur im Shader-Fenster liegt
                        // dann rund einen halben Radius außerhalb des Kerns.
                        let v = d <= radius ? s - falloff * d : core * (1 - (d - radius) / shoulder)
                        if v > po[t] { po[t] = v }
                    }
                }
            }
        }}}}}
    }
}
