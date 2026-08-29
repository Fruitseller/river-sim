import XCTest
@testable import SimCore

/// Geteilte Helfer der Pinsel-Tests (`TerrainAPITests`, `ToolContractTests`).
///
/// Alle drei rechnen mit derselben Kreisgeometrie wie `Terrain.forEachBrushCell`
/// (Radius in WELT-Einheiten, quadratischer Abstand ≤ 1 in Radius-Einheiten) —
/// „im Pinsel" und „außerhalb" dürfen zwischen den Suiten nicht auseinanderlaufen.
/// Deshalb liegen sie hier statt als private Kopie je Testklasse (dieselbe
/// Begründung wie bei `captures` in `RepoSource.swift`).

/// Zellen im Pinselkreis.
func brushCells(center: (Double, Double), radiusWorld: Double,
                cfg c: SimConfig) -> [Int] {
    let rCells = radiusWorld / c.cellSize
    let n = c.n
    var out: [Int] = []
    for j in 0..<n {
        for i in 0..<n {
            let dx = Double(i) - center.0, dz = Double(j) - center.1
            if (dx * dx + dz * dz) / (rCells * rCells) <= 1 { out.append(j * n + i) }
        }
    }
    return out
}

/// Mittlere Abweichung vom 3×3-Mittel im Pinselkreis = „Zerklüftung".
func roughness(_ h: [Double], center: (Double, Double), radiusWorld: Double,
               cfg c: SimConfig) -> Double {
    let n = c.n
    var sum = 0.0, cnt = 0.0
    for k in brushCells(center: center, radiusWorld: radiusWorld, cfg: c) {
        let i = k % n, j = k / n
        guard i > 0, i < n - 1, j > 0, j < n - 1 else { continue }
        var mean = 0.0
        for dj in -1...1 {
            for di in -1...1 { mean += h[(j + dj) * n + i + di] }
        }
        sum += abs(h[k] - mean / 9); cnt += 1
    }
    return cnt == 0 ? 0 : sum / cnt
}

/// Außerhalb des Pinsels (plus eine Zelle Toleranz für die Rundung des
/// Radius) darf sich KEIN Bit geändert haben.
func assertUntouchedOutside(_ h: [Double], before: [Double],
                            center: (Double, Double), radiusWorld: Double,
                            cfg c: SimConfig,
                            file: StaticString = #filePath, line: UInt = #line) {
    let rCells = radiusWorld / c.cellSize + 1
    let n = c.n
    for j in 0..<n {
        for i in 0..<n {
            let dx = Double(i) - center.0, dz = Double(j) - center.1
            guard dx * dx + dz * dz > rCells * rCells else { continue }
            let k = j * n + i
            if h[k] != before[k] {
                XCTFail("Zelle (\(i),\(j)) außerhalb des Pinsels verändert: "
                        + "\(before[k]) → \(h[k])", file: file, line: line)
                return
            }
        }
    }
}
