import XCTest
@testable import SimCore

/// Wächter gegen „hüpfende Seeflächen": Deposition am Becken-Auslass (Droplets,
/// Braiding, Mäander) schüttet den Sill zu → Priority-Flood hebt `hf` INSTANTAN
/// fürs ganze Becken, die Auslass-Inzision schneidet über ~100 J. zurück
/// (Plug/Breach-Sägezahn). Der Darstellungs-Seespiegel `waterLevel` folgt `hf`
/// deshalb ratenbegrenzt (`lakeLevelResponseYears`) — dieser Test stellt sicher,
/// dass die Glättung wirkt und niemand das Rendering zurück auf `hf` verdrahtet.
final class LakeLevelStability: XCTestCase {
    private func prodConfig() -> SimConfig {
        var c = SimConfig()
        c.hydraulicSkipWaterSpawns = true
        c.meanderSpatialCutoffIndex = true
        return c
    }

    func testWaterLevelDampsFillJumps() {
        let t = Terrain(config: prodConfig(), seed: 1337)
        // Warmup wie eine frühe Spielsession (kleine Echtzeit-Schritte).
        var years = 0.0
        while years < 2000 { t.step(dtYears: 20); years += 20 }

        // Größtes gefülltes Becken (zusammenhängend, 4er-Nachbarschaft) fixieren.
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

        // Mittleren Füllstand (hf) und Seespiegel (waterLevel) übers fixierte
        // Becken loggen; größter Anstieg je 20-J.-Schritt = Sägezahn-Amplitude.
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
        // Ohne Sägezahn im Füllstand gibt es nichts zu dämpfen (wäre sogar gut).
        guard maxHFJump > 0.0005 else { return }
        // Mathematisch springt waterLevel je Schritt höchstens um den Anteil
        // lam = 1−exp(−20/250) ≈ 0.08 der hf-Abweichung; 0.35 lässt Marge für
        // echte (langsame) Pegeländerungen, die sich auf den Sprung addieren.
        XCTAssertLessThan(maxWLJump, 0.35 * maxHFJump,
            "Seespiegel folgt hf-Sprüngen fast ungedämpft — Glättung defekt?")
        XCTAssertLessThan(maxWLJump, 0.0015,
            "Seespiegel-Sprünge über der Sichtbarkeitsschwelle")
    }
}
