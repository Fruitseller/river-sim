import XCTest
@testable import SimCore

/// Wächter für `Terrain.relaxFraction` — den gemeinsamen Helfer hinter allen
/// exponentiellen Relaxationen des Kerns (Seespiegel, Salzkruste,
/// Becken-Bilanz, Pfützen, Altarme, Vegetation, Stream-Map, Regeneration).
///
/// Die Formel stand vorher elfmal wörtlich im Code; sie ist eine der drei
/// Bauformen der Framerate-Unabhängigkeit (AGENTS.md) und deshalb hier
/// unabhängig gepinnt: das ERGEBNIS gegen die geschlossene Form, das
/// VERHALTEN über Teleskopierung, Monotonie und Ränder.
///
/// Ergänzt `DtInvariance.testRelaxationsTelescopeAcrossSubsteps`, das die
/// Teleskop-Eigenschaft der Form selbst zeigt (dort bewusst mit ausgeschriebener
/// Formel, damit der Wächter nicht am Helfer hängt, den er absichern soll).
final class RelaxationTests: XCTestCase {

    /// Die Zeitkonstanten der Produktion (Config.swift) plus die im Code fest
    /// verdrahtete der Seen-Verfüllung.
    private let taus = [20.0, 250.0, 500.0, 800.0, 1200.0, 3000.0, 5500.0]
    /// Von Echtzeit-Frame (dt ≈ 0.2 J.) bis „+10.000 Jahre"-Sprung.
    private let dts = [0.2, 1.0, 9.0, 100.0, 240.0, 500.0, 2000.0, 10_000.0]

    /// BIT-genau die geschlossene Form: der Helfer ersetzt elf Fundstellen, die
    /// alle exakt `1 − e^(−dt/τ)` rechneten — jede andere (mathematisch
    /// gleichwertige) Umformung wäre eine Physik-Änderung, weil der Sim-Kern
    /// bit-identisch reproduzierbar sein muss.
    func testFractionIsTheClosedFormBitForBit() {
        for tau in taus {
            for dt in dts {
                let f = Terrain.relaxFraction(dt: dt, tau: tau)
                XCTAssertEqual(f.bitPattern, (1 - exp(-dt / tau)).bitPattern,
                               "τ=\(tau), dt=\(dt): \(f) statt \(1 - exp(-dt / tau))")
            }
        }
    }

    /// Der Kern der Bauform: der VERBLEIBENDE Rest ist multiplikativ. N
    /// Teilschritte und EIN Sprung derselben Gesamtdauer landen auf demselben
    /// Wert — genau das, was „Echtzeit-Zeitraffer == +10.000 Jahre" verlangt.
    func testFractionTelescopesAcrossSubsteps() {
        for tau in taus {
            for total in [240.0, 2000.0, 10_000.0] {
                for parts in [1, 3, 24, 1000] {
                    var rest = 1.0
                    for _ in 0..<parts {
                        rest *= 1 - Terrain.relaxFraction(dt: total / Double(parts), tau: tau)
                    }
                    XCTAssertEqual(1 - rest, Terrain.relaxFraction(dt: total, tau: tau),
                                   accuracy: 1e-9,
                                   "τ=\(tau), \(total) J. in \(parts) Teilschritten")
                }
            }
        }
    }

    /// Anteil eines Anteils: in (0, 1] für dt > 0, wachsend in `dt`, fallend in
    /// `tau`. Damit ist der Helfer als GEWICHT einer Mischung
    /// `x += (ziel − x)·f` immer gutartig: kein Überschießen, kein
    /// Vorzeichenwechsel. Die Monotonie ist STRIKT, solange der Wert nicht auf
    /// 1.0 gesättigt ist — ab ~37 τ liegt `e^(−dt/τ)` unter der halben
    /// `Double`-Auflösung bei 1.0, `1 − …` rundet dann auf exakt 1 (τ = 20 J.
    /// gegen einen 10.000-Jahr-Sprung sind 500 τ), und dort geht es nicht
    /// weiter nach oben.
    func testFractionStaysAWeightBetweenZeroAndOne() {
        for tau in taus {
            var prev = 0.0
            for dt in dts {
                let f = Terrain.relaxFraction(dt: dt, tau: tau)
                XCTAssertGreaterThan(f, 0, "τ=\(tau), dt=\(dt)")
                XCTAssertLessThanOrEqual(f, 1, "τ=\(tau), dt=\(dt)")
                if prev < 1 {
                    XCTAssertGreaterThan(f, prev, "nicht monoton in dt (τ=\(tau), dt=\(dt))")
                } else {
                    XCTAssertEqual(f, 1, "gesättigt und wieder gefallen (τ=\(tau), dt=\(dt))")
                }
                prev = f
            }
        }
        for dt in dts {
            var prev = Double.infinity
            for tau in taus {
                let f = Terrain.relaxFraction(dt: dt, tau: tau)
                if prev <= 1 {
                    XCTAssertLessThanOrEqual(f, prev, "nicht fallend in τ (dt=\(dt), τ=\(tau))")
                    if prev < 1 {
                        XCTAssertLessThan(f, prev, "nicht strikt fallend in τ (dt=\(dt), τ=\(tau))")
                    }
                }
                prev = f
            }
        }
    }

    /// Verankerung der Skala: nach einer Zeitkonstante ist genau der Anteil
    /// `1 − 1/e` zurückgelegt, nach dt = 0 exakt nichts (ein Schritt ohne Zeit
    /// darf nichts bewegen — das ist die Voraussetzung dafür, dass `dt = 0`
    /// bei Generierung und Spieler-Eingriff ein No-Op der Relaxationen ist).
    func testAnchorsAtZeroAndOneTimeConstant() {
        for tau in taus {
            XCTAssertEqual(Terrain.relaxFraction(dt: 0, tau: tau), 0,
                           "dt = 0 bewegt etwas (τ=\(tau))")
            XCTAssertEqual(Terrain.relaxFraction(dt: tau, tau: tau), 1 - 1 / exp(1.0),
                           accuracy: 1e-12, "τ=\(tau)")
            XCTAssertEqual(Terrain.relaxFraction(dt: 20 * tau, tau: tau), 1,
                           accuracy: 1e-8, "20 τ ist praktisch fertig (τ=\(tau))")
        }
    }

    /// RANDVERHALTEN, auf das Aufrufer sich verlassen: `tau = 0` heißt „sofort
    /// ganz" (1.0), nicht NaN — `floodplainAggradation` liest das so (`rate <= 0
    /// → return`, also greift der Pass bei τ = 0 voll durch). Der Helfer prüft
    /// bewusst nicht selbst; hier steht, was dabei herauskommt.
    func testZeroTimeConstantMeansInstantaneous() {
        XCTAssertEqual(Terrain.relaxFraction(dt: 100, tau: 0), 1)
        XCTAssertEqual(Terrain.relaxFraction(dt: 0.2, tau: 0), 1)
    }
}
