import Foundation

/// Droplet-basierte Hydraulik-Erosion (Sebastian Lague / nickmcd). Anders als das
/// Grid-Stream-Power-Modell **carvt** sie feine dendritische Rinnen: viele
/// Wassertropfen laufen bergab, erodieren am steilen Hang (über einen Pinsel
/// verteilt → weiche Kerben) und lagern Sediment in flacheren Abschnitten/Senken
/// wieder ab. Deterministisch (Mulberry32-Seed) und headless-testbar.
/// `Codable`/`Equatable`: Teil der Config im Weltformat (s. `SimConfig`).
public struct HydraulicParams: Sendable, Codable, Equatable {
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
    // ---- Mäander-Kanal-Reconciliation (isChannel-Maske) ----
    // Der Mäander-Kanal carvt sein Bett selbst (Terrain.meanderStamp), der
    // Droplet-Pfad kannte diese Maske bisher nicht (nur der Grid-Pfad, via
    // cfg.channelErodeDamp) — in Produktion (hydraulicEnabled) arbeiteten
    // Kanal und Tropfen also gegeneinander. GEMESSEN (n=256, 3 Seeds, 40k+150k J.,
    // Bett-Tiefe der Kanalzellen gegen die Aue, testChannelBedSurvivesDroplets):
    // Nur die DEPOSITION ist der Konflikt — sie schüttet das Bett zu (14–15% der
    // Betten lagen über ihrer Aue). Die Tropfen-EROSION im Bett zieht dagegen in
    // dieselbe Richtung wie der Carve (sie tieft ein); ihre Dämpfung machte das
    // Bett flacher (+0.0147→+0.0116) und die Verlandung schlimmer (8.7%→12.7%) —
    // deshalb gibt es hier bewusst KEIN Erosions-Pendant zu channelErodeDamp.
    public var channelDepositDamp = 0.15 // Tropfen-Deposition auf Kanalzellen. Der nicht
                                         // abgelegte Rest bleibt in Suspension (Massenbilanz)
                                         // → der Kanal TRANSPORTIERT das Sediment weiter,
                                         // statt zu verlanden. 0.0 (gar keine Ablagerung) ist
                                         // instabil: der Tropfen dumpt seine Gesamtlast am
                                         // ersten Nicht-Kanal-Hindernis → Halden, Relief-Runaway
                                         // (150k J.: relief 1.22, maxH 1.37). 0.15/0.10 sind
                                         // messgleich, 0.15 hält Abstand zu dieser Kante.
    public init() {}
}

public enum Hydraulic {
    /// Deckel der Ablehnungs-Stichprobe für niederschlagsgewichtete Startpunkte
    /// (s. `spawnPosition`): so viele NEUZIEHUNGEN sind je Tropfen erlaubt, danach
    /// wird der letzte Vorschlag angenommen — der Aufwand je Tropfen bleibt hart
    /// beschränkt. Die Annahmerate je Vorschlag ist Mittel(w)/max(w); mit dem auf
    /// das Landmittel normierten Gewicht (Issue #10) ist Mittel(w) ≈ 1 und
    /// max(w) gemessen 1.84 … 2.91 (n=832, Seeds 1337/7/99, über 50k Jahre
    /// fallend) → 0.34 … 0.54, im Erwartungswert also 2–3 Vorschläge je Start.
    /// Rest-Verzerrung durch den Deckel: mit dem ungünstigsten gemessenen max(w)
    /// endet ein Start mit 0.66^24 ≈ 2·10⁻⁵ auf einem nicht angenommenen
    /// Vorschlag — gegen die 5.6-fache Gewichtsspanne vernachlässigbar.
    static let spawnRejectionTries = 24

    /// Zufallsstrom des Tropfens mit der laufenden Nummer `index` (Issue #2).
    ///
    /// Hier wird ein SEQUENZIELLER Generator als HASH über den Index benutzt —
    /// und dafür muss der Index vorher richtig gemischt werden. Mulberry32 ist
    /// darauf ausgelegt, aus einem laufenden Zustand gute FOLGEN zu liefern,
    /// nicht darauf, aus benachbarten Startzuständen gute ERSTE Ausgaben zu
    /// liefern. Genau das braucht der Tropfen aber: seine ersten beiden
    /// Ausgaben sind der Startpunkt, die dritte ist der Annahme-Zug der
    /// Ablehnungs-Stichprobe (`spawnPosition`) — sind die nicht unabhängig,
    /// entscheidet nicht mehr das Niederschlagsgewicht über die Annahme,
    /// sondern eine Eigenschaft des Startpunkts selbst.
    ///
    /// GEMESSEN, weil zuerst falsch gemacht: mit nur `index · 2654435761`
    /// (goldener Schnitt, wie vorher für die Schrittnummer) fiel die gewichtete
    /// Luv/Lee-Drainagedichte von ×1.14 (`main`) auf ×1.01 — die
    /// Niederschlags-Gewichtung war praktisch wirkungslos, obwohl Randverteilung
    /// (Chi² 67 gegen 63 df) und Serienkorrelation (lag-1 ~1e-3) der Startpunkte
    /// unauffällig blieben. Der Fehler steckte allein in der Kopplung zwischen
    /// Position und Annahme-Zug. Mit splitmix64-Finalizer und einem
    /// Aufwärm-Zug steht sie bei ×1.21 (`RainWeightedFlow`-Wächter).
    @inline(__always)
    static func dropRNG(seed: UInt32, index: UInt64) -> Mulberry32 {
        var z = index &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        var r = Mulberry32(seed: seed &+ UInt32(truncatingIfNeeded: z))
        _ = r.next()
        return r
    }

    /// Zieht einen Tropfen-Startpunkt in Zellkoordinaten.
    ///
    /// - `weight` leer → gleichverteilt über das Grid, mit exakt ZWEI Ziehungen aus
    ///   `rnd` (bit-identisch zum Zustand vor Issue #9).
    /// - `weight` gesetzt (= `Terrain.rainWeight`) → Ablehnungs-Stichprobe (von Neumann):
    ///   Vorschlag gleichverteilt, angenommen mit Wahrscheinlichkeit
    ///   `weight[k] / weightMax` → die Startdichte ist ∝ Niederschlag, ohne dass
    ///   eine 700k-Zellen-Verteilungstabelle je Charge gebaut werden muss.
    ///   Zellen mit Maximalgewicht werden OHNE Ziehung angenommen — dadurch ist ein
    ///   konstantes Gewichtsfeld bit-identisch zum ungewichteten Fall (Wächter:
    ///   `testUniformRainWeightIsBitIdentical`).
    static func spawnPosition(_ rnd: inout Mulberry32, n: Int,
                              weight: [Double], weightMax: Double) -> (x: Double, y: Double) {
        var px = rnd.next() * Double(n - 1)
        var py = rnd.next() * Double(n - 1)
        guard !weight.isEmpty, weightMax > 0 else { return (px, py) }
        var tries = 0
        while true {
            let w = weight[Int(py) * n + Int(px)]
            if w >= weightMax { break }              // Maximum → immer angenommen
            if rnd.next() * weightMax <= w { break } // angenommen
            if tries >= spawnRejectionTries { break }
            tries += 1
            px = rnd.next() * Double(n - 1)
            py = rnd.next() * Double(n - 1)
        }
        return (px, py)
    }

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
    /// - `channel`: Mäander-Kanalzellen (Terrain.isChannel). Dort ist die Tropfen-
    ///   DEPOSITION gedämpft (channelDepositDamp) — das Bett gehört dem Kanal-Carve
    ///   und darf nicht zugeschüttet werden. Leeres Array = Verhalten wie ohne Maske
    ///   (bit-identisch).
    /// - `rainWeight`: normiertes Niederschlags-Gewicht (Terrain.rainWeight,
    ///   Issue #9/#10). Die Startpunkte werden damit gewichtet (s.
    ///   `spawnPosition`) — es regnet im Luv häufiger, also starten dort auch mehr
    ///   Tropfen. Über See trägt das Feld den neutralen Wert 1.0, damit `seaLevel`
    ///   (verworfene Ozean-Starts) denselben Anteil verwirft wie ungewichtet und
    ///   der Tropfen-Etat auf Land unverändert bleibt. Leeres Array =
    ///   gleichverteilte Starts wie bisher (bit-identisch).
    /// - `underIce`: Vergletscherungs-Maske (Terrain.underIce, Issue #35). Auf
    ///   diesen Zellen rührt der Tropfen das BETT nicht an — weder erodierend
    ///   (unter einem Gletscher gibt es keinen fluvialen Abtrag) noch ablagernd
    ///   (Schutt auf einer Eisoberfläche ist kein Sediment im Bett). Der nicht
    ///   abgelegte Anteil bleibt wie bei der Kanalmaske in Suspension und
    ///   erreicht das Bett erst hinter der Zunge — physisch genau der
    ///   Sander/Schwemmfächer am Gletschertor. Leeres Array = Verhalten wie ohne
    ///   Maske (bit-identisch).
    /// - `erodibility`: relative Gesteins-Erodierbarkeit (Terrain.lithErodeK,
    ///   Issue #12; 1 = Referenzgestein). Skaliert den FELS-Anteil jedes Abtrags
    ///   (s. `dig`) — das lockere Sediment darüber erodiert unverändert. Leeres
    ///   Array = uniformes Gestein wie bisher (bit-identisch).
    /// - `firstDrop`: laufende Nummer des ERSTEN Tropfens dieser Charge im
    ///   fortlaufenden Tropfen-Strom des Terrains (`Terrain.dropsEmitted`).
    ///   Dann zieht jeder Tropfen seinen Startpunkt aus einem EIGENEN, aus
    ///   seiner Nummer abgeleiteten Strom (s. `dropRNG`) — Tropfen Nr. j ist
    ///   damit derselbe Tropfen, egal ob er als Einzelner in einem Frame-Schritt
    ///   fällt oder als einer von 360 in einem +10.000-Jahre-Sprung (Issue #2,
    ///   Wächter `DtInvariance.testDropletStreamIsChunkingInvariant`).
    ///
    ///   `nil` = EINMAL-CHARGE: alle Tropfen kommen aus einem Strom ab `seed`,
    ///   wie vor Issue #2. Das ist der richtige Modus für Chargen, die gar keine
    ///   Zeit abbilden und deren Größe fest ist — den Stream-Map-Spin-up der
    ///   Generierung (`Terrain.spinUpStreamMap`). Er behält damit exakt seine
    ///   kalibrierte Realisierung: die erzeugte Welt hängt an dieser Charge, und
    ///   sie hat kein dt-Problem, das zu beheben wäre.
    public static func erode(h: inout [Double], rock: inout [Double], sed: inout [Double],
                              n: Int, count: Int, seed: UInt32, floor: Double,
                              p: HydraulicParams,
                              seaLevel: Double? = nil,
                              firstDrop: UInt64? = nil,
                              hf: [Double] = [], receiver: [Int32] = [],
                             stream: [Double] = [], channel: [Bool] = [],
                             underIce: [Bool] = [],
                             rainWeight: [Double] = [],
                             erodibility: [Double] = [],
                             track: inout [Double]) {
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

        // Kanalmaske aktiv? (leeres Array → alle Kanal-Zweige fallen weg und die
        // Arithmetik ist bit-identisch mit dem Zustand vor der Reconciliation)
        let chanOn = channel.count == h.count

        // Lithologie-Feld aktiv? (leeres/kaputtes Array → Faktor fällt weg und die
        // Arithmetik ist bit-identisch zum Zustand vor Issue #12)
        let lithOn = erodibility.count == h.count

        // Eismaske aktiv? (leeres Array → beide Gletscher-Zweige fallen weg und
        // die Arithmetik ist bit-identisch zum Zustand vor Issue #35)
        let iceOn = underIce.count == h.count

        // Abtrag; gibt den tatsächlich abgetragenen Betrag zurück (am Tiefseeboden
        // gedeckelt), damit die Sedimentbilanz stimmt.
        //
        // Lithologie (Issue #12): der Härtefaktor wirkt NUR auf den Fels-Anteil.
        // Das lockere Sediment darüber wird wie bisher abgeräumt (Regolith weiß
        // nicht, welches Gestein darunter liegt); was darüber hinaus in den Fels
        // greift, wird mit dessen Erodierbarkeit skaliert — auf einer harten Bank
        // bleibt nach dem Abräumen der Auflage genau der Widerstand stehen, der
        // die Kante hält.
        //
        // BIT-IDENTITÄT: der Faktor wird VOR dem restlichen (unveränderten) Ablauf
        // auf `amount` gerechnet und nur angefasst, wenn er ≠ 1 ist. Sonst liefe
        // auch bei uniformem Gestein eine andere Gleitkomma-Reihenfolge
        // (`take + (d − take)` ist NICHT bit-genau `d`), und der 30k-Jahre-Lauf
        // des Braiding-Wächters driftet messbar weg (gemessen: Bank-Fläche
        // 185/104 statt 160/81) — chaotisches System, 1-ulp-Unterschiede wachsen.
        @inline(__always) func dig(_ k: Int, _ amount: Double) -> Double {
            // Unter Eis kein fluvialer Abtrag (Issue #35): das Bett gehört dem
            // Gletscher. Vor jeder anderen Rechnung, damit auch die
            // Lithologie-Arithmetik nicht anläuft.
            if iceOn && underIce[k] { return 0 }
            var d = amount
            let f = lithOn ? erodibility[k] : 1.0
            if f != 1.0 {
                let s = sed[k]
                if d > s { d = s + (d - s) * f }
            }
            let room = h[k] - floor
            if room <= 0 { return 0 } // schon am Tiefseeboden
            if d > room { d = room }  // nicht unter den Boden graben
            let take = min(d, sed[k])
            sed[k] -= take
            rock[k] -= (d - take)
            h[k] -= d
            return d
        }

        /// Ablagerung; gibt den NICHT abgelegten Rest zurück (auf Kanalzellen
        /// gedämpft: ein Bett, das von Tropfen-Sediment zugeschüttet wird, ist
        /// derselbe Reconciliation-Bug wie eins, das weggefressen wird). Der Rest
        /// bleibt beim Tropfen in Suspension (Massenbilanz + physisch: der Kanal
        /// TRANSPORTIERT das Sediment weiter). Ohne Maske exakt 0 → alte Arithmetik.
        @inline(__always) func deposit(_ k: Int, _ amount: Double) -> Double {
            // Gletscherzelle: gar nichts ablegen, alles bleibt in Suspension
            // (Issue #35) — der Tropfen trägt seine Fracht über das Eis hinweg
            // und lädt sie hinter der Zunge ab (Sander am Gletschertor).
            if iceOn && underIce[k] { return amount }
            if chanOn && channel[k] {
                let put = amount * p.channelDepositDamp
                sed[k] += put; h[k] += put
                return amount - put
            }
            sed[k] += amount; h[k] += amount
            return 0
        }

        // Gewichts-Maximum einmal je Charge (die Ablehnungs-Stichprobe normiert
        // darauf); leeres/kaputtes Feld → gleichverteilte Starts wie bisher.
        let rainOn = rainWeight.count == h.count
        let rainMax = rainOn ? (rainWeight.max() ?? 0) : 0

        // Zufallsstrom: EINER JE TROPFEN aus dessen laufender Nummer, wenn diese
        // Charge Teil des fortlaufenden Stroms ist (Issue #2) — sonst einer je
        // Charge wie bisher (s. `firstDrop`). Der gesamte Zufall eines Tropfens
        // steckt in seinem Startpunkt (die Bahn danach ist deterministisch),
        // also legt die Nummer den Tropfen vollständig fest: Tropfen Nr. j ist
        // derselbe, ob er allein in einem 0.2-Jahr-Frame fällt oder als einer
        // von 360 in einem Sprung. Vorher hing der Charge-Seed an der
        // SCHRITT-Nummer: leere Frame-Schritte (Tropfenzahl 0) schoben ihn
        // trotzdem weiter, und ein großer Schritt zog alle Tropfen aus einem
        // einzigen Strom — der Droplet-Pass blieb damit schrittweiten-abhängig.
        var batch = Mulberry32(seed: seed)
        for i in 0..<count {
            var px = 0.0, py = 0.0
            if let firstDrop {
                var rnd = dropRNG(seed: seed, index: firstDrop &+ UInt64(i))
                (px, py) = spawnPosition(&rnd, n: n,
                                         weight: rainOn ? rainWeight : [], weightMax: rainMax)
            } else {
                (px, py) = spawnPosition(&batch, n: n,
                                         weight: rainOn ? rainWeight : [], weightMax: rainMax)
            }
            if let seaLevel {
                let start = Int(py) * n + Int(px)
                if h[start] <= seaLevel { continue }
            }
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
                    sediment -= dep - deposit(k, dep)
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
                    // Rest aus der Kanal-Dämpfung bleibt in Suspension (ohne Maske: 0).
                    sediment += deposit(k, dep * (1 - fx) * (1 - fy))
                             +  deposit(k + 1, dep * fx * (1 - fy))
                             +  deposit(k + n, dep * (1 - fx) * fy)
                             +  deposit(k + n + 1, dep * fx * fy)
                } else {
                    // Unter Kapazität → erodieren, aber nicht mehr als das Gefälle
                    // (kein Löchergraben), über den Pinsel verteilt.
                    let ero = min((capacity - sediment) * p.erodeRate, -deltaH)
                    if ero > 0 {
                        for i in bx.indices {
                            let cx = nodeX + bx[i], cy = nodeY + byv[i]
                            if cx < 0 || cx >= n || cy < 0 || cy >= n { continue }
                            let ck = cy * n + cx
                            sediment += dig(ck, ero * bw[i])
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
