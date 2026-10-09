import SimCore

/// Schutzmaske für Kronendach und Verschiebung (Issue #154, Vorbau für #117).
///
/// Beide Schichten dürfen Wasserflächen nicht überdecken: das Kronendach würde
/// Bäume mitten in Flüsse und Seen pflanzen, die Verschiebung würde Ufer über
/// Flussbänder wölben oder Talböden deformieren.
///
/// Die Maske vereint:
///  1. Sichtbares Rasterwasser (Flüsse und Seen aus dem Wasserfeld).
///  2. Tatsächliche Abdeckung der Flussbänder (`RiverRibbonRenderer.bandCoverage`),
///     weil der Raster-Deckel (`WaterFieldRenderer`) das Rasterwasser unter
///     Bändern entfernt.
///  3. Einen Saum von `WaterRender.protectSeamCells` Zellen (je Zelle ein
///     3×3-Pass, also Chebyshev-Abstand) um alle Wasser- und Bandflächen.
///
/// Trockenes Land außerhalb von Wasser, Bändern und Saum bleibt frei (0).
/// Zustandslos: liest nur seine Eingaben, das Wasserfeld bleibt unverändert.
/// Den Cache hält `RenderState` (wie bei `TerrainColorRenderer`).
public enum WaterProtectMask {

    /// R8-Puffer (n×n, 0 = frei, 255 = geschützt). `waterBytes` ist das
    /// RGBA8-Wasserfeld (R = Fluss, G = See); fehlt es oder passt die Größe
    /// nicht, schützt die Maske nur die Bänder.
    public static func bytes(n: Int, bandCoverage: [Double], waterBytes: [UInt8]) -> [UInt8] {
        guard n > 0 else { return [] }
        let cnt = n * n
        let riverThresh = byte01(WaterRender.protectRiverThreshold)
        let lakeThresh = byte01(WaterRender.protectLakeThreshold)
        let bandThresh = WaterRender.protectBandThreshold
        let hasBands = bandCoverage.count == cnt
        let hasWater = waterBytes.count == cnt * 4

        // 1. Kern-Zellen: sichtbares Rasterwasser + gebaute Band-Abdeckung.
        var mask = [UInt8](repeating: 0, count: cnt)
        mask.withUnsafeMutableBufferPointer { mb in
            let pm = mb.baseAddress!
            parallelChunks(cnt) { lo, hi in
                for k in lo..<hi {
                    let isBand = hasBands && bandCoverage[k] >= bandThresh
                    let isWater = hasWater
                        && (waterBytes[k * 4] >= riverThresh || waterBytes[k * 4 + 1] >= lakeThresh)
                    pm[k] = (isBand || isWater) ? 255 : 0
                }
            }
        }

        // 2. Saum: protectSeamCells Pässe einer 3×3-Max-Erweiterung.
        var temp = [UInt8](repeating: 0, count: cnt)
        for _ in 0..<WaterRender.protectSeamCells {
            dilate3x3(src: mask, dst: &temp, n: n)
            swap(&mask, &temp)
        }
        return mask
    }

    /// Je Zeile parallel: liest nur `src`, schreibt nur die eigenen Zeilen von
    /// `dst`, damit bit-identisch zur sequenziellen Schleife.
    private static func dilate3x3(src: [UInt8], dst: inout [UInt8], n: Int) {
        src.withUnsafeBufferPointer { sb in
        dst.withUnsafeMutableBufferPointer { db in
            let ps = sb.baseAddress!, pd = db.baseAddress!
            parallelChunks(n) { jLo, jHi in
                for j in jLo..<jHi {
                    let jMin = max(0, j - 1), jMax = min(n - 1, j + 1)
                    for i in 0..<n {
                        let iMin = max(0, i - 1), iMax = min(n - 1, i + 1)
                        var hit: UInt8 = 0
                        for nj in jMin...jMax {
                            for ni in iMin...iMax { hit |= ps[nj * n + ni] }
                        }
                        pd[j * n + i] = hit
                    }
                }
            }
        }}
    }
}
