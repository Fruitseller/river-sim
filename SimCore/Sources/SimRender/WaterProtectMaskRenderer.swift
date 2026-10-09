import Foundation
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
///  3. Einen Saum von `WaterRender.protectSeamCells` Zellen (je Zelle ein 3×3-Pass) um alle
///     Wasser- und Bandflächen, damit Uferkonturen und Bandränder sauber
///     freibleiben.
///
/// Trockenes Land außerhalb von Wasser, Bändern und Saum bleibt frei (0).
/// Die Maske ist eine reine Render-Ableitung und ändert das Render-Wasserfeld nie.
public final class WaterProtectMaskRenderer {
    public init() {}

    private var maskBuffer: [UInt8] = []
    private var tempBuffer: [UInt8] = []

    /// Berechnet die Schutzmaske als R8-Byte-Puffer (n×n, Werte 0 = frei, 255 = geschützt).
    public func bytes(
        terrain: Terrain,
        bandCoverage: [Double],
        waterBytes: [UInt8]
    ) -> [UInt8] {
        let n = terrain.cfg.n
        guard n > 0 else { return [] }
        let cnt = n * n
        guard terrain.h.count >= cnt, terrain.waterLevel.count >= cnt else { return [] }

        if maskBuffer.count != cnt {
            maskBuffer = [UInt8](repeating: 0, count: cnt)
            tempBuffer = [UInt8](repeating: 0, count: cnt)
        }

        var mask: [UInt8] = []; swap(&mask, &maskBuffer)
        var temp: [UInt8] = []; swap(&temp, &tempBuffer)
        defer {
            swap(&mask, &maskBuffer)
            swap(&temp, &tempBuffer)
        }

        let riverThresh = byte01(WaterRender.protectRiverThreshold)
        let lakeThresh = byte01(WaterRender.protectLakeThreshold)
        let bandThresh = WaterRender.protectBandThreshold
        let bandCount = bandCoverage.count
        let hasWaterBytes = waterBytes.count >= cnt * 4

        // 1. Kern-Zellen: sichtbares Rasterwasser + gebaute Band-Abdeckung.
        mask.withUnsafeMutableBufferPointer { mb in
            let pm = mb.baseAddress!
            parallelChunks(cnt) { lo, hi in
                for k in lo..<hi {
                    let isBand = k < bandCount && bandCoverage[k] >= bandThresh
                    var isRasterWater = false
                    if hasWaterBytes {
                        let streamByte = waterBytes[k * 4]
                        let lakeByte = waterBytes[k * 4 + 1]
                        isRasterWater = streamByte >= riverThresh || lakeByte >= lakeThresh
                    }
                    pm[k] = (isBand || isRasterWater) ? 255 : 0
                }
            }
        }

        // 2. Saum-Dilatation: protectSeamCells Pässe einer 3×3-Max-Erweiterung,
        // Quelle und Ziel wechseln je Pass (auch ungerade Zahlen landen in `mask`).
        for _ in 0..<WaterRender.protectSeamCells {
            dilate3x3(src: mask, dst: &temp, n: n)
            swap(&mask, &temp)
        }

        return mask
    }

    private func dilate3x3(src: [UInt8], dst: inout [UInt8], n: Int) {
        src.withUnsafeBufferPointer { sb in
        dst.withUnsafeMutableBufferPointer { db in
            let ps = sb.baseAddress!, pd = db.baseAddress!
            parallelChunks(n) { jLo, jHi in
                for j in jLo..<jHi {
                    let rowOffset = j * n
                    for i in 0..<n {
                        let k = rowOffset + i
                        if ps[k] != 0 {
                            pd[k] = 255
                            continue
                        }
                        var found = false
                        let jMin = max(0, j - 1), jMax = min(n - 1, j + 1)
                        let iMin = max(0, i - 1), iMax = min(n - 1, i + 1)
                        for dj in jMin...jMax {
                            let nRow = dj * n
                            for di in iMin...iMax {
                                if ps[nRow + di] != 0 {
                                    found = true
                                    break
                                }
                            }
                            if found { break }
                        }
                        pd[k] = found ? 255 : 0
                    }
                }
            }
        }}
    }
}
