import XCTest
@testable import SimCore

/// **dt-Invarianz-Wächter (Issue #2).**
///
/// Gleiche Simulationszeit muss — unabhängig von der Schrittweite — dasselbe
/// Ergebnis liefern: der Echtzeit-Zeitraffer (viele winzige Schritte je Frame)
/// und der `+10.000 Jahre`-Sprung sind derselbe Vorgang. Vier Ursachen liefen
/// dem zuwider; alle sind behoben, jede hat unten ihren eigenen, engen Wächter
/// (Messreihen: `docs/dt-invariance-measurements.md`):
///
/// 1. `wavePass` war eine ZÄHLSCHLEIFE (`max(1, min(24, dt/100))`) statt einer
///    Rate → `testWaveErosionIsFramerateIndependent`.
/// 2. Lineare statt exponentieller Relaxation in `fillShallowPonds`,
///    `fillLakes`, `fillOxbows`, `updateVegetation` →
///    `testRelaxationsTelescopeAcrossSubsteps`.
/// 3. Tropfenzahl `max(1, dt·Rate)` rundete jeden Frame-Schritt auf →
///    `testDropletCountIsARate`; und der Tropfen-STROM hing an einem
///    Schritt-Zähler statt an der Zahl emittierter Tropfen →
///    `testDropletStreamIsChunkingInvariant`.
/// 4. Depositions-Deckel in `meanderStamp` (Carve, Prallhang/Gleithang) galten
///    JE SCHRITT statt je Zeit → `testStepCapsAreRates`. Der Deckel in
///    `braidPass` bleibt dagegen in seiner kalibrierten Form (s. unten).
///
/// **Was bewusst NICHT behoben ist** (und deshalb die weiten Schranken des
/// Produktionspfad-Wächters erklärt) — beides in
/// `docs/dt-invariance-measurements.md` §5 einzeln ausgemessen:
///
/// - **Operator-Splitting-Drift** (laut Issue-Zuschnitt ausgenommen): das
///   Abflussfeld (`hf`, `receiver`, `streamMap`) wird nur EINMAL je Schritt
///   bestimmt, die Tropfen laufen aber `dt·Rate` mal dagegen. Der Seeanteil
///   liegt über dt ∈ {10, 240, 2000} ohne Tropfen auf 1.6 % zusammen, bei
///   0.2 Tropfen/Jahr auf 2.3 %, bei den 2.0 der Produktion auf 29 %.
/// - **See-Kern-Gate** der Pfützen-Verlandung (`puddleLakeCoreCells`): eine
///   binäre Klassifikation je Schritt (s. `testDrainageIsFramerateIndependent…`).
/// - Die **beiden Deckel in `braidPass`** bleiben in ihrer kalibrierten Form:
///   der Scour-Deckel bei festen 0.5 je Schritt (als Rate gräbt er den Boden
///   abflussloser Becken tiefer — Playa-Fläche >100 → 35 Zellen) und die
///   Überfüll-Zugabe bei 0.005 je Schritt. Für Letztere sind FÜNF
///   dt-invariante Ersatzformen gemessen; jede kippt einen anderen
///   kalibrierten #11/#12-Wächter, und keine der nötigen Höhen ist physikalisch
///   begründet (Tabelle in docs §2.4). Die Becken reagieren so empfindlich,
///   weil ihre Hypsometrie flach ist: ein Millimeter Bilanz-Pegel bewegt
///   hunderte Zellen Wasserfläche.
final class DtInvariance: XCTestCase {

    // MARK: - Kennzahlen

    /// Bewusst mehrere unabhängige Achsen, weil die vier dt-Fehler an
    /// verschiedenen Pässen hingen: Wasserhaushalt (Seen), Küstenerosion
    /// (`wavePass`) und die fluviale Makro-Form (Relief, Landmasse).
    struct Metrics {
        var lakeFraction = 0.0   // Anteil Landzellen mit hf−h > 0.01
        var coastCells = 0.0     // Zellen in der Wellenzone (|h − sea| ≤ waveBand)
        var landRelief = 0.0     // robustes Relief (p95 − Median der Landhöhen)
        var meanLand = 0.0       // mittlere Landhöhe (Massen-Proxy)

        static func += (l: inout Metrics, r: Metrics) {
            l.lakeFraction += r.lakeFraction; l.coastCells += r.coastCells
            l.landRelief += r.landRelief; l.meanLand += r.meanLand
        }
        static func / (l: Metrics, d: Double) -> Metrics {
            Metrics(lakeFraction: l.lakeFraction / d, coastCells: l.coastCells / d,
                    landRelief: l.landRelief / d, meanLand: l.meanLand / d)
        }
        var line: String {
            String(format: "lake %.4f | coast %6.0f | relief %.4f | meanLand %.4f",
                   lakeFraction, coastCells, landRelief, meanLand)
        }
    }

    /// Zellen in der Wellen-Angriffszone — genau das Gate von `wavePass`. Die
    /// Kennzahl misst also direkt, wie weit die Küste zurückgearbeitet wurde.
    static func coastCells(_ t: Terrain) -> Int {
        var c = 0
        for k in 0..<t.cfg.count where abs(t.h[k] - t.cfg.sea) <= t.cfg.waveBand { c += 1 }
        return c
    }

    /// Momentaufnahme auf FRISCHEM Abflussfeld. `hf` wird in `step()` einmal am
    /// Anfang bestimmt, danach verschieben die Erosionspässe `h` — am
    /// Schrittende ist `hf − h` deshalb umso stärker verzerrt, je mehr ein
    /// Schritt bewegt (gemessen bei dt = 2000: Seeanteil 0.2111 gegen 0.1584 auf
    /// frischem Feld). Ohne diesen Auffrischer verglichen die Arme
    /// unterschiedlich alte Wasserstände statt Terrain. `computeFlow` ist genau
    /// das, was der nächste Schritt als Erstes selbst täte.
    static func metrics(_ t: Terrain) -> Metrics {
        t.computeFlow()
        var sum = 0.0, land = 0
        for k in 0..<t.cfg.count where t.h[k] > t.cfg.sea { sum += t.h[k]; land += 1 }
        return Metrics(lakeFraction: t.lakeStats(depth: 0.01).fraction,
                       coastCells: Double(coastCells(t)),
                       landRelief: t.landReliefRobust(),
                       meanLand: land == 0 ? 0 : sum / Double(land))
    }

    /// Ein Lauf über `years` Jahre in Schritten von `dt`, ZEITGEMITTELT über
    /// Abtastungen ab `from` im Abstand `every`.
    ///
    /// Warum gemittelt: der momentane Seeanteil ist keine stabile Kennzahl —
    /// Becken füllen und entleeren sich episodisch. Gemessen (n=192, Seed 1337,
    /// Abtastung je 1000 J.) schwankt er INNERHALB eines Laufs bei festem dt
    /// zwischen 0.071 und 0.150, die größte See-Komponente zwischen 926 und
    /// 3572 Zellen von einer Abtastung zur nächsten. Ein Einzelwert am Laufende
    /// verglicht also Phasen, nicht Regime. Die Abtastmarken sind Zeitpunkte,
    /// keine Schrittzahlen — jeder Arm bekommt gleich viele Abtastungen, egal
    /// wie fein er getaktet ist.
    static func run(seed: UInt32, n: Int = 192, years: Double = 20_000,
                    dt: Double, from: Double = 10_000, every: Double = 2_000,
                    configure: (inout SimConfig) -> Void = { _ in }) -> Metrics {
        var c = SimConfig(); c.n = n; configure(&c)
        let t = Terrain(config: c, seed: seed)
        var acc = Metrics(), samples = 0.0, next = from
        while t.years < years - 1e-9 {
            t.step(dtYears: min(dt, years - t.years))
            if t.years >= next - 1e-9 {
                next += every
                acc += metrics(t); samples += 1
            }
        }
        return acc / max(1, samples)
    }

    /// Relative Abweichung zweier Werte, bezogen auf den größeren Betrag.
    static func dev(_ a: Double, _ b: Double) -> Double {
        let m = max(abs(a), abs(b))
        return m < 1e-12 ? 0 : abs(a - b) / m
    }

    // MARK: - Wächter je Ursache

    /// **Ursache 1**: Küstenerosion als Rate. Auf einem Testfall, in dem NUR
    /// `wavePass` arbeitet, muss dieselbe Zeit dieselbe Abtragung liefern —
    /// hier ohne die Splitting-Drift der übrigen Pässe, also mit enger
    /// Schranke. Vor dem Fix erodierte dt=10 die Küste um ein Vielfaches
    /// (volle 100-Jahr-Relaxation je 10-Jahr-Schritt).
    func testWaveErosionIsFramerateIndependent() {
        func waveOnly(dt: Double) -> (band: Int, mass: Double) {
            var c = SimConfig(); c.n = 96
            c.meanderEnabled = false; c.braidingEnabled = false
            c.outletIncision = false; c.puddleFillYears = 0; c.basinFill = false
            c.hydraulicPerYear = 0    // keine Tropfen
            c.hillDiffusion = 0       // keine Hangdiffusion
            c.upliftPer100y = 0; c.upliftDecayStartPer100y = 0; c.upliftDecayFloorPer100y = 0
            c.reliefServoPer100y = 0
            let t = Terrain(config: c, seed: 1337)
            while t.years < 4000 - 1e-9 { t.step(dtYears: min(dt, 4000 - t.years)) }
            var mass = 0.0
            for k in 0..<t.cfg.count where t.h[k] > t.cfg.sea { mass += t.h[k] - t.cfg.sea }
            return (DtInvariance.coastCells(t), mass)
        }
        let a = waveOnly(dt: 10), b = waveOnly(dt: 250), c = waveOnly(dt: 2000)
        print("Wave-only: \(a) | \(b) | \(c)")
        for (x, y) in [(a, b), (a, c), (b, c)] {
            XCTAssertLessThan(DtInvariance.dev(Double(x.band), Double(y.band)), 0.05,
                              "Küstenzone driftet mit der Schrittweite: \(x.band) vs \(y.band)")
            XCTAssertLessThan(DtInvariance.dev(x.mass, y.mass), 0.02,
                              "Landmasse driftet mit der Schrittweite: \(x.mass) vs \(y.mass)")
        }
    }

    /// **Ursache 2**: exponentielle Relaxation teleskopiert. `1 − e^(−dt/τ)`
    /// über N Teilschritte ist exakt `1 − e^(−N·dt/τ)`; die alte lineare Form
    /// `min(cap, dt/τ)` tut das nicht — sie sättigt am Deckel. Der Test rechnet
    /// die Formen direkt gegeneinander, damit die Zusicherung nicht an einer
    /// Terrain-Kalibrierung hängt.
    func testRelaxationsTelescopeAcrossSubsteps() {
        for tau in [250.0, 800.0, 3000.0, 5500.0] {          // veg / Pfützen / Seen / Altarme
            for total in [240.0, 2000.0, 10_000.0] {
                for parts in [1, 3, 24, 1000] {
                    let dt = total / Double(parts)
                    var rest = 1.0
                    for _ in 0..<parts { rest *= 1 - (1 - exp(-dt / tau)) }
                    XCTAssertEqual(1 - rest, 1 - exp(-total / tau), accuracy: 1e-9,
                                   "τ=\(tau), \(total) J. in \(parts) Teilschritten")
                }
            }
        }
    }

    /// **Ursache 3**: die Tropfenzahl ist eine RATE — über dieselbe Zeit fällt
    /// dieselbe Zahl Tropfen, egal wie fein getaktet wird. Kleine Schritte
    /// (dt < 1/Rate) sind der Fall, den `max(1, …)` aufrundete: bei dt = 0.2 J.
    /// verlangte die Rate 0.09 Tropfen und es fielen 1 (11× zu viel).
    func testDropletCountIsARate() {
        var c = SimConfig(); c.n = 64
        let expected = 1000.0 * c.hydraulicPerYear * Double(c.n * c.n) / (640.0 * 640.0)
        for dt in [0.2, 1.0, 50.0, 1000.0] {
            let t = Terrain(config: c, seed: 1337)
            var drops = 0, elapsed = 0.0
            while elapsed < 1000 - 1e-9 {
                let step = min(dt, 1000 - elapsed)
                drops += t.dropletCount(dtYears: step)
                elapsed += step
            }
            XCTAssertLessThanOrEqual(abs(Double(drops) - expected), 1.0,
                                     "dt \(dt): \(drops) Tropfen statt \(expected)")
        }
    }

    /// **Ursache 3, zweiter Teil**: nicht nur die ANZAHL der Tropfen ist eine
    /// Rate, auch der Tropfen-STROM selbst ist schrittweiten-unabhängig.
    ///
    /// Der gesamte Zufall eines Tropfens steckt in seinem Startpunkt (die Bahn
    /// danach ist deterministisch), und der Startpunkt kommt aus einem Strom,
    /// der an der laufenden NUMMER des Tropfens hängt (`Hydraulic.dropRNG`,
    /// `Terrain.dropsEmitted`). Also muss dieselbe Tropfenfolge, in beliebige
    /// Chargen zerlegt, BIT-IDENTISCHES Terrain liefern. Vorher hing der Seed
    /// an der Zahl der SCHRITTE: leere Frame-Schritte schoben ihn weiter, und
    /// ein großer Schritt zog alle Tropfen aus einem einzigen Strom — die
    /// Tropfenzahl stimmte dann zwar, die Tropfen selbst waren andere.
    func testDropletStreamIsChunkingInvariant() {
        var c = SimConfig(); c.n = 96
        let ref = Terrain(config: c, seed: 1337)   // gemeinsames Ausgangsgelände
        let p = c.hydraulic

        /// Lässt `total` Tropfen in Chargen der Größe `chunk` auf eine Kopie des
        /// Ausgangsgeländes los. Die Felder, die der Pass nur LIEST (hf,
        /// receiver, stream), bleiben dabei bewusst eingefroren — geprüft wird
        /// der Tropfen-Strom, nicht die Rückkopplung übers Abflussfeld.
        func run(total: Int, chunk: Int) -> ([Double], [Double]) {
            var h = ref.h, rock = ref.rock, sed = ref.sed
            var track = [Double](repeating: 0, count: c.count)
            var done = 0
            while done < total {
                let k = min(chunk, total - done)
                Hydraulic.erode(h: &h, rock: &rock, sed: &sed, n: c.n, count: k,
                                seed: 1337, floor: c.floor, p: p,
                                seaLevel: nil, firstDrop: UInt64(done),
                                hf: ref.hf, receiver: ref.receiver,
                                stream: ref.streamMap,
                                rainWeight: ref.rainWeight,
                                erodibility: ref.lithErodeK,
                                track: &track)
                done += k
            }
            return (h, track)
        }

        let single = run(total: 120, chunk: 120)      // ein +10.000-Jahre-Sprung
        for chunk in [1, 7, 40] {                     // Frame-Schritte verschiedener Größe
            let split = run(total: 120, chunk: chunk)
            XCTAssertEqual(split.0, single.0, "Höhenfeld hängt an der Chargengröße \(chunk)")
            XCTAssertEqual(split.1, single.1, "Besuchszählung hängt an der Chargengröße \(chunk)")
        }
        // Gegenprobe, dass der Test überhaupt etwas sieht: ein verschobener
        // Strom (andere Startnummer) MUSS ein anderes Feld liefern.
        var h2 = ref.h, rock2 = ref.rock, sed2 = ref.sed
        var track2 = [Double](repeating: 0, count: c.count)
        Hydraulic.erode(h: &h2, rock: &rock2, sed: &sed2, n: c.n, count: 120,
                        seed: 1337, floor: c.floor, p: p,
                        seaLevel: nil, firstDrop: 1,
                        hf: ref.hf, receiver: ref.receiver, stream: ref.streamMap,
                        rainWeight: ref.rainWeight, erodibility: ref.lithErodeK,
                        track: &track2)
        XCTAssertNotEqual(h2, single.0, "verschobener Tropfen-Strom liefert dasselbe Feld?")
    }

    /// **Ursache 4**: der Schritt-Deckel (`stepCapFraction`) klebt bei großen
    /// Schritten nicht mehr bei der Hälfte.
    func testStepCapsAreRates() {
        let t = Terrain(config: { var c = SimConfig(); c.n = 32; return c }(), seed: 1)
        // Bis 500 J. exakt der alte feste Deckel — die bestehende Kalibrierung
        // (alle Wächter takten mit dt ≤ 500) bleibt unangetastet…
        for dt in [1e-6, 1.0, 20.0, 250.0, 500.0] {
            XCTAssertEqual(t.stepCapFractionForTests(dt), 0.5, accuracy: 1e-12, "dt \(dt)")
        }
        // …darüber wächst er monoton weiter, statt zu sättigen.
        XCTAssertEqual(t.stepCapFractionForTests(1000), 0.75, accuracy: 1e-9)
        XCTAssertEqual(t.stepCapFractionForTests(2000), 0.9375, accuracy: 1e-9)
        // Ein großer Schritt gibt (fast) so viel frei wie dieselbe Zeit in
        // 500-Jahr-Teilschritten — das ist der eigentliche Zweck.
        for parts in [2, 4, 8] {
            let total = 500.0 * Double(parts)
            var rest = 1.0
            for _ in 0..<parts { rest *= 1 - t.stepCapFractionForTests(500) }
            XCTAssertEqual(1 - rest, t.stepCapFractionForTests(total), accuracy: 1e-9,
                           "\(total) J. gegen \(parts)×500 J.")
        }
        // Der Deckel bleibt ein Deckel: nie mehr als die volle Differenz.
        XCTAssertLessThanOrEqual(t.stepCapFractionForTests(1e6), 1.0)
        XCTAssertLessThan(t.stepCapFractionForTests(1000), 1.0)
    }

    // MARK: - Wächter auf dem Gesamtpfad

    /// Der Wasserhaushalt selbst (Priority-Flood, Auslass-Inzision,
    /// Pfützen-Verlandung) ist schrittweiten-unabhängig, sobald die beiden
    /// bekannten, NICHT zu #2 gehörenden Verstärker draußen sind:
    ///
    /// - der **Tropfen-Pass** (Operator-Splitting-Drift: `dt·Rate` Tropfen je
    ///   Abfluss-Update — s. Klassen-Doku), und
    /// - das **See-Kern-Gate** der Pfützen-Verlandung
    ///   (`puddleLakeCoreCells`): eine Wasser-Komponente mit tiefem Kern gilt
    ///   als See und verlandet gar nicht mehr. Das ist eine BINÄRE
    ///   Klassifikation, die je Schritt neu fällt — je feiner getaktet, desto
    ///   öfter erwischt sie ein Grenzbecken in einem füllbaren Zustand.
    ///   Gemessen (ohne Tropfen, zeitgemittelt, Seed 1337):
    ///   mit Gate 0.0211 / 0.0212 / 0.0503, ohne Gate 0.0044 / 0.0045 / 0.0046.
    ///
    /// Beide sind bewusst nicht angefasst (Issue-Zuschnitt bzw. Kalibrierung
    /// des Gates, s. `puddleLakeCoreCells`) und in
    /// `docs/dt-invariance-measurements.md` §5 vermerkt. Was dieser Wächter
    /// festhält: die RELAXATIONEN selbst (Ursache 2) sind es im laufenden
    /// System, nicht nur formal.
    func testDrainageIsFramerateIndependentWithoutDroplets() {
        func arms(_ tweak: @escaping (inout SimConfig) -> Void) -> [(dt: Double, m: Metrics)] {
            [10.0, 240.0, 2000.0].map { dt in
                (dt, DtInvariance.run(seed: 1337, dt: dt) { c in
                    c.hydraulicPerYear = 0          // kein Tropfen-Splitting
                    c.meanderEnabled = false; c.braidingEnabled = false
                    c.hillDiffusion = 0; c.waveRelax = 0
                    c.upliftPer100y = 0; c.upliftDecayStartPer100y = 0
                    c.upliftDecayFloorPer100y = 0; c.reliefServoPer100y = 0
                    tweak(&c)
                })
            }
        }
        // (a) reine Entwässerung, ohne Pfützen-Verlandung
        // (b) MIT Pfützen-Verlandung, aber ohne deren See-Kern-Gate
        for (tag, run) in [("ohne Pfützen", arms { $0.puddleFillYears = 0 }),
                           ("ohne Kern-Gate", arms { $0.puddleLakeCoreCells = 1 << 28 })] {
            for a in run { print(String(format: "\(tag) dt %6.0f | ", a.dt) + a.m.line) }
            for a in run {
                for b in run where b.dt > a.dt {
                    XCTAssertLessThan(DtInvariance.dev(a.m.lakeFraction, b.m.lakeFraction), 0.10,
                                      "\(tag), dt \(Int(a.dt)) vs \(Int(b.dt)): Seeanteil "
                                      + "\(a.m.lakeFraction) vs \(b.m.lakeFraction)")
                }
            }
        }
    }

    /// **Abnahme-Wächter**: derselbe Seed, dieselbe Gesamtzeit, drei
    /// Schrittweiten auf den vollen Produktions-Defaults.
    ///
    /// Schranken aus der Messreihe (`docs/dt-invariance-measurements.md`,
    /// zeitgemittelt, n=192, Seed 1337, 20k Jahre):
    ///
    /// | Kennzahl  | vorher (main)            | nachher                  | Spanne vorher → nachher | Schranke |
    /// |-----------|--------------------------|--------------------------|------|------|
    /// | Küstenzone| 5529 / 4003 / 4042       | 4250 / 4084 / 4110       | 38 % → **3.9 %** | 10 % |
    /// | Relief    | 0.1690 / 0.1479 / 0.1650 | 0.1664 / 0.1508 / 0.1672 | 12.5 % → 9.8 % | 20 % |
    /// | meanLand  | 0.3547 / 0.3575 / 0.3524 | 0.3506 / 0.3567 / 0.3512 | 1.4 % → 1.7 % | 5 % |
    /// | Seeanteil | 0.0347 / 0.0996 / 0.1401 | 0.0367 / 0.0925 / 0.1312 | 75 % → 72 % | 80 % |
    ///
    /// Relief und Seeanteil bleiben also auf dem Stand von `main` — beide hängen
    /// am Tropfen-Splitting (s. Klassen-Doku), nicht an den vier Ursachen. Ihre
    /// Schranken sind entsprechend weit gesetzt: sie fangen eine
    /// Größenordnungs-Änderung ab (die Küstenzone lag vor dem Fix bei 38 %),
    /// nicht die Restdrift. Über die Zwischenstände von #2 lag die
    /// Relief-Spanne bei 9.8 … 15.0 %, der Seeanteil bei 72 … 76 %.
    ///
    /// Die weite See-Schranke ist Absicht und keine Kalibrierung nach dem
    /// Ergebnis: der Seeanteil hängt auf diesem Seed an EINEM Grenzbecken, das
    /// je nach Tropfen-Splitting und See-Kern-Gate innerhalb der 20k Jahre
    /// entwässert oder nicht — beides bewusst nicht Teil von #2, beide Anteile
    /// sind in `docs/dt-invariance-measurements.md` §5 einzeln ausgemessen. Die
    /// ENGEN See-Wächter sind `testDrainageIsFramerateIndependentWithoutDroplets`
    /// darüber; hier fängt die Schranke nur die Größenordnung ab, in der die
    /// Ursachen 1–4 lagen (vor dem Fix erreichte der momentane Seeanteil das
    /// 2.6–5.0-fache zwischen dt=10 und dt=2000).
    func testSameTimeSameResultAcrossStepSizes() {
        let arms = [10.0, 240.0, 2000.0].map { (dt: $0, m: DtInvariance.run(seed: 1337, dt: $0)) }
        for a in arms { print(String(format: "dt %6.0f | ", a.dt) + a.m.line) }
        for a in arms {
            for b in arms where b.dt > a.dt {
                let tag = "dt \(Int(a.dt)) vs \(Int(b.dt))"
                // Küstenzone: das direkte Maß der wavePass-Rate (vorher 38 %).
                XCTAssertLessThan(DtInvariance.dev(a.m.coastCells, b.m.coastCells), 0.10,
                                  "\(tag): Küstenzone \(a.m.coastCells) vs \(b.m.coastCells)")
                // Makro-Form: Relief und Landmasse dürfen nicht auseinanderlaufen.
                XCTAssertLessThan(DtInvariance.dev(a.m.landRelief, b.m.landRelief), 0.20,
                                  "\(tag): Relief \(a.m.landRelief) vs \(b.m.landRelief)")
                XCTAssertLessThan(DtInvariance.dev(a.m.meanLand, b.m.meanLand), 0.05,
                                  "\(tag): meanLand \(a.m.meanLand) vs \(b.m.meanLand)")
                // Seeanteil: s. Tabelle oben — grobe Größenordnungs-Schranke.
                XCTAssertLessThan(DtInvariance.dev(a.m.lakeFraction, b.m.lakeFraction), 0.80,
                                  "\(tag): Seeanteil \(a.m.lakeFraction) vs \(b.m.lakeFraction)")
            }
        }
    }


    /// Hängt die Rest-Abhängigkeit der Pfützen-Verlandung an der
    /// Relaxationsform oder an ihren SCHWELLEN (Tiefen-Gate, See-Kern-Gate)?
    /// Antwort (s. docs §5): am See-Kern-Gate.
    func testPuddleGateProbeDiagnostic() throws {
        try skipUnlessMeasuring()
        let variants: [(String, (inout SimConfig) -> Void)] = [
            ("Pfütze aus     ", { $0.puddleFillYears = 0 }),
            ("Pfütze an      ", { _ in }),
            ("ohne Gates     ", { $0.puddleFillDepth = 10; $0.puddleLakeCoreCells = 1 << 28 }),
            ("ohne Tiefen-Gate", { $0.puddleFillDepth = 10 }),
            ("ohne Kern-Gate ", { $0.puddleLakeCoreCells = 1 << 28 }),
        ]
        for (name, apply) in variants {
            var line = name + "|"
            for dt in [10.0, 240.0, 2000.0] {
                let m = DtInvariance.run(seed: 1337, dt: dt) { c in
                    c.hydraulicPerYear = 0
                    c.meanderEnabled = false; c.braidingEnabled = false
                    c.hillDiffusion = 0; c.waveRelax = 0
                    c.upliftPer100y = 0; c.upliftDecayStartPer100y = 0
                    c.upliftDecayFloorPer100y = 0; c.reliefServoPer100y = 0
                    apply(&c)
                }
                line += String(format: "  dt %5.0f: lake %.4f", dt, m.lakeFraction)
            }
            print(line)
        }
    }

    // MARK: - Messreihen (nur mit RS_MEASURE=1, s. docs/dt-invariance-measurements.md)

    /// Die Tabelle für `docs/`: momentan gemessen (Laufende) gegen zeitgemittelt.
    func testDtSpreadDiagnostic() throws {
        try skipUnlessMeasuring()
        for seed in [UInt32(1337), 4242] {
            for dt in [10.0, 240.0, 2000.0] {
                var c = SimConfig(); c.n = 192
                let t = Terrain(config: c, seed: seed)
                while t.years < 20_000 - 1e-9 { t.step(dtYears: min(dt, 20_000 - t.years)) }
                let stale = t.lakeStats(depth: 0.01).fraction
                let now = DtInvariance.metrics(t)
                let avg = DtInvariance.run(seed: seed, dt: dt)
                print(String(format: "seed %4d dt %6.0f | Ende: ", Int(seed), dt) + now.line
                      + String(format: " (hf veraltet: %.4f)", stale)
                      + " | Mittel: " + avg.line)
            }
        }
    }

    /// Zeitreihe des Ponding-Aufbaus — der Beleg, dass der momentane Seeanteil
    /// innerhalb EINES Laufs um mehr als den Faktor 2 schwankt.
    func testLakeTrajectoryDiagnostic() throws {
        try skipUnlessMeasuring()
        for dt in [250.0, 2000.0] {
            var c = SimConfig(); c.n = 192
            let t = Terrain(config: c, seed: 1337)
            print(String(format: "== dt %.0f ==", dt))
            var next = 1000.0
            while t.years < 20_000 - 1e-9 {
                t.step(dtYears: min(dt, 20_000 - t.years))
                guard t.years >= next - 1e-9 else { continue }
                next += 1000
                t.computeFlow()
                let s = t.lakeStats(depth: 0.01)
                print(String(format: "  %6.0f J. | lake %.4f | größter See %5d Zellen",
                             t.years, s.fraction, s.largest))
            }
        }
    }

    /// Der Rest-Unterschied skaliert mit den TROPFEN JE ABFLUSS-UPDATE — die
    /// Signatur der Operator-Splitting-Drift (bewusst nicht Teil von #2).
    func testSplittingScalesWithDropRateDiagnostic() throws {
        try skipUnlessMeasuring()
        for rate in [0.0, 0.2, 2.0] {
            for dt in [10.0, 240.0, 2000.0] {
                let m = DtInvariance.run(seed: 1337, dt: dt) { c in
                    c.hydraulicPerYear = rate
                    c.meanderEnabled = false; c.braidingEnabled = false
                    c.puddleFillYears = 0; c.waveRelax = 0; c.hillDiffusion = 0
                    c.upliftPer100y = 0; c.upliftDecayStartPer100y = 0
                    c.upliftDecayFloorPer100y = 0; c.reliefServoPer100y = 0
                }
                print(String(format: "Tropfen/Jahr %.1f dt %6.0f | lake %.4f",
                             rate, dt, m.lakeFraction))
            }
        }
    }

    /// Welcher Pass hält das Ponding in Schach? (Ablation, Seed 1337.)
    func testLakeAblationDiagnostic() throws {
        try skipUnlessMeasuring()
        let variants: [(String, (inout SimConfig) -> Void)] = [
            ("default         ", { _ in }),
            ("ohne Braiding   ", { $0.braidingEnabled = false }),
            ("ohne Mäander    ", { $0.meanderEnabled = false }),
            ("ohne Pfützenfüll", { $0.puddleFillYears = 0 }),
            ("ohne Droplets   ", { $0.hydraulicPerYear = 0 }),
        ]
        for (name, apply) in variants {
            var line = name + "|"
            for dt in [240.0, 2000.0] {
                var c = SimConfig(); c.n = 192; apply(&c)
                let t = Terrain(config: c, seed: 1337)
                while t.years < 20_000 - 1e-9 { t.step(dtYears: min(dt, 20_000 - t.years)) }
                t.computeFlow()
                let s = t.lakeStats(depth: 0.01)
                line += String(format: "  dt %4.0f: lake %.4f max %5d", dt, s.fraction, s.largest)
            }
            print(line)
        }
    }
}
