import Foundation
@testable import SimCore
@testable import SimRender

/// Durchgängigkeit des sichtbaren Wassers entlang der großen D8-Läufe
/// (Befund des Eigners 2026-10-18: „der Fluss fließt durchgehend weiter, aber
/// man sieht das Wasser nicht durchgehend"). Gemeinsam für den Wächter
/// (`RiverContinuityTests`) und die Messreihe
/// (`RiverContinuityDiagnostics`, `docs/zielbild-measurements.md`
/// § Durchgehende Flüsse).
struct RiverContinuity {
    /// Zellen eines großen D8-Laufs ohne sichtbares Wasser in 2 Zellen, mit
    /// sichtbarem Wasser stromauf UND stromab: das Wasser reißt mitten im
    /// Lauf ab.
    var gapCells = 0
    /// Zusammenhängende Lücken-Strecken entlang des D8-Laufs.
    var gapStretches = 0
    var longestGap = 0
    /// Zellen, die das Band zu ≥ 0,5 deckt, und sichtbare Raster-Fluss-Zellen.
    var bandCells = 0
    var rasterCells = 0
    /// Fluss-Bänder, die an Land spitz auslaufen, obwohl ihr D8-Lauf binnen
    /// `WaterRender.ribbonJoinSearchCells` in ein anderes Band mündet: der
    /// Zubringer endet als Keil vor dem Hauptlauf (Befund 2026-10-18, „Flüsse
    /// kreuzen sich unnatürlich").
    var endsBeforeBand = 0
    /// Raster-Läufe quer durch ein Band: eine sichtbare Raster-Zelle, deren
    /// D8-Lauf ein Band betritt, es binnen 12 Zellen wieder verlässt und danach
    /// mindestens 4 Zellen als Raster weiterläuft.
    var rasterCrossings = 0

    /// Zählt `endsBeforeBand` am gebauten Mesh. Reichweite und Deckung als
    /// Literale (= `WaterRender.ribbonJoinSearchCells`/`ribbonJoinCoverage`),
    /// damit dieselbe Messung auch auf dem Stand vor dem Fix läuft.
    static func endsBeforeBand(_ t: Terrain, mesh: RibbonMesh) -> Int {
        let joinCells = 8, joinCoverage = 0.5
        let n = t.cfg.n, cs = t.cfg.cellSize, half = t.cfg.world * 0.5
        guard mesh.bandCoverage.count == n * n else { return 0 }
        func cell(_ v: Int) -> Int {
            let m = (mesh.vertices[v] + mesh.vertices[v + 1]) * 0.5
            let i = min(max(Int(((Double(m.x) + half) / cs).rounded()), 0), n - 1)
            let j = min(max(Int(((Double(m.z) + half) / cs).rounded()), 0), n - 1)
            return j * n + i
        }
        var count = 0
        for strip in mesh.stripStarts.indices {
            let start = Int(mesh.stripStarts[strip])
            let end = strip + 1 < mesh.stripStarts.count ? Int(mesh.stripStarts[strip + 1]) : mesh.vertices.count
            guard end - start >= 4, mesh.uv2s[start].x == Float(WaterRender.ribbonKindRiver) else { continue }
            let last = end - 2
            guard mesh.colors[last].w <= Float(WaterRender.ribbonMinimumAlpha) else { continue }
            var c = cell(last)
            guard t.h[c] > t.cfg.sea, mesh.bandCoverage[c] < joinCoverage else { continue }
            for _ in 0..<joinCells {
                let r = Int(t.receiver[c])
                guard r >= 0, r < n * n, t.h[r] > t.cfg.sea else { break }
                c = r
                if mesh.bandCoverage[c] >= joinCoverage { count += 1; break }
            }
        }
        return count
    }

    /// `water` ist das Wasserfeld VOR Blur und EWMA (`deferTail`), also das,
    /// was die Regeln entscheiden. Sichtbar: Band ≥ 0,5, Raster-Fluss ab
    /// `riverMaskLo`, stehendes Wasser über `lakeRawWetDepth`, Meer.
    static func measure(_ t: Terrain, bandCoverage: [Double], water: [UInt8],
                        minCells: Double = 1000) -> RiverContinuity {
        let n = t.cfg.n, cnt = n * n, sea = t.cfg.sea
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        var out = RiverContinuity()
        guard bandCoverage.count == cnt, water.count == cnt * 4, cellArea > 0 else { return out }
        let riverLo = byte01(WaterRender.riverMaskLo)
        var visible = [Bool](repeating: false, count: cnt)
        for k in 0..<cnt {
            let band = bandCoverage[k] >= 0.5, river = water[k * 4] >= riverLo
            if band { out.bandCells += 1 }
            if river && !band && t.h[k] > sea { out.rasterCells += 1 }
            visible[k] = band || river || t.h[k] <= sea
                || t.waterLevel[k] - t.h[k] > WaterRender.lakeRawWetDepth
        }
        var near = visible
        for k in 0..<cnt where visible[k] {
            let i = k % n, j = k / n
            for jj in max(0, j - 2)...min(n - 1, j + 2) {
                for ii in max(0, i - 2)...min(n - 1, i + 2) { near[jj * n + ii] = true }
            }
        }
        let rec = t.receiver
        let big = (0..<cnt).map { t.h[$0] > sea && t.area[$0] / cellArea >= minCells }
        // Stromauf sichtbar: von hoch nach tief, jede Zelle gibt an ihren
        // Empfänger weiter (der liegt nie höher, Priority-Flood).
        var upVisible = [Bool](repeating: false, count: cnt)
        for k in (0..<cnt).sorted(by: { t.h[$0] > t.h[$1] || (t.h[$0] == t.h[$1] && $0 < $1) }) where big[k] {
            let r = Int(rec[k])
            if r >= 0 && r < cnt { upVisible[r] = upVisible[r] || near[k] || upVisible[k] }
        }
        var gap = [Bool](repeating: false, count: cnt)
        for k in 0..<cnt where big[k] && !near[k] && upVisible[k] {
            var r = Int(rec[k]), steps = 0
            while r >= 0 && r < cnt && steps < 400 {
                if near[r] { gap[k] = true; break }
                r = Int(rec[r]); steps += 1
            }
        }
        var counted = [Bool](repeating: false, count: cnt)
        for k in (0..<cnt).sorted(by: { t.h[$0] > t.h[$1] || (t.h[$0] == t.h[$1] && $0 < $1) }) where gap[k] && !counted[k] {
            var length = 0, r = k
            while r >= 0 && r < cnt && gap[r] && !counted[r] {
                counted[r] = true; length += 1; r = Int(rec[r])
            }
            out.gapStretches += 1
            out.longestGap = max(out.longestGap, length)
        }
        out.gapCells = gap.filter { $0 }.count
        let landRiver = (0..<cnt).map { water[$0 * 4] >= riverLo && bandCoverage[$0] < 0.5 && t.h[$0] > sea }
        for k in 0..<cnt where landRiver[k] && t.area[k] / cellArea >= t.cfg.renderMinCells {
            var r = Int(rec[k])
            guard r >= 0, r < cnt, bandCoverage[r] >= 0.5 else { continue }
            var inside = 0
            while r >= 0 && r < cnt && bandCoverage[r] >= 0.5 && inside < 12 { r = Int(rec[r]); inside += 1 }
            guard r >= 0, r < cnt, inside < 12, landRiver[r] else { continue }
            var after = 0
            while r >= 0 && r < cnt && landRiver[r] && after < 4 { r = Int(rec[r]); after += 1 }
            if after >= 4 { out.rasterCrossings += 1 }
        }
        return out
    }
}
