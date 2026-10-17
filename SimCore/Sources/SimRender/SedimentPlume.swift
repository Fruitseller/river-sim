import Foundation
import SimCore

/// Sedimentfahnen der großen Flüsse im Meer (Issue #174, Paket C): die
/// Trübungsdichte 0…1 je Meereszelle, wie `ocean.gdshader` sie zeichnet.
///
/// Die Fahne entsteht HIER und nicht im Shader. Vorher legte der Shader eine
/// einzelne Quellzelle je Mündung über eine Mip-Kette aus und zog sie entlang
/// einer festen Strömung auf: die Fahne wurde mit jeder Stufe breiter und las
/// sich aus der Ferne als brauner Rauchfächer, der unabhängig von der Küste ins
/// offene Meer reichte. Jetzt läuft die Trübung als Pfad über die Meereszellen
/// KÜSTENNAH ab der Mündung: ein schmales Band an der Küste entlang
/// (`WaterRender.plumeBandCells`), das mit der Pfadlänge abklingt. Der Shader
/// liest die fertige Dichte nur noch (eine Abfrage, leicht weichgezeichnet).
///
/// Die Küstenströmung bevorzugt eine Richtung (`WaterRender.plumeUpstreamPenalty`,
/// dieselbe Drift wie die Ozean-Wellen): stromauf klingt die Fahne schneller
/// ab als stromab. Wo die Küste quer zur Strömung läuft, reicht sie symmetrisch
/// nach beiden Seiten.
///
/// Zustandslos, liest das Terrain und ändert es nie. Den Cache hält
/// `RenderState`. Kalibrierung und Begründung (Fracht-Stellvertreter):
/// `WaterRender` § Sedimentfahne. Wächter: `SimCoreTests/SedimentPlumeTests.swift`.
public enum SedimentPlume {

    /// Eine Mündung ins Meer.
    public struct Mouth: Equatable {
        /// Letzte Landzelle des Laufs.
        public let landCell: Int
        /// Erste Meereszelle hinter der Mündung (D8-Empfänger der Landzelle):
        /// dort beginnt die Fahne.
        public let seaCell: Int
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
            out.append(Mouth(landCell: k, seaCell: Int(rec[k]),
                             dischargeCells: q, relief: relief[index]))
        }
        return out
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

    /// n×n-Dichtefeld (row-major, Float32 für die Textur des Ozean-Shaders):
    /// 0 außerhalb der Fahnen. Überlappen zwei Fahnen, zählt die dichtere.
    public static func field(_ terrain: Terrain) -> [Float] {
        let n = terrain.cfg.n
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n * n)
        for mouth in mouths(terrain) {
            spread(mouth, strength: strength(mouth), terrain, into: &out)
        }
        return out
    }

    /// Streut die Trübung einer Mündung: kürzester Pfad (Kosten wachsen mit der
    /// Schrittlänge und stromauf) über Meereszellen, die höchstens
    /// `plumeBandCells` vom Land liegen; Dichte = Stärke · e^(−Kosten/Abklinglänge),
    /// zum Rand des Streifens hin ausgeblendet.
    static func spread(_ mouth: Mouth, strength: Double, _ terrain: Terrain,
                       into out: inout [Float]) {
        let n = terrain.cfg.n, sea = terrain.cfg.sea
        guard strength > 0, strength.isFinite, mouth.seaCell >= 0, mouth.seaCell < n * n else { return }
        let decay = WaterRender.plumeDecayCells
        let cutoff = decay * WaterRender.plumeCutoffDecays
        let band = WaterRender.plumeBandCells
        let searchRadius = Int(band.rounded(.up)) + 1
        let half = Int(cutoff.rounded(.up)) + searchRadius
        let size = 2 * half + 1
        let h = terrain.h
        let si = mouth.seaCell % n, sj = mouth.seaCell / n
        let i0 = si - half, j0 = sj - half

        // Küstenströmung als Einheitsvektor (Welt-x = Spalte, Welt-z = Zeile).
        let dx = WaterRender.oceanWaveDriftX, dz = WaterRender.oceanWaveDriftZ
        let dn = max((dx * dx + dz * dz).squareRoot(), 1e-9)
        let cx = dx / dn, cz = dz / dn
        // Acht Schritte mit Länge und Strömungs-Aufschlag: stromab 1×, quer
        // 1 + p/2, stromauf 1 + p.
        var steps: [(di: Int, dj: Int, cost: Double)] = []
        for dj in -1...1 { for di in -1...1 where di != 0 || dj != 0 {
            let len = (Double(di * di + dj * dj)).squareRoot()
            let along = (Double(di) * cx + Double(dj) * cz) / len
            steps.append((di, dj, len * (1 + WaterRender.plumeUpstreamPenalty * (1 - along) / 2)))
        } }

        var cost = [Double](repeating: .infinity, count: size * size)
        // Abstand zum nächsten Land (Zellen, euklidisch), je Fensterzelle
        // einmal bestimmt; −1 = noch nicht.
        var landDistance = [Float](repeating: -1, count: size * size)
        func distanceToLand(_ gi: Int, _ gj: Int, local: Int) -> Double {
            if landDistance[local] >= 0 { return Double(landDistance[local]) }
            var best = Double((searchRadius + 1) * (searchRadius + 1))
            for dj in -searchRadius...searchRadius {
                let jj = gj + dj
                guard jj >= 0, jj < n else { continue }
                for di in -searchRadius...searchRadius {
                    let ii = gi + di
                    guard ii >= 0, ii < n, h[jj * n + ii] > sea else { continue }
                    best = min(best, Double(di * di + dj * dj))
                }
            }
            let d = best.squareRoot()
            landDistance[local] = Float(d)
            return d
        }

        let start = half * size + half
        cost[start] = 0
        var queue = [start]
        var head = 0
        while head < queue.count {
            let c = queue[head]; head += 1
            let ci = c % size, cj = c / size
            for step in steps {
                let li = ci + step.di, lj = cj + step.dj
                guard li >= 0, li < size, lj >= 0, lj < size else { continue }
                let next = cost[c] + step.cost
                let local = lj * size + li
                guard next < cutoff, next < cost[local] else { continue }
                let gi = i0 + li, gj = j0 + lj
                guard gi >= 0, gi < n, gj >= 0, gj < n, h[gj * n + gi] <= sea else { continue }
                guard distanceToLand(gi, gj, local: local) <= band else { continue }
                cost[local] = next
                queue.append(local)
            }
        }

        for local in 0..<(size * size) where cost[local] < cutoff {
            let gi = i0 + local % size, gj = j0 + local / size
            guard gi >= 0, gi < n, gj >= 0, gj < n else { continue }
            let c = cost[local]
            let across = 1 - smoothstep(WaterRender.plumeCoreCells, band,
                                        distanceToLand(gi, gj, local: local))
            let density = Float(strength * exp(-c / decay) * across)
            let k = gj * n + gi
            if density > out[k] { out[k] = density }
        }
    }
}
