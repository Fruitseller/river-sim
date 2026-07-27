import Foundation

/// Nicht-simulierter Erosionsfilter nach Rune Skovbo Johansen („Fast and
/// Gorgeous Erosion Filter", https://blog.runevision.com/2026/03/fast-and-gorgeous-erosion-filter.html,
/// Shadertoy wXcfWn — Referenz-GLSL in docs/references/runevision-erosion/).
///
/// Carvt verzweigte Rinnen/Grate („stacked faded gullies") in ein Höhenfeld —
/// jeder Punkt unabhängig auswertbar, daher parallel und deterministisch. Wird
/// EINMAL bei der Terrain-Generierung angewendet (Pre-Erosion): das Terrain
/// startet mit fertig erodiertem Look, statt ihn über zehntausende Sim-Jahre
/// einzucarven. Die Simulation (Droplets/Stream-Power/Mäander) arbeitet danach
/// ganz normal auf dem vor-erodierten Feld weiter.
///
/// Phacelle Noise + Erosionsfilter portiert aus GLSL:
/// Copyright (c) 2025 Rune Skovbo Johansen — Mozilla Public License v2.0
/// (https://mozilla.org/MPL/2.0/). Portierung Swift: river-sim.
public enum ErosionFilter {

    // MARK: - Utility (GLSL-Semantik)

    @inline(__always) private static func fract(_ x: Double) -> Double { x - x.rounded(.down) }
    @inline(__always) private static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

    /// hash() aus dem Shadertoy-Common-Tab (deterministisch, ohne Tabellen).
    @inline(__always) private static func hash(_ x0: Double, _ y0: Double) -> (Double, Double) {
        let kx = 0.3183099, ky = 0.3678794
        let x = x0 * kx + ky
        let y = y0 * ky + kx
        let t = fract(x * y * (x + y))
        return (-1.0 + 2.0 * fract(16.0 * kx * t), -1.0 + 2.0 * fract(16.0 * ky * t))
    }

    @inline(__always) private static func powInv(_ t: Double, _ power: Double) -> Double {
        1.0 - pow(1.0 - clamp01(t), power)
    }

    @inline(__always) private static func easeOut(_ t: Double) -> Double {
        let v = 1.0 - clamp01(t)
        return 1.0 - v * v
    }

    @inline(__always) private static func smoothStart(_ t: Double, _ smoothing: Double) -> Double {
        if t >= smoothing { return t - 0.5 * smoothing }
        return smoothing <= 0 ? t : 0.5 * t * t / smoothing
    }

    // MARK: - Phacelle Noise

    /// Streifenmuster entlang `dir` (normalisiert): interpoliert cos/sin-Paare aus
    /// 4×4 zufällig versetzten Zellpunkten und normalisiert die Magnitude.
    /// Rückgabe: (cos, sin, sideDirX, sideDirY) — sideDir · sin = Ableitung des cos.
    @inline(__always) private static func phacelle(
        px: Double, py: Double, dirX: Double, dirY: Double,
        freq: Double, offset: Double, normalization: Double
    ) -> (c: Double, s: Double, dx: Double, dy: Double) {
        let tau = 2.0 * Double.pi
        let sideX = -dirY * freq * tau
        let sideY = dirX * freq * tau
        let off = offset * tau
        let ix = px.rounded(.down), iy = py.rounded(.down)
        let fx = px - ix, fy = py - iy
        var phX = 0.0, phY = 0.0, wsum = 0.0
        for i in -1...2 {
            for j in -1...2 {
                let (rx, ry) = hash(ix + Double(i), iy + Double(j))
                let vx = fx - Double(i) - rx * 0.5
                let vy = fy - Double(j) - ry * 0.5
                let w = exp(-(vx * vx + vy * vy) * 2.0) - 0.01111
                if w <= 0 { continue }
                wsum += w
                let wave = vx * sideX + vy * sideY + off
                phX += cos(wave) * w
                phY += sin(wave) * w
            }
        }
        let iX = phX / wsum, iY = phY / wsum
        var mag = (iX * iX + iY * iY).squareRoot()
        mag = max(1.0 - normalization, mag)
        return (iX / mag, iY / mag, sideX, sideY)
    }

    // MARK: - Filter-Parameter

    public struct Params: Sendable {
        public var strength = 0.20      // Gesamtstärke (× scale = Höhen-Offset Oktave 0)
        public var gullyWeight = 0.5    // 0 = nur Peak-Schärfung, 1 = volle Rinnen
        public var detail = 1.5         // < groß: feine Rinnen nur an steilen Hängen
        // rounding: (Grat-Rundung, Kerben-Rundung, Mult. Eingangsfeld, Mult. je Oktave)
        public var rounding = (0.1, 0.0, 0.1, 2.0)
        // onset: (Eingangsfeld, je Oktave, RidgeMap-Eingang, RidgeMap je Oktave)
        public var onset = (1.25, 1.25, 2.8, 1.5)
        // assumedSlope: (angenommene Steigung, Anteil 0..1 der Ersetzung)
        public var assumedSlope = (0.7, 1.0)
        public var scale = 0.06         // horizontale Skala der größten Rinnen (p-Einheiten)
        public var octaves = 5
        public var lacunarity = 2.0
        public var gain = 0.5
        public var cellScale = 0.7      // Phacelle-Zellgröße relativ zur Streifenbreite
        public var normalization = 0.5
        public init() {}
    }

    // MARK: - Kern (Port von ErosionFilter aus Buffer A)

    /// Wertet den Filter an einem Punkt aus. `h`/`sx`/`sy` = Höhe + Steigung des
    /// Eingangsfelds (dh/dp, p-Einheiten), `fadeTarget` ∈ [-1,1] (Tal → Gipfel).
    /// Rückgabe: Höhen-Delta, Steigungs-Delta, Gesamt-Magnitude, RidgeMap
    /// (-1 Kerbe … 1 Grat — dendritische Drainage-Linien bei -1).
    public static func evaluate(
        px: Double, py: Double, h: Double, sx: Double, sy: Double,
        fadeTarget fadeTargetIn: Double, p: Params
    ) -> (dh: Double, dsx: Double, dsy: Double, magnitude: Double, ridgeMap: Double) {
        let strength0 = p.strength * p.scale
        var fadeTarget = min(max(fadeTargetIn, -1), 1)

        var hs = (h, sx, sy)
        let h0 = hs
        var freq = 1.0 / (p.scale * p.cellScale)
        let slopeLength = max((sx * sx + sy * sy).squareRoot(), 1e-10)
        var magnitude = 0.0
        var roundingMult = 1.0
        var strength = strength0

        let roundingForInput = (p.rounding.1 + (p.rounding.0 - p.rounding.1) * clamp01(fadeTarget + 0.5)) * p.rounding.2
        var combiMask = easeOut(smoothStart(slopeLength * p.onset.0, roundingForInput * p.onset.0))

        var ridgeMapCombiMask = easeOut(slopeLength * p.onset.2)
        var ridgeMapFadeTarget = fadeTarget

        // Rinnen-Richtung: Mix aus echter und angenommener Steigung.
        var gsx = sx + (sx / slopeLength * p.assumedSlope.0 - sx) * p.assumedSlope.1
        var gsy = sy + (sy / slopeLength * p.assumedSlope.0 - sy) * p.assumedSlope.1

        for _ in 0..<p.octaves {
            let gl = max((gsx * gsx + gsy * gsy).squareRoot(), 1e-10)
            let ph = phacelle(px: px * freq, py: py * freq,
                              dirX: gsx / gl, dirY: gsy / gl,
                              freq: p.cellScale, offset: 0.25,
                              normalization: p.normalization)
            // freq-Skalierung (p wurde mit freq multipliziert), Slope zeigt bergab.
            let pdx = ph.dx * -freq, pdy = ph.dy * -freq
            let sloping = abs(ph.s)

            // Nicht maskierte, normalisierte Steigung für die nächsten Oktaven
            // (gerade Rinnen: sign statt sin).
            let sgn = ph.s >= 0 ? 1.0 : -1.0
            gsx += sgn * pdx * strength * p.gullyWeight
            gsy += sgn * pdy * strength * p.gullyWeight

            // Höhen-Offset + Ableitung, Richtung fadeTarget ausgefadet.
            let g = (ph.c, ph.s * pdx, ph.s * pdy)
            let fg = (fadeTarget + (g.0 * p.gullyWeight - fadeTarget) * combiMask,
                      g.1 * p.gullyWeight * combiMask,
                      g.2 * p.gullyWeight * combiMask)
            hs.0 += fg.0 * strength
            hs.1 += fg.1 * strength
            hs.2 += fg.2 * strength
            magnitude += strength

            fadeTarget = fg.0

            let roundingForOctave = (p.rounding.1 + (p.rounding.0 - p.rounding.1) * clamp01(ph.c + 0.5)) * roundingMult
            let newMask = easeOut(smoothStart(sloping * p.onset.1, roundingForOctave * p.onset.1))
            combiMask = powInv(combiMask, p.detail) * newMask

            ridgeMapFadeTarget += (g.0 - ridgeMapFadeTarget) * ridgeMapCombiMask
            ridgeMapCombiMask *= easeOut(sloping * p.onset.3)

            strength *= p.gain
            freq *= p.lacunarity
            roundingMult *= p.rounding.3
        }

        let ridgeMap = ridgeMapFadeTarget * (1.0 - ridgeMapCombiMask)
        return (hs.0 - h0.0, hs.1 - h0.1, hs.2 - h0.2, magnitude, ridgeMap)
    }

    // MARK: - Anwendung aufs Höhenfeld (Pre-Erosion bei der Generierung)

    /// Wendet den Filter auf das n×n-Höhenfeld an (in-place). p-Koordinaten sind
    /// UV ∈ [0,1] plus Seed-Offset (jeder Seed andere Rinnen), Steigungen numerisch
    /// (zentrale Differenzen) aus dem UNVERÄNDERTEN Feld. Nur Land: unterhalb
    /// `sea` faden die Rinnen aus (Küste/Meeresboden bleiben unberührt).
    /// `heightOffset` (x: -1..1, y: 0..1 Ersetzung durch -fadeTarget) senkt das
    /// Feld ∝ magnitude — Rinnen CARVEN dann netto, statt Grate aufzuschütten.
    public static func apply(
        h: inout [Double], n: Int, sea: Double,
        seedOffsetX: Double, seedOffsetY: Double,
        params: Params, heightOffset: (Double, Double) = (-0.35, 0.5)
    ) {
        let count = n * n
        precondition(h.count == count)
        let src = h // Steigungen aus dem Eingangsfeld (Filter ist punkt-unabhängig)
        var peak = sea + 0.1
        for k in 0..<count { peak = max(peak, src[k]) }
        let valley = sea
        let scaleUV = Double(n - 1) * 0.5 // zentrale Differenz → dh/duv

        var out = [Double](repeating: 0, count: count)
        out.withUnsafeMutableBufferPointer { outBuf in
            src.withUnsafeBufferPointer { s in
                let outPtr = outBuf.baseAddress!
                let sp = s.baseAddress!
                DispatchQueue.concurrentPerform(iterations: n) { j in
                    let inv = 1.0 / Double(n - 1)
                    for i in 0..<n {
                        let k = j * n + i
                        let hv = sp[k]
                        // Küsten-Fade: Meeresboden/Strand unangetastet.
                        let landT = clamp01((hv - (sea - 0.02)) / 0.07)
                        let landFade = landT * landT * (3 - 2 * landT)
                        if landFade <= 0 { outPtr[k] = hv; continue }
                        let iL = max(i - 1, 0), iR = min(i + 1, n - 1)
                        let jD = max(j - 1, 0), jU = min(j + 1, n - 1)
                        let sx = (sp[j * n + iR] - sp[j * n + iL]) * scaleUV
                        let sy = (sp[jU * n + i] - sp[jD * n + i]) * scaleUV
                        let fade = min(max((hv - valley) / (peak - valley) * 2 - 1, -1), 1)
                        let e = evaluate(px: Double(i) * inv + seedOffsetX,
                                         py: Double(j) * inv + seedOffsetY,
                                         h: hv, sx: sx, sy: sy,
                                         fadeTarget: fade, p: params)
                        let off = (heightOffset.0 + (-fade - heightOffset.0) * heightOffset.1) * e.magnitude
                        outPtr[k] = hv + (e.dh + off) * landFade
                    }
                }
            }
        }
        h = out
    }
}
