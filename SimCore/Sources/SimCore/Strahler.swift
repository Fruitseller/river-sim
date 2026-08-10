import Foundation

/// Strahler-Ordnung auf dem D8-Empfänger-Wald (Issue #31).
///
/// Reine Render-/Rang-Ableitung: kein Sim-Zustand, wird NICHT persistiert
/// (siehe Zustandsinventar in `Terrain.swift`). Das Netz ist die Menge der
/// Zellen mit `isNetwork == true` (typisch: Einzugsgebiet über einer
/// Kanal-Schwelle); alles außerhalb bekommt Ordnung 0 und zählt nicht als
/// Donor. Semantik: Netz-Quelle = 1, Zusammenfluss zweier (oder mehr) Stränge
/// gleicher Maximal-Ordnung s → s+1, sonst bleibt die Maximal-Ordnung.
/// Randfall bewusst so belassen: eine Netz-LÜCKE (Netz → Nicht-Netz → Netz,
/// etwa über eine Meer-Zelle) trennt die Stränge — stromab der Lücke beginnt
/// die Ordnung wieder bei 1, der Rang „springt" nicht über Nicht-Netz-Zellen.
public enum Strahler {
    /// Ordnungen für alle Zellen. `receiver[k] == -1` ist Senke/Meer.
    /// Läuft als Kahn-Topsort über den Donor-Grad — Ergebnis ist eindeutig
    /// (unabhängig von der Abarbeitungs-Reihenfolge), also deterministisch.
    public static func orders(receiver: [Int32], isNetwork: [Bool]) -> [Int32] {
        let n = receiver.count
        precondition(isNetwork.count == n)
        var out = [Int32](repeating: 0, count: n)
        // Donor-Grad nur über Netz-Zellen: Nicht-Netz-Donoren beeinflussen
        // weder Grad noch Ordnung.
        var pending = [Int32](repeating: 0, count: n)
        for k in 0..<n where isNetwork[k] {
            let r = Int(receiver[k])
            if r >= 0 { pending[r] += 1 }
        }
        var maxDonor = [Int32](repeating: 0, count: n)
        var maxCount = [Int32](repeating: 0, count: n)
        var queue = [Int32]()
        queue.reserveCapacity(n)
        for k in 0..<n where isNetwork[k] && pending[k] == 0 { queue.append(Int32(k)) }
        var qi = 0
        while qi < queue.count {
            let k = Int(queue[qi]); qi += 1
            let s: Int32 = maxDonor[k] == 0 ? 1 : (maxCount[k] >= 2 ? maxDonor[k] + 1 : maxDonor[k])
            out[k] = s
            let r = Int(receiver[k])
            guard r >= 0 else { continue }
            if s > maxDonor[r] { maxDonor[r] = s; maxCount[r] = 1 }
            else if s == maxDonor[r] { maxCount[r] += 1 }
            if isNetwork[r] {
                pending[r] -= 1
                if pending[r] == 0 { queue.append(Int32(r)) }
            }
        }
        return out
    }
}

extension Terrain {
    /// Strahler-Ordnung des aktuellen D8-Netzes; Netz = Landzellen (`hf > sea`)
    /// mit Einzugsgebiet ≥ `minCells` Zellen. Für Render-Schwellen und
    /// Breiten-Hierarchie — ändert keinen Sim-Zustand.
    public func strahlerOrders(minCells: Double) -> [Int32] {
        let cellArea = cfg.cellSize * cfg.cellSize
        var net = [Bool](repeating: false, count: area.count)
        for k in 0..<area.count {
            net[k] = hf[k] > cfg.sea && area[k] / cellArea >= minCells
        }
        return Strahler.orders(receiver: receiver, isNetwork: net)
    }
}
