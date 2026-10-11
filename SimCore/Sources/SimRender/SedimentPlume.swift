import Foundation
import SimCore

/// Quellen der Sedimentfahnen im Meer (Issue #174, Paket C): EINE Zelle je
/// Mündung, gewichtet nach Abfluss und Fracht. `ocean.gdshader` zeichnet die
/// Fahne daraus weich (Mip-Stufen) und zieht sie mit der Küstenströmung
/// stromab; hier entsteht nur die Quelle.
///
/// Zustandslos, liest das Terrain und ändert es nie. Den Cache hält
/// `RenderState`. Kalibrierung und Begründung (Fracht-Stellvertreter):
/// `WaterRender` § Sedimentfahne. Wächter: `SimCoreTests/SedimentPlumeTests.swift`.
public enum SedimentPlume {

    /// Eine Mündung ins Meer.
    public struct Mouth: Equatable {
        /// Letzte Landzelle des Laufs.
        public let landCell: Int
        /// Meereszelle, auf der die Quelle sitzt (`plumeOffshoreCells` vor der
        /// Küste, soweit das Meer reicht).
        public let sourceCell: Int
        /// Einzugsgebiet der Mündung in Zellen (D8, wie die Erosion).
        public let dischargeCells: Double
        /// Höchster Punkt des Einzugsgebiets über dem Meer (Sim-Höhe).
        public let relief: Double
    }

    /// Alle Mündungen ins Meer ab `WaterRender.plumeMinDischargeCells`:
    /// Landzellen, deren D8-Empfänger eine Meereszelle ist (`h ≤ sea`). Jeder
    /// D8-Lauf erreicht das Meer in genau einer solchen Zelle.
    public static func mouths(_ terrain: Terrain) -> [Mouth] {
        let n = terrain.cfg.n, cnt = n * n
        let h = terrain.h, rec = terrain.receiver, area = terrain.area
        let cellArea = terrain.cfg.cellSize * terrain.cfg.cellSize
        guard n > 2, h.count == cnt, rec.count == cnt, area.count == cnt,
              cellArea > 0, cellArea.isFinite else { return [] }
        let sea = terrain.cfg.sea

        // Mündungs-Etikett je Landzelle über die Empfänger-Kette (memoisiert,
        // damit O(n²) insgesamt): −1 = noch offen, −2 = endet nicht im Meer.
        var label = [Int32](repeating: -1, count: cnt)
        var mouthCells: [Int] = []
        var relief: [Double] = []
        var path: [Int] = []
        for start in 0..<cnt where h[start] > sea && label[start] == -1 {
            path.removeAll(keepingCapacity: true)
            var k = start
            var result: Int32 = -2
            // Höchstens `cnt` Schritte: eine kaputte Empfänger-Kette (Zyklus)
            // endet als „nicht im Meer" statt in einer Endlosschleife.
            for _ in 0..<cnt {
                if label[k] != -1 { result = label[k]; break }
                path.append(k)
                let r = Int(rec[k])
                if r < 0 || r >= cnt { break }
                if h[r] <= sea {
                    result = Int32(mouthCells.count)
                    mouthCells.append(k)
                    relief.append(0)
                    break
                }
                k = r
            }
            for p in path {
                label[p] = result
                if result >= 0 { relief[Int(result)] = max(relief[Int(result)], h[p] - sea) }
            }
        }

        var out: [Mouth] = []
        for (index, k) in mouthCells.enumerated() {
            let q = area[k] / cellArea
            guard q.isFinite, q >= WaterRender.plumeMinDischargeCells else { continue }
            out.append(Mouth(landCell: k, sourceCell: offshore(from: k, terrain),
                             dischargeCells: q, relief: relief[index]))
        }
        return out
    }

    /// Quelle vor der Küste: in Fließrichtung (Landzelle → Empfänger) so weit
    /// hinaus, wie das Meer reicht, höchstens `plumeOffshoreCells`.
    static func offshore(from land: Int, _ terrain: Terrain) -> Int {
        let n = terrain.cfg.n
        let r = Int(terrain.receiver[land])
        let di = r % n - land % n, dj = r / n - land / n
        var cell = r
        for _ in 1..<max(WaterRender.plumeOffshoreCells, 1) {
            let i = cell % n + di, j = cell / n + dj
            guard i >= 0, i < n, j >= 0, j < n else { break }
            let next = j * n + i
            if terrain.h[next] > terrain.cfg.sea { break }
            cell = next
        }
        return cell
    }

    /// Stärke 0…1 einer Fahne: Abfluss-Gewicht (log-Rampe) × Fracht-Gewicht
    /// (Relief, mit Boden).
    @inline(__always)
    public static func strength(_ mouth: Mouth) -> Double {
        let lo = WaterRender.plumeMinDischargeCells, hi = WaterRender.plumeFullDischargeCells
        let discharge = clamp01(log(max(mouth.dischargeCells, lo) / lo) / log(hi / lo))
        let floor = WaterRender.plumeReliefFloor
        let load = floor + (1 - floor) * clamp01(mouth.relief / WaterRender.plumeFullRelief)
        return discharge * load
    }

    /// n×n-Quellfeld (row-major, Float32 für die Mip-Kette der Ozean-Textur):
    /// 0 überall außer an den Quellzellen der Mündungen. Fallen zwei
    /// Mündungen auf dieselbe Zelle, zählt die stärkere.
    public static func field(_ terrain: Terrain) -> [Float] {
        let n = terrain.cfg.n
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n * n)
        for mouth in mouths(terrain) {
            out[mouth.sourceCell] = max(out[mouth.sourceCell], Float(strength(mouth)))
        }
        return out
    }
}
