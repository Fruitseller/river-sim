import Foundation

/// Lagrange-Zentrumslinien für die Mäander-Migration. Anders als die D8-
/// Entwässerung (Euler-Grid) ist ein Fluss hier eine *persistente* Polylinie mit
/// Gedächtnis: sie wandert über die Zeit (Prallhang erodiert → Außenkurve
/// verschiebt sich), schnürt Schlingen ab (Cutoff) und hinterlässt Altarme.
///
/// Dieser Kern ist bewusst grid-frei und deterministisch: er operiert nur auf
/// Knoten-Koordinaten (kontinuierliche Grid-Koords, x = Spalte i, z = Zeile j).
/// Die Rückkopplung ins Höhenfeld (Bett-Carve, Ufer-Verschiebung) macht separat
/// `Terrain.meanderStamp` — hier passiert noch nichts am Terrain.

public struct MeanderNode: Equatable, Sendable {
    public var x: Double // Spalte i (kontinuierlich)
    public var z: Double // Zeile j (kontinuierlich)
    public init(x: Double, z: Double) { self.x = x; self.z = z }
}

/// Ein durchgehender Flusslauf von der Quelle bis zur Mündung/zum See.
public struct RiverChannel: Sendable {
    public var nodes: [MeanderNode]
    public var discharge: [Double] // pro Knoten, in Zell-Flächen-Einheiten (∝ Abfluss)

    public init(nodes: [MeanderNode], discharge: [Double]) {
        precondition(nodes.count == discharge.count)
        self.nodes = nodes
        self.discharge = discharge
    }

    /// Frischt `discharge` je Knoten aus einem Feld-Sampler auf. Die Schleife
    /// steht hier statt beim Aufrufer, damit sie auf den EIGENEN (eindeutig
    /// referenzierten) Arrays läuft — über `terrain.meander.channels[ci]…`
    /// kostete jeder Knoten COW- und Exklusivitätsprüfungen (Issue #43).
    public mutating func refreshDischarge(_ sample: (Double, Double) -> Double) {
        for i in nodes.indices { discharge[i] = sample(nodes[i].x, nodes[i].z) }
    }

    /// Hält alle Knoten im Gitter [0, `maxCoord`] (Sicherheits-Clamp).
    /// Konstante zuerst (`min(maxCoord, max(0, …))`), damit ungültige
    /// Koordinaten (NaN) sicher zu 0 gefaltet werden.
    public mutating func clampToWorld(maxCoord: Double) {
        guard maxCoord >= 0, maxCoord.isFinite else { return }
        for i in nodes.indices {
            nodes[i].x = min(maxCoord, max(0, nodes[i].x))
            nodes[i].z = min(maxCoord, max(0, nodes[i].z))
        }
    }

    /// Lauflänge (Summe der Segmentlängen) in Zellen.
    public var length: Double {
        guard nodes.count > 1 else { return 0 }
        var s = 0.0
        for i in 1..<nodes.count { s += dist(nodes[i - 1], nodes[i]) }
        return s
    }

    /// Sinuosität = Lauflänge / Luftlinie (Quelle→Mündung). 1 = schnurgerade.
    public var sinuosity: Double {
        guard let a = nodes.first, let b = nodes.last else { return 1 }
        let straight = dist(a, b)
        return straight > 1e-9 ? length / straight : 1
    }
}

public final class MeanderState {
    public var channels: [RiverChannel] = []
    /// Abgeschnürte Schleifen (river-history). Alter in Jahren pro Altarm.
    public var oxbows: [[MeanderNode]] = []
    public var oxbowAge: [Double] = []
    /// Zähler der Cutoffs seit `generate`/`restore` (Diagnose für Issue #174,
    /// Abnahmepunkt 15) — kein Sim-Zustand: kein Pass liest sie.
    public private(set) var neckCutoffs = 0
    public private(set) var chuteCutoffs = 0

    // Wiederverwendbare Puffer des räumlichen Cutoff-Index (Produktion,
    // meanderSpatialCutoffIndex): flaches Bin-Gitter mit Linked-List statt
    // Dictionary-of-Arrays — das Dictionary allokierte je Kanal & Schritt und
    // war mit ~5% des Sim-Steps (n=832) der Mäander-Hotspot. `binHead` wird nur
    // an den tatsächlich belegten Zellen (binTouched) zurückgesetzt.
    private var binHead: [Int32] = []
    private var binNext: [Int32] = []
    private var binTouched: [Int32] = []
    private var binW = 0

    public init() {}

    /// Entfernt verlandete Altarme (Alter über `maxAge`) aus der river-history.
    public func pruneOxbows(maxAge: Double) {
        var no: [[MeanderNode]] = [], na: [Double] = []
        let count = min(oxbows.count, oxbowAge.count)
        for i in 0..<count where oxbowAge[i] <= maxAge {
            no.append(oxbows[i]); na.append(oxbowAge[i])
        }
        oxbows = no; oxbowAge = na
    }

    // MARK: - Migrations-Schritt

    /// Ein Migrations-Schritt über `dt` Jahre für alle Läufe:
    /// laterale Verschiebung ∝ Krümmung × Abfluss, dann Glättung, Resample auf
    /// uniformen Knotenabstand und Cutoff-Erkennung. `mobility` gated die
    /// Aktivität (0 = fixiert, z. B. steile Oberläufe; 1 = voll mobil, Flachland);
    /// im entkoppelten M1-Kern ist alles voll mobil.
    /// `heightAt` liefert die Geländehöhe an einer Knotenposition (für das
    /// Flachland-Gate über die *Längsneigung* entlang des Laufs — nicht die
    /// Querneigung, die an eingetieften Kanälen immer steil ist). Default 0 →
    /// überall voll mobil (entkoppelte Kernel-Tests).
    /// `riparianAt` liefert das mittlere Auwald-veg (0..1) im Ufer-Streifen um
    /// einen Knoten (Terrain.riparianVegAt): bewachsene Ufer sind kohäsiv und
    /// migrieren langsamer — Faktor (1 − meanderCohesion·riparianAt). Default 0
    /// → keine Kohäsion (entkoppelte Kernel-Tests bleiben unverändert).
    public func migrate(dt: Double, config: SimConfig,
                        heightAt: (MeanderNode) -> Double = { _ in 0 },
                        riparianAt: (MeanderNode) -> Double = { _ in 0 }) {
        let spacing = config.meanderNodeSpacing
        for age in oxbowAge.indices { oxbowAge[age] += dt }
        for ci in channels.indices {
            var ch = channels[ci]
            // Sinuositäts-Deckel: über der Schwelle migriert der Lauf NICHT weiter
            // (sonst tangeln einzelne Läufe zu Knäueln, Sinu → 7..26). Glättung und
            // Cutoff laufen weiter und holen ihn wieder unter die Schwelle → gedeckelt.
            if ch.sinuosity <= config.meanderMaxSinuosity {
                lateralStep(&ch, dt: dt, config: config, heightAt: heightAt,
                            riparianAt: riparianAt)
            }
            smooth(&ch.nodes, factor: config.meanderSmooth)
            applyCutoffs(&ch, config: config)
            ch = resample(ch, spacing: spacing) // Splice-Knick der Cutoffs glätten
            channels[ci] = ch
        }
    }

    /// Verschiebt jeden inneren Knoten lateral ∝ (signierte Krümmung × Abfluss).
    /// Positive Krümmung (Linksbogen) + linke Normale → weiter nach links: die
    /// bestehende Schlinge verstärkt sich (Howard–Knutson, lokale Variante).
    private func lateralStep(_ ch: inout RiverChannel, dt: Double, config: SimConfig,
                             heightAt: (MeanderNode) -> Double,
                             riparianAt: (MeanderNode) -> Double = { _ in 0 }) {
        let nodes = ch.nodes
        let count = nodes.count
        guard count >= 3 else { return }
        let k = config.meanderMigration
        let flat = config.meanderFlatSlope
        let cs = config.cellSize
        let maxStep = 0.5 * config.meanderNodeSpacing // CFL: kein Knoten springt >½ Abstand

        // Pass 1: signierte Krümmung, linke Normale, Mobilität, Segmentlänge je Knoten.
        var curv = [Double](repeating: 0, count: count)
        var nlx = [Double](repeating: 0, count: count)
        var nlz = [Double](repeating: 0, count: count)
        var mob = [Double](repeating: 0, count: count)
        var seg = [Double](repeating: config.meanderNodeSpacing, count: count)
        for i in 1..<(count - 1) {
            let a = nodes[i - 1], b = nodes[i], c = nodes[i + 1]
            let v1x = b.x - a.x, v1z = b.z - a.z
            let v2x = c.x - b.x, v2z = c.z - b.z
            let l1 = (v1x * v1x + v1z * v1z).squareRoot()
            let l2 = (v2x * v2x + v2z * v2z).squareRoot()
            let ds = 0.5 * (l1 + l2)
            if ds < 1e-9 { continue }
            seg[i] = ds
            let cross = v1x * v2z - v1z * v2x
            let dot = v1x * v2x + v1z * v2z
            curv[i] = atan2(cross, dot) / ds
            let tx = c.x - a.x, tz = c.z - a.z
            let tl = (tx * tx + tz * tz).squareRoot()
            if tl < 1e-9 { continue }
            nlx[i] = -tz / tl; nlz[i] = tx / tl // linke Normale der Sehne a→c
            let arc = (l1 + l2) * cs               // Flachland-Gate über die Längsneigung
            let longSlope = arc > 1e-9 ? abs(heightAt(a) - heightAt(c)) / arc : 0
            mob[i] = max(0, min(1, 1 - longSlope / flat))
        }

        // Pass 2: upstream-gewichtete Krümmung (Ikeda–Parker–Sawai). Die Bank­erosion
        // hängt von der stromauf integrierten Krümmung ab (das near-bank-Geschwindig­
        // keitsfeld lagt) → die Erosionsspitze verschiebt sich stromab, Schlingen
        // werden asymmetrisch (downstream-geskewt) statt symmetrisch. EMA über
        // steigendes i (= stromab), integriert also j<i (= stromauf).
        let beta = config.meanderSkew
        let lam = max(1e-6, config.meanderSkewLength)
        var eff = curv
        if beta > 0 {
            var ema = 0.0
            var sumC = 0.0, sumE = 0.0
            for i in 0..<count {
                eff[i] = (1 - beta) * curv[i] + beta * ema
                let w = exp(-seg[i] / lam)
                ema = ema * w + curv[i] * (1 - w)
                sumC += abs(curv[i]); sumE += abs(eff[i])
            }
            // Auf gleiche Gesamt-Stärke normieren: die EMA ist ein Tiefpass und
            // würde die Amplitude (und damit die Mäander-Rate) sonst dämpfen.
            // Der Skew verschiebt so nur die Phase (Erosionsspitze stromab).
            let sc = sumE > 1e-9 ? sumC / sumE : 1
            for i in 0..<count { eff[i] *= sc }
        }

        // Pass 3: Knoten entlang lokaler Normale verschieben (Betrag aus eff).
        let cohesion = config.meanderCohesion
        var out = nodes
        for i in 1..<(count - 1) {
            // −eff: zum Außenufer (weg vom Krümmungszentrum) → Schlinge verstärkt sich.
            // Ufer-Kohäsion: Auwald-bewachsene Ufer (riparianAt) bremsen die
            // Migration — Wurzelwerk hält den Prallhang (Stufe 2).
            let coh = cohesion > 0 ? max(0, min(1, riparianAt(nodes[i]))) : 0
            var m = -k * ch.discharge[i] * eff[i] * dt * mob[i] * (1 - cohesion * coh)
            m = max(-maxStep, min(maxStep, m)) // Displacement-Clamp gegen Verheddern
            out[i] = MeanderNode(x: nodes[i].x + m * nlx[i], z: nodes[i].z + m * nlz[i])
        }
        ch.nodes = out
    }

    /// Milde Laplace-Glättung (Endpunkte fest), hält den Lauf gegen die D8-
    /// Treppe und Zacken glatt, ohne die Amplifikation zu ersticken.
    private func smooth(_ nodes: inout [MeanderNode], factor: Double) {
        guard factor > 0, nodes.count >= 3 else { return }
        let src = nodes
        for i in 1..<(src.count - 1) {
            let lx = (src[i - 1].x + 2 * src[i].x + src[i + 1].x) * 0.25
            let lz = (src[i - 1].z + 2 * src[i].z + src[i + 1].z) * 0.25
            nodes[i].x = src[i].x + (lx - src[i].x) * factor
            nodes[i].z = src[i].z + (lz - src[i].z) * factor
        }
    }

    // MARK: - Cutoff (Abschnürung → Altarm)

    /// Schnürt Schlingen ab, deren Hals enger als `neckDist` ist, sofern die
    /// Schleife dazwischen entlang des Laufs deutlich länger ist (echter Hals,
    /// kein Nachbar). Die herausgeschnittene Schleife wird ein Altarm.
    private func applyCutoffs(_ ch: inout RiverChannel, config: SimConfig) {
        let neck = config.meanderNeckDist
        guard neck > 0, neck.isFinite else { return }
        let spacing = config.meanderNodeSpacing
        guard spacing.isFinite else { return }
        // Mindest-Index-Abstand: die Schleife muss ein Vielfaches des Halses lang
        // sein, sonst sind es bloß Nachbarknoten.
        // Verhältnis vor der Konvertierung begrenzen, um Int-Überlauf bei extrem
        // kleinem meanderNodeSpacing defensiv abzufangen.
        let rawSep = (neck / max(1e-6, spacing)) * 3
        let sepCount = (rawSep.isFinite && rawSep >= 0) ? Int(min(Double(ch.nodes.count + 2), rawSep)) : 0
        let minSep = max(4, sepCount + 2)
        var guardN = 0
        while guardN < 64 {
            guardN += 1
            var cut: (Int, Int)? = nil
            if config.meanderSpatialCutoffIndex {
                // Nur Knoten aus den eigenen/nebenliegenden Zellen können einen
                // Hals bilden. Das erhält das früheste (i, j) der Vollsuche.
                // Bin-Koordinaten werden ins Gitter GEKLEMMT (Knoten können während
                // der Migration kurz aus der Welt driften): Klemmen ist monoton →
                // Paare mit dist < neck bleiben in benachbarten Bins, und der exakte
                // dist-Filter macht das Ergebnis identisch zur Dictionary-Variante.
                // gw vor der Konversion begrenzen, um Int-Überlauf bei extrem
                // kleinem meanderNeckDist (z. B. 1e-300) und Speicher-Explosion
                // im flachen Bin-Gitter (gw * gw) defensiv zu verhindern.
                let rawGw = Double(config.n) / neck
                let gw = (rawGw.isFinite && rawGw >= 0) ? max(1, Int(min(4096.0, rawGw)) + 2) : 1
                if binW != gw { binW = gw; binHead = [Int32](repeating: -1, count: gw * gw) }
                let count = ch.nodes.count
                if binNext.count < count { binNext = [Int32](repeating: -1, count: count) }
                for c in binTouched { binHead[Int(c)] = -1 }
                binTouched.removeAll(keepingCapacity: true)
                @inline(__always) func binX(_ v: Double) -> Int {
                    guard v.isFinite else { return 0 }
                    let cell = (v / neck).rounded(.down)
                    guard cell >= 0 else { return 0 }
                    guard cell < Double(gw) else { return gw - 1 }
                    return Int(cell)
                }
                for i in 0..<count {
                    let b = binX(ch.nodes[i].z) * gw + binX(ch.nodes[i].x)
                    if binHead[b] < 0 { binTouched.append(Int32(b)) }
                    binNext[i] = binHead[b]
                    binHead[b] = Int32(i)
                }
                outer: for i in 0..<count {
                    let node = ch.nodes[i]
                    let x = binX(node.x), z = binX(node.z)
                    var bestJ = Int.max
                    for bz in max(0, z - 1)...min(gw - 1, z + 1) {
                        for bx in max(0, x - 1)...min(gw - 1, x + 1) {
                            var jj = binHead[bz * gw + bx]
                            while jj >= 0 {
                                let j = Int(jj)
                                jj = binNext[j]
                                if j >= i + minSep && j < bestJ && dist(node, ch.nodes[j]) < neck {
                                    bestJ = j
                                }
                            }
                        }
                    }
                    if bestJ < Int.max { cut = (i, bestJ); break outer }
                }
            } else {
                outer: for i in 0..<ch.nodes.count {
                    var j = i + minSep
                    while j < ch.nodes.count {
                        if dist(ch.nodes[i], ch.nodes[j]) < neck { cut = (i, j); break outer }
                        j += 1
                    }
                }
            }
            guard let (i, j) = cut else { break }
            oxbows.append(Array(ch.nodes[i...j]))
            oxbowAge.append(0)
            var newNodes = Array(ch.nodes[0...i])
            newNodes.append(contentsOf: ch.nodes[j...])
            var newDis = Array(ch.discharge[0...i])
            newDis.append(contentsOf: ch.discharge[j...])
            ch = RiverChannel(nodes: newNodes, discharge: newDis)
        }
    }

    // MARK: - Resample auf uniformen Knotenabstand

    /// Verteilt die Knoten auf ~uniformen Abstand `spacing` (Knoten stauen sich
    /// sonst in engen Bögen), Endpunkte bleiben exakt erhalten. Abfluss wird
    /// entlang der Bogenlänge mitinterpoliert.
    private func resample(_ ch: RiverChannel, spacing: Double) -> RiverChannel {
        let nodes = ch.nodes
        guard nodes.count >= 2, spacing > 0, spacing.isFinite else { return ch }
        var cum = [Double](repeating: 0, count: nodes.count)
        for i in 1..<nodes.count { cum[i] = cum[i - 1] + dist(nodes[i - 1], nodes[i]) }
        let total = cum[nodes.count - 1]
        guard total.isFinite else { return ch }
        if total < spacing { // zu kurz → nur Endpunkte
            return RiverChannel(nodes: [nodes[0], nodes[nodes.count - 1]],
                                discharge: [ch.discharge[0], ch.discharge[nodes.count - 1]])
        }
        // Schrittzahl vor der Konvertierung deckeln, um Int(inf) bzw. Überlauf bei
        // extrem kleinem spacing (z. B. meanderNodeSpacing = 1e-320) abzufangen.
        let rawSteps = (total / spacing).rounded()
        guard rawSteps.isFinite, rawSteps >= 0 else { return ch }
        let maxSteps = 65_536
        let steps = Int(min(Double(maxSteps), rawSteps))
        let count = max(2, steps + 1)
        var outN = [MeanderNode](); outN.reserveCapacity(count)
        var outD = [Double](); outD.reserveCapacity(count)
        var seg = 0
        for kk in 0..<count {
            let target = total * Double(kk) / Double(count - 1)
            while seg < nodes.count - 2 && cum[seg + 1] < target { seg += 1 }
            let segLen = cum[seg + 1] - cum[seg]
            let t = segLen > 1e-9 ? (target - cum[seg]) / segLen : 0
            outN.append(MeanderNode(x: nodes[seg].x + (nodes[seg + 1].x - nodes[seg].x) * t,
                                    z: nodes[seg].z + (nodes[seg + 1].z - nodes[seg].z) * t))
            outD.append(ch.discharge[seg] + (ch.discharge[seg + 1] - ch.discharge[seg]) * t)
        }
        return RiverChannel(nodes: outN, discharge: outD)
    }

    // MARK: - Initialisierung aus der D8-Entwässerung

    /// Tract die großen Läufe aus der Entwässerung (Quelle = große Zelle ohne
    /// großen Zufluss-Nachbarn; dann der Empfänger-Kette bis Meer/See folgen) und
    /// resampled sie auf `spacing`. EINZIGE Trasse im Projekt: die Render-Seite
    /// (`SimRender.RiverRibbonRenderer`) baut ihre Bänder aus den fertigen
    /// `terrain.meander.channels` und trasst nicht selbst — der frühere Zwilling
    /// `SimNode.buildRivers` ist mit f3556c8 entfallen.
    ///
    /// Mismatch der Pufferlängen, leere Terrains sowie Empfänger-Indizes außerhalb
    /// des Gitters (`r < 0 || r >= n*n`) werden defensiv abgefangen.
    public static func traceChannels(config: SimConfig, h: [Double], hf: [Double],
                                     area: [Double], receiver: [Int32]) -> [RiverChannel] {
        let n = config.n
        guard n > 0 else { return [] }
        let (count, overflow) = n.multipliedReportingOverflow(by: n)
        guard !overflow,
              h.count == count, hf.count == count,
              area.count == count, receiver.count == count else { return [] }
        let cellArea = config.cellSize * config.cellSize
        let minCells = config.meanderMinCells
        guard cellArea > 0, cellArea.isFinite,
              minCells > 0, minCells.isFinite else { return [] }
        let sea = config.sea
        let lakeEps = 0.035

        var isBig = [Bool](repeating: false, count: count)
        for k in 0..<count where hf[k] > sea && area[k] / cellArea >= minCells { isBig[k] = true }

        func isSource(_ k: Int) -> Bool {
            if !isBig[k] { return false }
            let i = k % n, j = k / n
            for dj in -1...1 {
                for di in -1...1 {
                    if di == 0 && dj == 0 { continue }
                    let ni = i + di, nj = j + dj
                    if ni < 0 || ni >= n || nj < 0 || nj >= n { continue }
                    let nb = nj * n + ni
                    if isBig[nb] && Int(receiver[nb]) == k { return false }
                }
            }
            return true
        }

        let state = MeanderState() // nur für resample() wiederverwendet
        var drawn = [Bool](repeating: false, count: count)
        var result: [RiverChannel] = []
        var sources = (0..<count).filter(isSource)
        if config.meanderBelt {
            // Hauptstamm zuerst (Hack): die Quelle mit dem längsten Fließweg zieht
            // den Stamm bis zur Mündung, Zubringer enden an ihm. In Index-
            // Reihenfolge besaß die zuerst gezogene Quelle den Unterlauf — oft eine
            // kurze nahe der Küste, und der Stamm zerfiel gemessen in Stummel
            // (größter Lauf: 30 Knoten). Feste Enden und die Rand-Ausblendung
            // lassen auf Stummeln keinen Bogen wachsen.
            var pathLen = [Int](repeating: 0, count: count)
            for s0 in sources {
                var c = s0, steps = 0
                while steps < count {
                    steps += 1
                    let r = Int(receiver[c])
                    if r < 0 || r >= count || hf[r] <= sea || hf[r] - h[r] > lakeEps { break }
                    c = r
                }
                pathLen[s0] = steps
            }
            sources.sort { pathLen[$0] != pathLen[$1] ? pathLen[$0] > pathLen[$1] : $0 < $1 }
        }
        for s in sources {
            var cells: [Int] = []
            var c = s, guardN = 0
            while guardN < count {
                guardN += 1
                cells.append(c)
                if drawn[c] && cells.count > 1 { break }
                drawn[c] = true
                let r = Int(receiver[c])
                if r < 0 || r >= count { break }
                if hf[r] <= sea || hf[r] - h[r] > lakeEps { break }
                c = r
            }
            if cells.count < 3 { continue }
            var nodes = [MeanderNode](); nodes.reserveCapacity(cells.count)
            var dis = [Double](); dis.reserveCapacity(cells.count)
            for k in cells {
                nodes.append(MeanderNode(x: Double(k % n), z: Double(k / n)))
                dis.append(area[k] / cellArea)
            }
            result.append(state.resample(RiverChannel(nodes: nodes, discharge: dis),
                                          spacing: config.meanderNodeSpacing))
        }
        return result
    }
}

// MARK: - Mäandergürtel (Issue #174, Paket B)

/// Geometrie eines Laufs auf Breiten-Skala, je Knoten.
struct BeltGeometry {
    /// Kanalbreite (Zellen).
    var width: [Double]
    /// Signierte Krümmung (1/Zellen) über ±k Knoten, k ≈ halbe Kanalbreite:
    /// Knicke unterhalb der Kanalbreite sind kein Bogen und treiben nichts.
    var curv: [Double]
    /// Linke Normale der Sehne über dieselben Knoten.
    var nx: [Double]
    var nz: [Double]
    /// Mobilität 0…1 aus der Längsneigung (Flachland-Gate, `meanderFlatSlope`).
    var mob: [Double]
}

extension MeanderState {
    /// Wandert dieser Lauf überhaupt? Erst ab `meanderBeltMinCells` Abfluss; der
    /// Abfluss ist entlang des Laufs monoton (`Terrain.refreshBeltDischarge`),
    /// das Ende reicht also. Nur diese Läufe (einige Dutzend von ~700) laufen
    /// durch die Teilschritte — vorher kostete der Gürtel 99 ms je Schritt.
    @inline(__always) static func migrates(_ ch: RiverChannel, _ config: SimConfig) -> Bool {
        (ch.discharge.last ?? 0) >= config.meanderBeltMinCells
    }

    /// Kanalbreite (Zellen) aus dem Abfluss — DIESELBE Kurve wie die
    /// Band-Geometrie (`WaterRender.ribbonHalfWidthCells`), damit Bett und Band
    /// gleich breit sind (Issue #174).
    public static func beltWidthCells(discharge: Double, config: SimConfig) -> Double {
        2 * WaterRender.ribbonHalfWidthCells(dischargeCells: discharge,
                                             referenceCells: config.renderMinCells)
    }

    static func beltGeometry(_ ch: RiverChannel, config: SimConfig,
                             heightAt: (MeanderNode) -> Double) -> BeltGeometry {
        let nodes = ch.nodes, c = nodes.count
        var g = BeltGeometry(width: .init(repeating: 0, count: c), curv: .init(repeating: 0, count: c),
                             nx: .init(repeating: 0, count: c), nz: .init(repeating: 0, count: c),
                             mob: .init(repeating: 0, count: c))
        let sp = max(1e-6, config.meanderNodeSpacing)
        let cs = config.cellSize, flat = config.meanderFlatSlope
        var cum = [Double](repeating: 0, count: c)
        for i in 1..<max(1, c) { cum[i] = cum[i - 1] + dist(nodes[i - 1], nodes[i]) }
        let total = cum[max(0, c - 1)]
        for i in 0..<c {
            let b = beltWidthCells(discharge: ch.discharge[i], config: config)
            g.width[i] = b
            guard i > 0, i < c - 1 else { continue }
            let k = max(1, min(min(i, c - 1 - i), Int((0.5 * b / sp).rounded())))
            let a = nodes[i - k], m = nodes[i], d = nodes[i + k]
            let v1x = m.x - a.x, v1z = m.z - a.z, v2x = d.x - m.x, v2z = d.z - m.z
            let l1 = (v1x * v1x + v1z * v1z).squareRoot(), l2 = (v2x * v2x + v2z * v2z).squareRoot()
            let ds = 0.5 * (l1 + l2)
            guard ds > 1e-9 else { continue }
            g.curv[i] = atan2(v1x * v2z - v1z * v2x, v1x * v2x + v1z * v2z) / ds
            let tx = d.x - a.x, tz = d.z - a.z, tl = (tx * tx + tz * tz).squareRoot()
            guard tl > 1e-9 else { continue }
            g.nx[i] = -tz / tl; g.nz[i] = tx / tl
            // Längsneigung über ±1,5 Kanalbreiten: über ±k (≈ 3 Zellen) brach
            // jede Stufe im eingeschnittenen Bett den mobilen Abschnitt auf
            // (gemessen 12–45 mobile Knoten am Hauptlauf von Seed 1337).
            let ks = max(k, min(min(i, c - 1 - i), Int((1.5 * b / sp).rounded())))
            let arc = (cum[i + ks] - cum[i - ks]) * cs
            let slope = arc > 1e-9 ? abs(heightAt(nodes[i - ks]) - heightAt(nodes[i + ks])) / arc : 0
            // Unter dem Meeresspiegel wandert nichts: der Schelf ist flach, ohne
            // das Gate liefen die Schlingen gemessen weit aufs Meer hinaus.
            g.mob[i] = flat > 0 && heightAt(m) > config.sea ? max(0, min(1, 1 - slope / flat)) : 0
            // Zu den festen Enden (Quelle, Mündung) hin ausblenden: der
            // Stromauf-Term staute sich gemessen am festen Endknoten zu Spiralen.
            g.mob[i] *= min(1, min(cum[i], total - cum[i]) / max(1e-6, 3 * b))
        }
        return g
    }

    /// Verschiebungsrate je Knoten (Zellen/Jahr entlang der linken Normalen)
    /// nach Howard–Knutson: `Ω·C + Γ·∫C stromauf`, Kern-Länge ∝ Breite, Rate
    /// ∝ Breite × (Breite · eff). Mit Mobilität und Ufer-Kohäsion.
    func beltRates(_ ch: RiverChannel, _ g: BeltGeometry, config: SimConfig,
                   heightAt: (MeanderNode) -> Double,
                   riparianAt: (MeanderNode) -> Double) -> [Double] {
        beltRatesAndErodibility(ch, g, config: config, heightAt: heightAt, riparianAt: riparianAt).rate
    }

    /// Rate (Zellen/Jahr) und Ufer-Erodierbarkeit je Knoten (0…1: Mobilität ×
    /// Kohäsion × Talwand-Bremse). Die Erodierbarkeit skaliert AUCH den
    /// impliziten Lokalterm in `migrateBelt`: bremste sie nur den
    /// Wachstumsterm, überwog an jeder gebremsten Stelle die Diffusion, und die
    /// Linie wurde gerade statt stehen zu bleiben (gemessen: Rate 1,5 Zellen je
    /// 1000 Jahre, Bewegung 0,2, Sinuosität fallend).
    func beltRatesAndErodibility(_ ch: RiverChannel, _ g: BeltGeometry, config: SimConfig,
                                 heightAt: (MeanderNode) -> Double,
                                 riparianAt: (MeanderNode) -> Double) -> (rate: [Double], erod: [Double]) {
        let nodes = ch.nodes, c = nodes.count
        var rate = [Double](repeating: 0, count: c)
        var erod = [Double](repeating: 0, count: c)
        var pull = [Double](repeating: 0, count: c)
        let ga = config.meanderBeltUpstreamWeight
        let kw = config.meanderBeltKernelWidths, e = config.meanderBeltRate
        let cohesion = config.meanderBeltCohesion
        // Örtliche Sinuosität über ±`meanderBeltSinuosityWidths` Breiten.
        var cum = [Double](repeating: 0, count: c)
        for i in 1..<c { cum[i] = cum[i - 1] + dist(nodes[i - 1], nodes[i]) }
        let sp = max(1e-6, config.meanderNodeSpacing)
        let s0 = config.meanderBeltSinuosityStart, s1 = config.meanderBeltSinuosityFull
        var ema = 0.0
        for i in 0..<c {
            let seg = i > 0 ? dist(nodes[i - 1], nodes[i]) : 0
            let w = exp(-seg / max(1e-6, kw * g.width[i]))
            ema *= w                                    // stromauf integriert, ohne Knoten i selbst
            // Nur der Stromauf-Term: der LOKALE Term (Ω < 0, zur Krümmungsmitte)
            // ist eine Diffusion der Linie mit κ = |Ω|·Rate·b² und läuft als
            // implizit stabile Glättung in `migrateBelt` (s. dort).
            let eff = ga * ema
            ema += g.curv[i] * (1 - w)
            guard i > 0, i < c - 1, g.mob[i] > 0, ch.discharge[i] >= config.meanderBeltMinCells else { continue }
            let coh = cohesion > 0 ? max(0, min(1, riparianAt(nodes[i]))) : 0
            let b = g.width[i]
            let m = max(1, Int((config.meanderBeltSinuosityWidths * b / sp).rounded()))
            let lo = max(0, i - m), hi = min(c - 1, i + m)
            let chord = dist(nodes[lo], nodes[hi])
            let localSinu = chord > 1e-9 ? (cum[hi] - cum[lo]) / chord : 1
            let sat = s1 > s0 ? max(0, min(1, (s1 - localSinu) / (s1 - s0))) : 1
            // −eff: zum Außenufer (weg vom Krümmungszentrum), wie `lateralStep`.
            var er = g.mob[i] * (1 - cohesion * coh)
            var r = -e * b * (b * eff) * er * sat
            // Querneigung: Ufer links gegen rechts (linke Normale), gemessen in
            // der Rinnen-Tiefe von `channelCarve` (mindestens Kanaltiefe): in
            // dieser Rinne liegt jeder D8-Lauf, sie ist hier „die Aue".
            // Ohne Querbezug lief die Linie gemessen am HANG entlang
            // (Längsneigung ~0 entlang der Höhenlinie, das Flachland-Gate sah
            // „flach"): 40 m Quergefälle über 16 Zellen, kein Profil sichtbar.
            let reach = 0.5 * b + 1.5
            let dref = max(1e-9, config.meanderBeltDepthPerWidth * config.cellSize * b,
                           config.channelTargetDepth)
            let hl = heightAt(MeanderNode(x: nodes[i].x + g.nx[i] * reach, z: nodes[i].z + g.nz[i] * reach))
            let hr = heightAt(MeanderNode(x: nodes[i].x - g.nx[i] * reach, z: nodes[i].z - g.nz[i] * reach))
            let cross = (hl - hr) / dref                   // > 0: links höher
            // Talwand-Bremse: liegt das Gelände ein paar Breiten weiter in
            // Bewegungsrichtung deutlich über der Linie (über
            // `meanderBeltBrakeDepths` Rinnentiefen), hält der Lauf — Hügel und
            // Talflanken begrenzen den Gürtel, Unebenheiten der Aue nicht.
            // Gemessen verworfen: Ufer gegen gegenüberliegendes Ufer direkt am
            // Kanal — das reagierte auf jedes sanfte Quergefälle und hielt die
            // Linie gerade (Sinuosität 1,1–1,2); ganz ohne Bremse lief der Lauf
            // über die Ebene ins Knäuel.
            if r != 0 {
                let dir = r > 0 ? 1.0 : -1.0
                let far = 0.5 * b + 3 * b
                let wall = heightAt(MeanderNode(x: nodes[i].x + dir * g.nx[i] * far,
                                                z: nodes[i].z + dir * g.nz[i] * far))
                let over = max(0, (wall - heightAt(nodes[i])) / dref - config.meanderBeltBrakeDepths)
                r /= 1 + over * over
                er /= 1 + over * over
            }
            erod[i] = er
            rate[i] = r
            // Zug zur tieferen Seite (Totband `meanderBeltPullDeadband`), unten
            // längs geglättet: koppelt die Linie an die Talsohle zurück, ohne
            // jeder zellgroßen Rinne nachzulaufen — ungeglättet zackte sie
            // gemessen in Bandbreite (2100 Hals-Cutoffs in 20.000 Jahren).
            let dz = max(0, abs(cross) - config.meanderBeltPullDeadband) * (cross > 0 ? 1 : -1)
            pull[i] = -config.meanderBeltPull * e * b * max(-3, min(3, dz)) * g.mob[i]
        }
        // Längs glätten: Zug über ±1 Breite, die Gesamtrate über ±½ Breite.
        // (`sp` von oben.)
        // Je Knoten verschiedene Bremsfaktoren verschoben Nachbarknoten
        // ungleich; der entstehende Zickzack im Knotenabstand liegt unter der
        // Krümmungs-Skala (±½ Breite), der negative Lokalterm sah ihn nicht,
        // und seine Knick-Krümmung trieb die CFL-Teilschritte gemessen in den
        // Deckel (64 in jedem Lauf).
        var out = rate
        for i in 1..<max(1, c - 1) {
            let kp = max(1, Int((g.width[i] / sp).rounded()))
            let kr = max(1, Int((0.5 * g.width[i] / sp).rounded()))
            var accP = 0.0, accR = 0.0
            let lp = max(1, i - kp), hp = min(c - 2, i + kp)
            for j in lp...hp { accP += pull[j] }
            let lr = max(1, i - kr), hr = min(c - 2, i + kr)
            for j in lr...hr { accR += rate[j] }
            out[i] = accR / Double(hr - lr + 1) + accP / Double(hp - lp + 1)
        }
        return (out, erod)
    }

    /// Größte Verschiebungsrate aller mobilen Läufe (Zellen/Jahr) — daraus
    /// bestimmt der Aufrufer die Teilschritte (CFL statt Deckel je Schritt).
    func beltMaxRate(config: SimConfig, heightAt: (MeanderNode) -> Double,
                     riparianAt: (MeanderNode) -> Double) -> Double {
        var m = 0.0
        for ch in channels where ch.nodes.count >= 3 && Self.migrates(ch, config) {
            let g = Self.beltGeometry(ch, config: config, heightAt: heightAt)
            for r in beltRates(ch, g, config: config, heightAt: heightAt, riparianAt: riparianAt) { m = max(m, abs(r)) }
        }
        return m
    }

    /// Ein Teilschritt der Gürtel-Migration über `dt` Jahre: Verschiebung,
    /// Glättung, Cutoffs (Hals und Chute), Resample. Der Aufrufer taktet so,
    /// dass kein Knoten mehr als einen halben Knotenabstand springt; die
    /// Klemme hier ist nur Sicherheitsnetz.
    func migrateBelt(dt: Double, config: SimConfig, heightAt: (MeanderNode) -> Double,
                     riparianAt: (MeanderNode) -> Double) {
        for age in oxbowAge.indices { oxbowAge[age] += dt }
        for ci in channels.indices where Self.migrates(channels[ci], config) {
            migrateBeltChannel(ci, dt: dt, config: config, heightAt: heightAt, riparianAt: riparianAt)
        }
    }

    /// Größte Verschiebungsrate EINES Laufs (Zellen/Jahr) — seine eigene
    /// CFL-Teilschrittzahl (`Terrain.meanderBeltStep`).
    func beltMaxRate(channel ci: Int, config: SimConfig, heightAt: (MeanderNode) -> Double,
                     riparianAt: (MeanderNode) -> Double) -> Double {
        let ch = channels[ci]
        guard ch.nodes.count >= 3, Self.migrates(ch, config) else { return 0 }
        let g = Self.beltGeometry(ch, config: config, heightAt: heightAt)
        return beltRates(ch, g, config: config, heightAt: heightAt, riparianAt: riparianAt)
            .reduce(0) { max($0, abs($1)) }
    }

    /// Ein Teilschritt für EINEN Lauf (ohne Altarm-Alterung, die macht der
    /// Aufrufer einmal je Schritt).
    func migrateBeltChannel(_ ci: Int, dt: Double, config: SimConfig,
                            heightAt: (MeanderNode) -> Double,
                            riparianAt: (MeanderNode) -> Double) {
        let spacing = config.meanderNodeSpacing
        let maxStep = 0.5 * spacing
        let kappaK = abs(config.meanderBeltLocalWeight) * config.meanderBeltRate / max(1e-12, spacing * spacing)
        do {
            var ch = channels[ci]
            if ch.nodes.count >= 3 {
                do {
                    let g = Self.beltGeometry(ch, config: config, heightAt: heightAt)
                    let (r, erod) = beltRatesAndErodibility(ch, g, config: config, heightAt: heightAt,
                                                            riparianAt: riparianAt)
                    for i in 1..<(ch.nodes.count - 1) where r[i] != 0 {
                        let m = max(-maxStep, min(maxStep, r[i] * dt))
                        ch.nodes[i].x += m * g.nx[i]; ch.nodes[i].z += m * g.nz[i]
                    }
                    // Lokaler Term als Diffusion der Linie, ∂x/∂t = κ·∂²x/∂s² mit
                    // κ = |Ω|·Rate·b²·Erodierbarkeit, IMPLIZIT (Rückwärts-Euler,
                    // tridiagonal): für jedes dt stabil und in der Zeit konsistent.
                    // Explizit (als Teil der Rate) war er nur bis dt ≈ ds²/(2κ)
                    // ≈ 3 Jahre stabil, die Linie zackte im Knotenabstand. Die
                    // Zwischenfassung als Glättung mit Faktor 1 − e^(−4κ·dt/ds²)
                    // sättigte schon bei dt = 50 auf 1 — die Diffusion wuchs dann
                    // mit der ZAHL der Teilschritte (gemessen 19 % Kanalbreite
                    // Abstand zwischen dt 50 und 1500).
                    // Erodierbarkeit (Mobilität, Kohäsion, Talwand) wirkt auf BEIDE
                    // Terme, s. `beltRatesAndErodibility`.
                    let c = ch.nodes.count
                    var a = [Double](repeating: 0, count: c)
                    for i in 1..<(c - 1) where erod[i] > 0 {
                        let b = g.width[i]
                        a[i] = kappaK * b * b * erod[i] * dt
                    }
                    ch.nodes = Self.implicitDiffuse(ch.nodes, a)
                }
            }
            applyBeltCutoffs(&ch, config: config)
            ch = resample(ch, spacing: spacing)
            channels[ci] = ch
        }
    }

    /// Zubringer bleiben an ihrem Vorfluter: jeder Lauf ist eine eigene
    /// Zentrumslinie, und `traceChannels` beendet einen Zubringer an der Zelle,
    /// an der er auf einen schon gezogenen Lauf trifft. Wandern beide, liefen sie
    /// gemessen als zwei, drei parallele Bänder durch denselben Gürtel zum Meer.
    /// Deshalb: kommt ein Lauf einem GRÖSSEREN (Abfluss am Ende) näher als
    /// die halbe Summe beider Breiten, endet er dort, und sein Endknoten sitzt
    /// auf dem nächsten Knoten des Vorfluters — auch in den folgenden
    /// Teilschritten, solange der Vorfluter in Reichweite (zwei Breiten) bleibt.
    func attachTributaries(config: SimConfig) {
        let cell = 8.0
        // Nachschlagen auf einer unveränderten Kopie: das Kürzen eines Laufs
        // unten darf die Indizes im Gitter nicht ungültig machen. Flaches
        // Bin-Gitter statt Dictionary (Allokationen, s. `applyBeltCutoffs`).
        let snap = channels
        let gw = max(1, Int(Double(config.n) / cell) + 3)
        var head = [Int32](repeating: -1, count: gw * gw)
        var flatC: [Int32] = [], flatN: [Int32] = [], next: [Int32] = []
        @inline(__always) func bin(_ v: Double) -> Int { min(gw - 1, max(0, Int(v / cell) + 1)) }
        for (ci, ch) in snap.enumerated() {
            for (ni, p) in ch.nodes.enumerated() {
                let b = bin(p.z) * gw + bin(p.x)
                next.append(head[b]); head[b] = Int32(flatC.count)
                flatC.append(Int32(ci)); flatN.append(Int32(ni))
            }
        }
        func nearestBigger(_ ci: Int, _ p: MeanderNode, _ q: Double, _ reach: (Double) -> Double)
            -> (MeanderNode, Double)? {
            var best: (MeanderNode, Double)? = nil
            let bx = bin(p.x), bz = bin(p.z)
            let qaEnd = snap[ci].discharge.last ?? 0
            for zz in max(0, bz - 2)...min(gw - 1, bz + 2) {
                for xx in max(0, bx - 2)...min(gw - 1, bx + 2) {
                    var e = head[zz * gw + xx]
                    while e >= 0 {
                        let cj = Int(flatC[Int(e)]), nj = Int(flatN[Int(e)]); e = next[Int(e)]
                        guard cj != ci, nj < snap[cj].nodes.count - 3 else { continue }
                        // Größer = der GANZE Lauf führt mehr (Abfluss am Ende). Der
                        // Abfluss an der Stelle taugt nicht: der Endknoten eines
                        // Zubringers liegt auf der Mündungszelle und trägt den
                        // Abfluss des Vorfluters — so zerhackte der Vergleich
                        // gemessen jeden Hauptlauf an jedem Zusammenfluss. Aus
                        // demselben Grund zählen die letzten Knoten nicht als Ziel.
                        let qbEnd = snap[cj].discharge.last ?? 0
                        guard qbEnd > qaEnd || (qbEnd == qaEnd && cj < ci) else { continue }
                        let o = snap[cj].nodes[nj]
                        let d = dist(p, o)
                        let bB = Self.beltWidthCells(discharge: snap[cj].discharge[nj], config: config)
                        if d < reach(bB), best == nil || d < best!.1 { best = (o, d) }
                    }
                }
            }
            return best
        }
        for ci in channels.indices {
            let ch = channels[ci]
            let c = ch.nodes.count
            guard c >= 3 else { continue }
            // Mündung in einen größeren Lauf: erster Knoten (ab Index 2) in Reichweite.
            for j in 2..<c {
                let q = ch.discharge[j]
                let bA = Self.beltWidthCells(discharge: q, config: config)
                if let (o, _) = nearestBigger(ci, ch.nodes[j], q, { 0.5 * (bA + $0) }) {
                    var nodes = Array(ch.nodes[0...j]), dis = Array(ch.discharge[0...j])
                    nodes[j] = o; dis[j] = q
                    if j + 1 < c || nodes[j] != ch.nodes[j] {
                        channels[ci] = RiverChannel(nodes: nodes, discharge: dis)
                    }
                    break
                }
                if j == c - 1, let (o, _) = nearestBigger(ci, ch.nodes[j], q, { 2 * $0 }) {
                    channels[ci].nodes[j] = o   // angeschlossenes Ende folgt dem Vorfluter
                }
            }
        }
    }

    /// Löst `−aᵢ·xᵢ₋₁ + (1 + 2aᵢ)·xᵢ − aᵢ·xᵢ₊₁ = xᵢ(alt)` für beide Koordinaten
    /// (Thomas-Algorithmus), Endknoten fest. `a` = κ·dt/ds² je Knoten.
    static func implicitDiffuse(_ nodes: [MeanderNode], _ a: [Double]) -> [MeanderNode] {
        let c = nodes.count
        guard c >= 3, a.contains(where: { $0 > 0 }) else { return nodes }
        var cp = [Double](repeating: 0, count: c)
        var dx = [Double](repeating: 0, count: c), dz = [Double](repeating: 0, count: c)
        // Zeile 0: x₀ fest.
        cp[0] = 0; dx[0] = nodes[0].x; dz[0] = nodes[0].z
        for i in 1..<(c - 1) {
            let lo = -a[i], di = 1 + 2 * a[i], up = -a[i]
            let m = di - lo * cp[i - 1]
            cp[i] = up / m
            dx[i] = (nodes[i].x - lo * dx[i - 1]) / m
            dz[i] = (nodes[i].z - lo * dz[i - 1]) / m
        }
        var out = nodes
        // Zeile c−1: Endknoten fest; Rückwärtseinsetzen.
        for i in stride(from: c - 2, through: 1, by: -1) {
            out[i].x = dx[i] - cp[i] * out[i + 1].x
            out[i].z = dz[i] - cp[i] * out[i + 1].z
        }
        return out
    }

    /// Hals-Cutoff (Halsweite unter `meanderBeltNeckWidths` Kanalbreiten) und
    /// Chute-Cutoff (Sehne unter `meanderChuteWidths` Breiten, Schleife
    /// mindestens `meanderChuteLoopRatio`-mal länger, Abfluss ab
    /// `meanderChuteMinCells`). Früheste Abschnürung zuerst, wie `applyCutoffs`.
    private func applyBeltCutoffs(_ ch: inout RiverChannel, config: SimConfig) {
        let spacing = max(1e-6, config.meanderNodeSpacing)
        var guardN = 0
        while guardN < 64, ch.nodes.count >= 4 {
            guardN += 1
            let nodes = ch.nodes, c = nodes.count
            var cum = [Double](repeating: 0, count: c)
            for i in 1..<c { cum[i] = cum[i - 1] + dist(nodes[i - 1], nodes[i]) }
            var maxReach = 0.0                                 // größte Prüfweite
            for i in 0..<c {
                let b = Self.beltWidthCells(discharge: ch.discharge[i], config: config)
                let neck = max(config.meanderNeckDist, config.meanderBeltNeckWidths * b)
                let chute = ch.discharge[i] >= config.meanderChuteMinCells ? config.meanderChuteWidths * b : 0
                maxReach = max(maxReach, max(neck, chute))
            }
            guard maxReach > 0, maxReach.isFinite else { return }
            // Flaches Bin-Gitter (Kantenlänge maxReach, verkettete Listen):
            // Kandidaten nur aus den 3×3 Nachbar-Bins. Ein Dictionary allokierte
            // je Lauf und Teilschritt und trug den Großteil der Gürtel-Kosten.
            let gw = max(1, Int(Double(config.n) / maxReach) + 3)
            var head = [Int32](repeating: -1, count: gw * gw)
            var next = [Int32](repeating: -1, count: c)
            @inline(__always) func bin(_ v: Double) -> Int { min(gw - 1, max(0, Int(v / maxReach) + 1)) }
            for i in 0..<c {
                let b = bin(nodes[i].z) * gw + bin(nodes[i].x)
                next[i] = head[b]; head[b] = Int32(i)
            }
            var cut: (Int, Int, Bool)? = nil
            outer: for i in 0..<c {
                let b = Self.beltWidthCells(discharge: ch.discharge[i], config: config)
                let neck = max(config.meanderNeckDist, config.meanderBeltNeckWidths * b)
                let chute = ch.discharge[i] >= config.meanderChuteMinCells ? config.meanderChuteWidths * b : 0
                let minSep = max(4, Int(neck / spacing * 3) + 2)
                let maxLoop = config.meanderBeltMaxLoopWidths * b
                let bx = bin(nodes[i].x), bz = bin(nodes[i].z)
                var best: (Int, Bool)? = nil
                for zz in max(0, bz - 1)...min(gw - 1, bz + 1) {
                    for xx in max(0, bx - 1)...min(gw - 1, bx + 1) {
                        var jj = head[zz * gw + xx]
                        while jj >= 0 {
                            let j = Int(jj); jj = next[j]
                            guard j >= i + minSep, best == nil || j < best!.0,
                                  cum[j] - cum[i] <= maxLoop else { continue }
                            let d = dist(nodes[i], nodes[j])
                            if d < neck { best = (j, false) }
                            else if d < chute && cum[j] - cum[i] >= config.meanderChuteLoopRatio * d {
                                best = (j, true)
                            }
                        }
                    }
                }
                if let (j, isChute) = best { cut = (i, j, isChute); break outer }
            }
            guard let (i, j, isChute) = cut else { break }
            if isChute { chuteCutoffs += 1 } else { neckCutoffs += 1 }
            oxbows.append(Array(ch.nodes[i...j]))
            oxbowAge.append(0)
            var newNodes = Array(ch.nodes[0...i]); newNodes.append(contentsOf: ch.nodes[j...])
            var newDis = Array(ch.discharge[0...i]); newDis.append(contentsOf: ch.discharge[j...])
            ch = RiverChannel(nodes: newNodes, discharge: newDis)
        }
    }
}

@inline(__always) func dist(_ a: MeanderNode, _ b: MeanderNode) -> Double {
    let dx = a.x - b.x, dz = a.z - b.z
    return (dx * dx + dz * dz).squareRoot()
}
