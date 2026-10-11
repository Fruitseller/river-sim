import SimCore

/// Strand und Felsküste (Issue #174, Paket C): welche Landzellen an der Küste
/// Sand tragen und welche Fels sind.
///
/// Reine Render-Ableitung aus Höhe und Abstand zum Meer, zustandslos, ändert
/// das Terrain nie. Kalibrierung und Begründung: `WaterRender` § Strand und
/// Felsküste. Die Gewichte fließen im `TerrainColorRenderer` in die
/// Materialpuffer (Sand im A-Kanal der Makrofarbe, Fels im G-Kanal der
/// Materialgewichte); Wächter: `SimCoreTests/CoastMaterialTests.swift`.
public enum CoastMaterial {

    /// Chebyshev-Abstand (Zellen) jeder Zelle zur nächsten Meereszelle
    /// (`h ≤ sea`, dieselbe Meeres-Definition wie `openWaterSurface`),
    /// gedeckelt auf `WaterRender.coastReachCells + 1`. Meer = 0.
    public static func seaDistance(_ terrain: Terrain) -> [UInt8] {
        let n = terrain.cfg.n
        guard n > 0, terrain.h.count == n * n else { return [] }
        let cap = UInt8(min(254, WaterRender.coastReachCells + 1))
        let sea = terrain.cfg.sea
        var dist = terrain.h.map { $0 <= sea ? 0 : cap }
        var next = dist
        // Je Pass eine 3×3-Min-Erweiterung: nach `reach` Pässen kennt jede
        // Zelle bis zum Deckel ihren exakten Chebyshev-Abstand. Zeilenparallel,
        // liest nur `dist`, schreibt nur `next` → bit-identisch zur Schleife.
        for _ in 0..<Int(cap - 1) {
            dist.withUnsafeBufferPointer { sb in
            next.withUnsafeMutableBufferPointer { db in
                let ps = sb.baseAddress!, pd = db.baseAddress!
                parallelChunks(n) { jLo, jHi in
                    for j in jLo..<jHi {
                        let jMin = max(0, j - 1), jMax = min(n - 1, j + 1)
                        for i in 0..<n {
                            let iMin = max(0, i - 1), iMax = min(n - 1, i + 1)
                            var best = ps[j * n + i]
                            for nj in jMin...jMax {
                                for ni in iMin...iMax where ps[nj * n + ni] + 1 < best {
                                    best = ps[nj * n + ni] + 1
                                }
                            }
                            pd[j * n + i] = best
                        }
                    }
                }
            }}
            swap(&dist, &next)
        }
        return dist
    }

    /// In Reichweite der Brandung? `distance` aus `seaDistance`; Meer (0)
    /// selbst ist keine Küste.
    @inline(__always)
    static func inSurf(_ distance: UInt8) -> Bool {
        distance >= 1 && Int(distance) <= WaterRender.coastReachCells
    }

    /// Sandgewicht 0…1 einer Landzelle: in Reichweite der Brandung, flach und
    /// knapp über dem Meer. `height` = Höhe über dem Meeresspiegel.
    @inline(__always)
    public static func sand(distance: UInt8, slope: Double, height: Double) -> Double {
        guard inSurf(distance), height > 0 else { return 0 }
        return (1 - smoothstep(WaterRender.beachSlopeLo, WaterRender.beachSlopeHi, slope))
            * (1 - smoothstep(WaterRender.beachHeightLo, WaterRender.beachHeightHi, height))
    }

    /// Felsgewicht 0…1 einer steilen Küstenzelle in Reichweite der Brandung.
    @inline(__always)
    public static func cliff(distance: UInt8, slope: Double) -> Double {
        guard inSurf(distance) else { return 0 }
        return smoothstep(WaterRender.cliffCoastSlopeLo, WaterRender.cliffCoastSlopeHi, slope)
    }
}
