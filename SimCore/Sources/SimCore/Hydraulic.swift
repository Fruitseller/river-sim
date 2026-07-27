import Foundation

/// Droplet-basierte Hydraulik-Erosion (Sebastian Lague / nickmcd). Anders als das
/// Grid-Stream-Power-Modell **carvt** sie feine dendritische Rinnen: viele
/// Wassertropfen laufen bergab, erodieren am steilen Hang (über einen Pinsel
/// verteilt → weiche Kerben) und lagern Sediment in flacheren Abschnitten/Senken
/// wieder ab. Deterministisch (Mulberry32-Seed) und headless-testbar.
public struct HydraulicParams: Sendable {
    public var inertia = 0.05       // 0 = folgt dem Gradienten, 1 = Richtung bleibt
    public var capacity = 4.0       // Sedimentkapazität ∝ Steigung·Speed·Wasser
    public var minSlope = 0.01      // Mindest-Steigung für Kapazität (kein Stagnieren)
    public var erodeRate = 0.3      // Anteil des Kapazitätsdefizits, der erodiert
    public var depositRate = 0.3    // Anteil des Überschusses, der abgelagert wird
    public var evaporate = 0.02     // Wasserverlust je Tropfen-Schritt
    public var gravity = 4.0
    public var maxSteps = 144       // Schritte je Tropfen. Von 64 erhöht (nickmcd: Tropfen leben bis zur Mündung): 64 starb auf halbem Weg den Hang hinunter → die Unterläufe großer Flüsse bekamen nie Tropfen (keine Tracks, kein Carven der Auen-Ebenen). 192 kostete ~25% mehr ohne sichtbaren Zugewinn.
    public var erodeRadius = 3      // Pinsel-Radius fürs Erodieren (weiche Rinnen)
    public var initialWater = 1.0
    public var initialSpeed = 1.0
    // ---- nickmcd-Kopplung (Procedural Hydrology) ----
    public var streamEvapDamp = 0.5 // Verdunstung ×(1−damp·stream): auf etablierten Läufen leben Tropfen länger → Flüsse verlängern/schärfen sich selbst (sein „River Sharpening", effR = evap·(1−0.2·stream) sinngemäß)
    public var poolDepth = 0.03     // ab dieser Wassertiefe (hf−h) gilt eine Zelle als SEE (= See-Render-Schwelle): Tropfen deponiert dort sein Sediment (Delta) und läuft am Auslass weiter. Flacheres Ponding (Auen-Washes) behandeln Tropfen normal — sie sollen es CARVEN und damit entwässern, nicht überspringen (0.02 ließ Tropfen auf den Ebenen permanent teure Ketten-Sprünge machen → FPS-Einbruch)
    public var poolSedimentKeep = 0.1 // Sediment-Anteil, der den See überlebt (nickmcd: −90% beim Drain)
    public init() {}
}

public enum Hydraulic {
    /// Führt `count` Tropfen aus und modifiziert `h`/`rock`/`sed` massenkonsistent
    /// (h = rock + sed). `seed` steuert die (deterministischen) Startpositionen.
    ///
    /// nickmcd-Kopplung (Procedural Hydrology), alle optional:
    /// - `track`: besuchte Zellen werden markiert → `Terrain.streamMap`
    ///   (zeitgemittelte Partikel-Pfade = seine Stream-Map).
    /// - `stream`: etablierte Läufe (0..1) senken die Verdunstung → Tropfen leben
    ///   dort länger, Flüsse schärfen/verlängern sich selbst (River Sharpening).
    /// - `hf`/`receiver`: Tropfen, der in einen See läuft (hf−h > poolDepth),
    ///   deponiert sein Sediment als DELTA am Eintritt, springt der Empfänger-
    ///   Kette entlang zum See-Auslass und läuft dort mit 10% Sediment weiter
    ///   (sein Descend→Flood→Drain-Zyklus, ohne den See selbst zu carven).
    public static func erode(h: inout [Double], rock: inout [Double], sed: inout [Double],
                             n: Int, count: Int, seed: UInt32, floor: Double,
                             p: HydraulicParams,
                             hf: [Double] = [], receiver: [Int32] = [],
                             stream: [Double] = [], track: inout [Double]) {
        guard count > 0, n > 2 else { return }
        // Erosions-Pinsel einmal vorberechnen: Offsets + normierte Gewichte im Radius.
        var bx: [Int] = [], byv: [Int] = [], bw: [Double] = []
        let r = p.erodeRadius
        var wsum = 0.0
        for dy in -r...r {
            for dx in -r...r {
                let d = (Double(dx * dx + dy * dy)).squareRoot()
                if d > Double(r) { continue }
                let w = 1 - d / Double(r)
                bx.append(dx); byv.append(dy); bw.append(w); wsum += w
            }
        }
        for i in bw.indices { bw[i] /= wsum }

        // Erosion gibt den tatsächlich abgetragenen Betrag zurück (am Boden gedeckelt),
        // damit die Sedimentbilanz stimmt.
        @inline(__always) func modify(_ k: Int, _ delta: Double) -> Double {
            if delta >= 0 { sed[k] += delta; h[k] += delta; return delta }
            var d = -delta
            let room = h[k] - floor
            if room <= 0 { return 0 } // schon am Tiefseeboden
            if d > room { d = room }  // nicht unter den Boden graben
            let take = min(d, sed[k])
            sed[k] -= take
            rock[k] -= (d - take)
            h[k] -= d
            return d
        }

        var rnd = Mulberry32(seed: seed)
        for _ in 0..<count {
            var px = rnd.next() * Double(n - 1)
            var py = rnd.next() * Double(n - 1)
            var dirX = 0.0, dirY = 0.0
            var speed = p.initialSpeed, water = p.initialWater, sediment = 0.0

            for step in 0..<p.maxSteps {
                let nodeX = Int(px), nodeY = Int(py)
                if nodeX < 0 || nodeX >= n - 1 || nodeY < 0 || nodeY >= n - 1 { break }
                let fx = px - Double(nodeX), fy = py - Double(nodeY)
                let k = nodeY * n + nodeX
                // Besuchs-Zählung → streamMap, gewichtet nach Tropfen-REIFE: die
                // ersten Schritte ab Spawn liegen auf zufälligen Hängen (jeder
                // Tropfen woanders → Rauschen), gereifte Tropfen sind ins Talnetz
                // konvergiert (immer dieselben Zellen → Flüsse). Ohne Gewicht
                // liegt das Rauschband nur ~5× unter den Trunk-Raten.
                if !track.isEmpty { track[k] += min(1.0, Double(step) / 40) }

                // See-Interaktion (nickmcd Descend→Flood→Drain): Sediment als
                // Delta am Eintritt abladen, zum Auslass springen, weiterlaufen.
                if !hf.isEmpty && hf[k] - h[k] > p.poolDepth {
                    let dep = sediment * (1 - p.poolSedimentKeep)
                    _ = modify(k, dep)
                    sediment -= dep
                    var c = k, guardN = 0
                    var exited = false
                    while guardN < 4 * n {
                        guardN += 1
                        let r = receiver.isEmpty ? -1 : receiver[c]
                        if r < 0 { break }
                        c = Int(r)
                        if hf[c] - h[c] <= p.poolDepth { exited = true; break }
                    }
                    if !exited { break } // See ohne Auslass (Meer/Rand) → Tropfen endet
                    px = Double(c % n); py = Double(c / n)
                    dirX = 0; dirY = 0
                    speed = p.initialSpeed
                    continue
                }
                let hNW = h[k], hNE = h[k + 1], hSW = h[k + n], hSE = h[k + n + 1]
                // Höhe + Gradient (bilinear)
                let gradX = (hNE - hNW) * (1 - fy) + (hSE - hSW) * fy
                let gradY = (hSW - hNW) * (1 - fx) + (hSE - hNE) * fx
                let height = hNW * (1 - fx) * (1 - fy) + hNE * fx * (1 - fy)
                           + hSW * (1 - fx) * fy + hSE * fx * fy

                // Richtung mit Trägheit aktualisieren, dann normieren.
                dirX = dirX * p.inertia - gradX * (1 - p.inertia)
                dirY = dirY * p.inertia - gradY * (1 - p.inertia)
                let len = (dirX * dirX + dirY * dirY).squareRoot()
                if len < 1e-9 { break } // flach & richtungslos → Tropfen endet
                dirX /= len; dirY /= len
                let npx = px + dirX, npy = py + dirY
                if npx < 0 || npx >= Double(n - 1) || npy < 0 || npy >= Double(n - 1) { break }

                // Höhendifferenz zum neuen Punkt.
                let nnx = Int(npx), nny = Int(npy)
                let nfx = npx - Double(nnx), nfy = npy - Double(nny)
                let nk = nny * n + nnx
                let newHeight = h[nk] * (1 - nfx) * (1 - nfy) + h[nk + 1] * nfx * (1 - nfy)
                             + h[nk + n] * (1 - nfx) * nfy + h[nk + n + 1] * nfx * nfy
                let deltaH = newHeight - height

                // Sedimentkapazität an dieser Stelle.
                let capacity = max(-deltaH, p.minSlope) * speed * water * p.capacity

                if sediment > capacity || deltaH > 0 {
                    // Überschuss (oder bergauf) → ablagern, bilinear auf die 4 Zellen.
                    let dep = (deltaH > 0) ? min(deltaH, sediment)
                                           : (sediment - capacity) * p.depositRate
                    sediment -= dep
                    _ = modify(k, dep * (1 - fx) * (1 - fy))
                    _ = modify(k + 1, dep * fx * (1 - fy))
                    _ = modify(k + n, dep * (1 - fx) * fy)
                    _ = modify(k + n + 1, dep * fx * fy)
                } else {
                    // Unter Kapazität → erodieren, aber nicht mehr als das Gefälle
                    // (kein Löchergraben), über den Pinsel verteilt.
                    let ero = min((capacity - sediment) * p.erodeRate, -deltaH)
                    if ero > 0 {
                        for i in bx.indices {
                            let cx = nodeX + bx[i], cy = nodeY + byv[i]
                            if cx < 0 || cx >= n || cy < 0 || cy >= n { continue }
                            let ck = cy * n + cx
                            sediment += modify(ck, -ero * bw[i])
                        }
                    }
                }

                // Speed aus Gefälle (bergab → schneller), Wasser verdunstet —
                // auf etablierten Läufen LANGSAMER (nickmcd-Sharpening: Tropfen
                // im Fluss leben länger → der Fluss verlängert/verstärkt sich).
                speed = (max(0, speed * speed - deltaH * p.gravity)).squareRoot()
                let sv = stream.isEmpty ? 0.0 : min(1, max(0, stream[k]))
                water *= (1 - p.evaporate * (1 - p.streamEvapDamp * sv))
                px = npx; py = npy
                if water < 1e-3 { break }
            }
        }
    }
}
