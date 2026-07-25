import Foundation

/// Deterministischer PRNG (mulberry32) — bit-identisch reproduzierbar je Seed.
/// Portiert aus dem Web-Prototyp, damit Terrains vergleichbar bleiben.
public struct Mulberry32 {
    private var a: UInt32
    public init(seed: UInt32) { self.a = seed }

    public mutating func next() -> Double {
        a = a &+ 0x6D2B79F5
        var t = a
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double((t ^ (t >> 14))) / 4294967296.0
    }
}

/// 2D-Simplex-Noise (nach Gustavson), deterministisch über eine Permutationstabelle.
/// Rückgabe ~[-1, 1].
public struct SimplexNoise {
    private var perm = [Int](repeating: 0, count: 512)
    private static let grad: [(Double, Double)] = [
        (1, 1), (-1, 1), (1, -1), (-1, -1), (1, 0), (-1, 0), (0, 1), (0, -1),
    ]
    private static let F2 = 0.5 * (3.0.squareRoot() - 1)
    private static let G2 = (3 - 3.0.squareRoot()) / 6

    public init(seed: UInt32) {
        var rnd = Mulberry32(seed: seed)
        var p = Array(0..<256)
        var i = 255
        while i > 0 {
            let j = Int(rnd.next() * Double(i + 1))
            p.swapAt(i, j)
            i -= 1
        }
        for k in 0..<512 { perm[k] = p[k & 255] }
    }

    public func value(_ xin: Double, _ yin: Double) -> Double {
        let s = (xin + yin) * Self.F2
        var i = Int(floor(xin + s))
        var j = Int(floor(yin + s))
        let t = Double(i + j) * Self.G2
        let x0 = xin - (Double(i) - t)
        let y0 = yin - (Double(j) - t)
        let i1 = x0 > y0 ? 1 : 0
        let j1 = 1 - i1
        let x1 = x0 - Double(i1) + Self.G2
        let y1 = y0 - Double(j1) + Self.G2
        let x2 = x0 - 1 + 2 * Self.G2
        let y2 = y0 - 1 + 2 * Self.G2
        i &= 255
        j &= 255
        var n = 0.0
        let g0 = Self.grad[perm[i + perm[j]] & 7]
        let g1 = Self.grad[perm[i + i1 + perm[j + j1]] & 7]
        let g2 = Self.grad[perm[i + 1 + perm[j + 1]] & 7]
        var t0 = 0.5 - x0 * x0 - y0 * y0
        if t0 > 0 { t0 *= t0; n += t0 * t0 * (g0.0 * x0 + g0.1 * y0) }
        var t1 = 0.5 - x1 * x1 - y1 * y1
        if t1 > 0 { t1 *= t1; n += t1 * t1 * (g1.0 * x1 + g1.1 * y1) }
        var t2 = 0.5 - x2 * x2 - y2 * y2
        if t2 > 0 { t2 *= t2; n += t2 * t2 * (g2.0 * x2 + g2.1 * y2) }
        return 70 * n
    }

    /// Fraktales Rauschen (fBm) mit `octaves` Oktaven, auf ~[0, 1] normiert.
    public func fbm01(_ x: Double, _ y: Double, octaves: Int) -> Double {
        var amp = 1.0, freq = 1.0, v = 0.0, norm = 0.0
        for _ in 0..<octaves {
            v += amp * value(x * freq, y * freq)
            norm += amp
            amp *= 0.5
            freq *= 2
        }
        return (v / norm + 1) / 2
    }

    /// Ridged-Multifractal (Musgrave): `1 − |noise|` je Oktave, quadriert und mit
    /// der vorigen Oktave gewichtet → scharfe **Bergkämme** und Grate statt der
    /// rundlichen Blobs von fBm. Ergebnis ~[0, 1] (hohe Werte = Grate).
    public func ridged01(_ x: Double, _ y: Double, octaves: Int,
                         lacunarity: Double = 2.0, gain: Double = 0.5) -> Double {
        var sum = 0.0, freq = 1.0, amp = 0.5, prev = 1.0, norm = 0.0
        for _ in 0..<octaves {
            var n = 1.0 - abs(value(x * freq, y * freq)) // Rücken bei |noise|→0
            n *= n                                        // Grate schärfen
            n *= prev                                     // multifraktal: Grate auf Graten
            prev = min(1, n * 2.0)
            sum += n * amp
            norm += amp
            freq *= lacunarity
            amp *= gain
        }
        return min(1, max(0, sum / norm))
    }
}
