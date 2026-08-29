import Foundation
import SimCore

/// Makrofarbe und Materialgewichte des Geländes als zwei RGBA8-Puffer.
///
/// Die Farbe trägt nur großräumige Sim-Signale wie Biom, Salz und Eis. Der
/// Shader baut daraus zusammen mit `surfaces` die eigentliche Oberfläche. So
/// bleiben Materialgrenzen an die Physik gebunden, ohne die 256er-Sim-Zellen als
/// verwaschene "Textur" sichtbar zu machen.
public enum TerrainColorRenderer {
    public struct Buffers {
        public let colors: [UInt8]
        /// R = Vegetation, G = freier Fels, B = Schnee/Eis,
        /// A = Lithologie-Härte von −1 ... +1 auf 0 ... 1 abgebildet.
        public let surfaces: [UInt8]
    }

    /// Berechnet beide Puffer in EINEM Lauf. Farbe und Materialgewichte brauchen
    /// dieselben teuren Standortwerte (`macroSlope`, Habitat, Schnee/Eis); zwei
    /// getrennte Callables würden diese Arbeit pro Textur-Update verdoppeln.
    public static func buffers(_ terrain: Terrain) -> Buffers {
        let n = terrain.cfg.n
        let sea = terrain.cfg.sea
        let h = terrain.h, rain = terrain.rain, veg = terrain.veg
        let salt = terrain.saltCrust
        let lith = terrain.lithHardness.count == n * n ? terrain.lithHardness : [0.0]
        let lithOn = lith.count == n * n
        let snow = terrain.snow.count == n * n ? terrain.snow : [0.0]
        let snowOn = snow.count == n * n
        let snowRef = terrain.cfg.snowCoverRef
        let ice = terrain.ice.count == n * n ? terrain.ice : [0.0]
        let iceOn = ice.count == n * n
        let iceRef = terrain.cfg.iceCoverRef
        let bands = terrain.heightBands

        var colors = [UInt8](repeating: 255, count: n * n * 4)
        var surfaces = [UInt8](repeating: 0, count: n * n * 4)
        h.withUnsafeBufferPointer { hb in
        rain.withUnsafeBufferPointer { rnb in
        veg.withUnsafeBufferPointer { vgb in
        salt.withUnsafeBufferPointer { slb in
        lith.withUnsafeBufferPointer { ltb in
        snow.withUnsafeBufferPointer { snb in
        ice.withUnsafeBufferPointer { icb in
        colors.withUnsafeMutableBufferPointer { cb in
        surfaces.withUnsafeMutableBufferPointer { sb in
        let ph = hb.baseAddress!, prain = rnb.baseAddress!, pveg = vgb.baseAddress!
        let psalt = slb.baseAddress!, plith = ltb.baseAddress!
        let psnow = snb.baseAddress!, pice = icb.baseAddress!
        let pcolor = cb.baseAddress!, psurface = sb.baseAddress!

        parallelChunks(n) { jLo, jHi in
            for j in jLo..<jHi {
                for i in 0..<n {
                    let k = j * n + i
                    let v = ph[k]
                    let hard = lithOn ? min(1, max(-1, plith[k])) : 0
                    var r = 0.0, g = 0.0, b = 0.0
                    var vegWeight = 0.0, rockWeight = 0.0, coldWeight = 0.0

                    if v <= sea + 0.012 {
                        (r, g, b) = gradColor(v)
                    } else {
                        var slope = 0.0
                        if i > 1 && i < n - 2 && j > 1 && j < n - 2 {
                            slope = Terrain.macroSlope(ph, k, n)
                        }
                        let steep = min(1, slope * 45)

                        // Dunkler Grundfels statt der bisherigen kreidigen
                        // 0.38...0.45-Fläche. Der Shader ergänzt Materialdetail
                        // und Rauheit; hier bleibt nur die großräumige Tönung.
                        r = 0.29 + 0.035 * steep
                        g = 0.30 + 0.035 * steep
                        b = 0.31 + 0.04 * steep

                        let habitat = Terrain.vegetationSuitability(
                            height: v, slope: slope, rain: prain[k], bands: bands)
                        let vegAmount = min(1, (0.5 + 0.5 * pveg[k]) * habitat * 1.3) * 0.78
                        r += (0.15 - r) * vegAmount
                        g += (0.32 - g) * vegAmount
                        b += (0.10 - b) * vegAmount

                        let highRock = bands.rockAmount(v)
                        if highRock > 0 {
                            r += (0.34 - r) * highRock
                            g += (0.35 - g) * highRock
                            b += (0.37 - b) * highRock
                        }

                        let snowCover = snowOn
                            ? Terrain.snowCoverage(swe: psnow[k], ref: snowRef)
                            : bands.snowAmount(v)
                        if snowCover > 0 {
                            r += (0.88 - r) * snowCover
                            g += (0.90 - g) * snowCover
                            b += (0.93 - b) * snowCover
                        }

                        let iceCover = iceOn
                            ? Terrain.iceCoverage(thickness: pice[k], ref: iceRef)
                            : 0
                        if iceCover > 0 {
                            r += (0.68 - r) * iceCover
                            g += (0.81 - g) * iceCover
                            b += (0.92 - b) * iceCover
                        }

                        let saltCover = min(1, max(0, psalt[k])) * 0.9
                        if saltCover > 0 {
                            r += (0.78 - r) * saltCover
                            g += (0.74 - g) * saltCover
                            b += (0.64 - b) * saltCover
                        }

                        // Die Makrofarbe macht die echte Sim-Lithologie bereits
                        // sichtbar. Der A-Kanal gibt dem Shader zusätzlich die
                        // Härte für Schichtkontrast, Körnung und Rauheit.
                        r -= hard * 0.065
                        g -= hard * 0.075
                        b -= hard * 0.09

                        // Die drei Gewichte werden hier hierarchisch
                        // abgeschwächt (Kälte deckt alles, Vegetation wächst
                        // nicht unter Schnee, Fels schaut nur zwischen beiden
                        // durch) und summieren sich deshalb auf höchstens 1 —
                        // der Rest ist Boden. `terrain.gdshader` mischt die
                        // Materialien als GEWICHTSSUMME und verlässt sich
                        // genau darauf; wer die Faktoren hier ändert, prüft
                        // die Summe dort mit.
                        coldWeight = max(snowCover, iceCover)
                        vegWeight = vegAmount * (1 - coldWeight) * (1 - saltCover)
                        let cliff = smoothstep(0.004, 0.026, slope)
                        rockWeight = max(highRock * 0.82, cliff)
                            * (1 - vegWeight) * (1 - coldWeight) * (1 - saltCover)
                    }

                    let o = k * 4
                    pcolor[o] = byte(r)
                    pcolor[o + 1] = byte(g)
                    pcolor[o + 2] = byte(b)
                    pcolor[o + 3] = 255
                    psurface[o] = byte(vegWeight)
                    psurface[o + 1] = byte(rockWeight)
                    psurface[o + 2] = byte(coldWeight)
                    psurface[o + 3] = byte(hard * 0.5 + 0.5)
                }
            }
        }
        }}}}}}}}}

        return Buffers(colors: colors, surfaces: surfaces)
    }

    @inline(__always)
    private static func byte(_ value: Double) -> UInt8 {
        UInt8(min(max(value, 0), 1) * 255)
    }

    @inline(__always)
    private static func smoothstep(_ lo: Double, _ hi: Double, _ value: Double) -> Double {
        let t = min(max((value - lo) / (hi - lo), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // Meeresgrund und unmittelbarer Ufersaum. Landmaterialien entstehen im
    // Shader aus den Gewichten; diese Rampe muss dort keine Biompalette mehr
    // vortäuschen.
    private static let stops: [(Double, Double, Double, Double)] = [
        (-0.3, 0.015, 0.04, 0.11),
        (0.00, 0.04, 0.13, 0.27),
        (0.15, 0.12, 0.28, 0.38),
        (0.17, 0.53, 0.46, 0.34),
        (0.28, 0.24, 0.42, 0.19),
    ]

    private static func gradColor(_ v: Double) -> (Double, Double, Double) {
        for k in 0..<(stops.count - 1) {
            if v <= stops[k + 1].0 {
                let a = stops[k], c = stops[k + 1]
                let t = min(max((v - a.0) / (c.0 - a.0), 0), 1)
                return (a.1 + (c.1 - a.1) * t,
                        a.2 + (c.2 - a.2) * t,
                        a.3 + (c.3 - a.3) * t)
            }
        }
        let c = stops[stops.count - 1]
        return (c.1, c.2, c.3)
    }
}
