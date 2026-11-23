import XCTest
@testable import SimCore

final class LakeLevelStability: XCTestCase {
    func testWaterLevelDampsFillJumps() {
        var c = SimConfig.production; c.rangeLandform = calibrationRangeLandform
        let t = Terrain(config: c, seed: 1337)
        var years = 0.0
        while years < 2000 { t.step(dtYears: 20); years += 20 }

        let n = t.cfg.n, cnt = t.cfg.count, sea = t.cfg.sea
        var visited = [Bool](repeating: false, count: cnt)
        var basin: [Int] = []
        for s in 0..<cnt where !visited[s] && t.hf[s] > sea && t.hf[s] - t.h[s] > 0.02 {
            var stack = [s]; visited[s] = true
            var comp: [Int] = []
            while let k = stack.popLast() {
                comp.append(k)
                let i = k % n, j = k / n
                for (di, dj) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let ni = i + di, nj = j + dj
                    guard ni >= 0, ni < n, nj >= 0, nj < n else { continue }
                    let nk = nj * n + ni
                    if !visited[nk] && t.hf[nk] > sea && t.hf[nk] - t.h[nk] > 0.02 {
                        visited[nk] = true; stack.append(nk)
                    }
                }
            }
            if comp.count > basin.count { basin = comp }
        }
        XCTAssertGreaterThan(basin.count, 500, "kein nennenswertes Becken gefunden")

        let inv = 1.0 / Double(basin.count)
        var prevHF = 0.0, prevWL = 0.0
        for k in basin { prevHF += t.hf[k] * inv; prevWL += t.waterLevel[k] * inv }
        var maxHFJump = 0.0, maxWLJump = 0.0
        for _ in 0..<150 {
            t.step(dtYears: 20)
            var mhf = 0.0, mwl = 0.0
            for k in basin { mhf += t.hf[k] * inv; mwl += t.waterLevel[k] * inv }
            maxHFJump = max(maxHFJump, mhf - prevHF)
            maxWLJump = max(maxWLJump, mwl - prevWL)
            prevHF = mhf; prevWL = mwl
        }
        guard maxHFJump > 0.0005 else { return }
        XCTAssertLessThan(maxWLJump, 0.35 * maxHFJump,
            "Seespiegel folgt hf-Sprüngen fast ungedämpft — Glättung defekt?")
        XCTAssertLessThan(maxWLJump, 0.0015,
            "Seespiegel-Sprünge über der Sichtbarkeitsschwelle")
    }

    func testWaterLevelNeverStandsAboveFill() {
        let t = Terrain(config: renderConfig(n: 96), seed: 1337)
        var maxAbove = 0.0, fell = 0
        for _ in 0..<10 {
            let before = t.hf
            t.step(dtYears: 20)
            for k in 0..<t.cfg.count {
                maxAbove = max(maxAbove, t.waterLevel[k] - t.hf[k])
                if t.hf[k] < before[k] - 1e-6 { fell += 1 }
            }
        }
        XCTAssertGreaterThan(fell, 0, "kein fallender Füllstand — der Test prüft nichts")
        XCTAssertLessThanOrEqual(maxAbove, 0,
            "Darstellungs-Spiegel über dem Füllstand: Geister-See auf trockenem Boden")
    }
}

