import Foundation

/// Großform der Generierung (Issue #174, Paket A): ein Gebirgskamm statt einer
/// gleichmäßigen Gratfläche, Tieflandkorridore vom Kamm zur Küste.
///
/// Vorher legte `generate()` `ridged01`-Grate über die ganze Landfläche; ein
/// Massiv-Rauschen modulierte nur die HÖHE, nicht die FORM — auch das
/// „Tiefland" war gratig, nur niedriger, und zerfiel in 12–24 Flecken
/// (`docs/zielbild-measurements.md`). Hier liegt die Form als Skelett aus
/// Polylinien in Gitterkoordinaten:
///
/// - **Kammachse** je Seed (gekrümmt) plus zwei bis drei **Seitenäste**. Mit dem
///   Abstand zum Skelett blendet das Relief von Graten (`mountain`) über sanfte
///   Hügel (`hill`) auf die flache Küstenebene über — als Distanzfeld zur
///   Achse, nicht als Radius um den Inselmittelpunkt. Das Hügelland reicht
///   weit (bis ~3,6 R): eine freie Ebene zwischen Kamm und Küste wäre ein
///   Kegel, von dem viele kleine Läufe parallel zur Küste rinnen, statt sich in
///   den Tälern zu sammeln (gemessen am ersten Entwurf mit 2,4 R).
/// - **Haupttäler** (zwei bis vier) laufen vom Kammfuß zur Küste und weiten sich
///   zum Meer hin auf. Im Tal (`corridor`) treten Grate und Hügel zurück; die
///   Talsohle steigt zum Talschluss sanft an (`rise`), mit einem Gefälle weit
///   unter der Mäander-Schwelle.
///
/// Reine Generierungs-Geometrie: kein Sim-Zustand, nichts davon reist im
/// Spielstand (die Felder, die daraus entstehen — `h`, `upliftBase` — tun es).
struct RangeSkeleton {
    /// Halbbreite des Gebirgsgürtels (Zellen). Bis etwa `R` vom Skelett ist
    /// Gebirge, bis etwa `3,6 R` Hügelland, dahinter Ebene.
    let halfWidth: Double
    private var ridges: [(pts: [SIMD2<Double>], weight: Double)] = []
    private var valleys: [[SIMD2<Double>]] = []

    /// Gewichte je Zelle, alle 0…1.
    struct Fields {
        var mountain: [Double]
        var hill: [Double]
        var corridor: [Double]
        var rise: [Double]
    }

    /// - Parameters:
    ///   - center: Mittelpunkt der Kammachse (Gitterkoordinaten).
    ///   - axisDir: Richtung der Achse (wird normiert).
    ///   - halfLength: halbe Achsenlänge (Zellen).
    init(n: Int, rng: inout Mulberry32, center: SIMD2<Double>, axisDir: SIMD2<Double>,
         halfLength: Double) {
        let len = (axisDir.x * axisDir.x + axisDir.y * axisDir.y).squareRoot()
        let dir = len > 1e-9 ? axisDir / len : SIMD2(1, 0)
        let perp = SIMD2(-dir.y, dir.x)
        let L = halfLength
        halfWidth = Double(n) * (0.14 + 0.06 * rng.next())

        // Achse: sanfter Bogen (eine bis anderthalb Halbwellen) über die Länge.
        let bend = 0.10 + 0.15 * rng.next()
        let freq = 0.5 + 0.7 * rng.next()
        let phase = rng.next() * 2 * .pi
        func axisPoint(_ s: Double) -> SIMD2<Double> {
            center + s * dir + (L * bend * sin(.pi * freq * s / L + phase)) * perp
        }
        let axisCount = 48
        ridges.append((pts: (0..<axisCount).map {
            axisPoint(-L + 2 * L * Double($0) / Double(axisCount - 1))
        }, weight: 1))

        // Seitenäste: schräg vom Hauptkamm weg, kürzer und niedriger.
        let spurCount = 2 + Int(rng.next() * 2)
        for _ in 0..<spurCount {
            let s0 = (rng.next() * 1.4 - 0.7) * L
            let side: Double = rng.next() < 0.5 ? -1 : 1
            let fwd: Double = rng.next() < 0.5 ? -1 : 1
            let ang = (40 + 30 * rng.next()) * .pi / 180
            let sd = cos(ang) * fwd * dir + sin(ang) * side * perp
            let sLen = (0.30 + 0.20 * rng.next()) * L
            let curl = (rng.next() - 0.5) * 0.6
            let start = axisPoint(s0)
            var pts: [SIMD2<Double>] = []
            for k in 0..<12 {
                let t = Double(k) / 11
                let sp = SIMD2(-sd.y, sd.x)
                pts.append(start + t * sLen * sd + curl * sLen * t * t * sp)
            }
            ridges.append((pts: pts, weight: 0.55 + 0.25 * rng.next()))
        }

        // Haupttäler: über die Achse verteilt, Seiten abwechselnd, vom Kammfuß
        // weg Richtung Küste (Länge über den Gitterrand hinaus — das Meer
        // beendet sie, nicht die Polylinie).
        let valleyCount = 2 + Int(rng.next() * 3)
        var side: Double = rng.next() < 0.5 ? -1 : 1
        for k in 0..<valleyCount {
            let s = (-0.75 + 1.5 * (Double(k) + 0.5) / Double(valleyCount)
                     + (rng.next() - 0.5) * 0.15) * L
            let jitter = (rng.next() - 0.5) * 50 * .pi / 180
            var vd = side * perp
            vd = SIMD2(vd.x * cos(jitter) - vd.y * sin(jitter), vd.x * sin(jitter) + vd.y * cos(jitter))
            let vp = SIMD2(-vd.y, vd.x)
            let wiggle = (rng.next() - 0.5) * 0.25
            let start = axisPoint(s) + 0.45 * halfWidth * side * perp
            let vLen = 1.2 * Double(n)
            var pts: [SIMD2<Double>] = []
            for q in 0..<40 {
                let t = Double(q) / 39
                pts.append(start + t * vLen * vd + wiggle * vLen * sin(.pi * t) * t * vp)
            }
            valleys.append(pts)
            side = -side
        }
    }

    /// Nächster Punkt auf einer Polylinie: Abstand und Bogenlänge bis dorthin.
    private static func nearest(_ pts: [SIMD2<Double>], _ p: SIMD2<Double>)
        -> (dist: Double, arc: Double, total: Double) {
        var best = Double.infinity, bestArc = 0.0, arc = 0.0
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let ab = b - a, ap = p - a
            let l2 = ab.x * ab.x + ab.y * ab.y
            let t = l2 > 1e-12 ? min(1, max(0, (ap.x * ab.x + ap.y * ab.y) / l2)) : 0
            let d = ap - t * ab
            let dd = d.x * d.x + d.y * d.y
            let seg = l2.squareRoot()
            if dd < best { best = dd; bestArc = arc + t * seg }
            arc += seg
        }
        return (best.squareRoot(), bestArc, arc)
    }

    @inline(__always) private static func smooth(_ a: Double, _ b: Double, _ v: Double) -> Double {
        let t = min(max((v - a) / (b - a), 0), 1); return t * t * (3 - 2 * t)
    }

    /// Wertet das Skelett auf dem ganzen Gitter aus (zeilenweise parallel, je
    /// Zelle unabhängig — bit-identisch zur sequenziellen Schleife).
    func evaluate(n: Int) -> Fields {
        let count = n * n
        var f = Fields(mountain: .init(repeating: 0, count: count),
                       hill: .init(repeating: 0, count: count),
                       corridor: .init(repeating: 0, count: count),
                       rise: .init(repeating: 0, count: count))
        let R = halfWidth
        f.mountain.withUnsafeMutableBufferPointer { mb in
        f.hill.withUnsafeMutableBufferPointer { hb in
        f.corridor.withUnsafeMutableBufferPointer { cb in
        f.rise.withUnsafeMutableBufferPointer { rb in
            // Swift 6 (Issue #201): rohe Zeiger in die @Sendable-Closure — je
            // Zeile `j` ein disjunktes Zeilen-Intervall, geschrieben wird nur
            // Index `j * n + i` des eigenen `j` (Projektregel wie bei
            // `Terrain.parallel`).
            nonisolated(unsafe) let pm = mb.baseAddress!, ph = hb.baseAddress!
            nonisolated(unsafe) let pc = cb.baseAddress!, pr = rb.baseAddress!
            DispatchQueue.concurrentPerform(iterations: n) { j in
                for i in 0..<n {
                    let p = SIMD2(Double(i), Double(j))
                    var m = 0.0, hl = 0.0
                    for (ri, r) in ridges.enumerated() {
                        let (d, arc, total) = Self.nearest(r.pts, p)
                        // Seitenäste sind schmaler und laufen zur Spitze aus;
                        // der Hauptkamm flacht nur an seinen Enden ab.
                        let u = total > 0 ? arc / total : 0
                        let taper = ri == 0 ? 1 - 0.45 * pow(abs(2 * u - 1), 4) : 1 - 0.6 * u
                        let dA = d / (R * (0.6 + 0.4 * r.weight))
                        m = max(m, r.weight * taper * (1 - Self.smooth(0.5, 1.3, dA)))
                        hl = max(hl, 1 - Self.smooth(1.0, 3.6, dA))
                    }
                    var c = 0.0, rise = 0.0
                    for v in valleys {
                        let (d, arc, _) = Self.nearest(v, p)
                        let open = Self.smooth(0, 2.2 * R, arc)
                        let w = R * (0.22 + 1.0 * open)
                        let cv = 1 - Self.smooth(0.55 * w, w, d)
                        if cv > c { c = cv; rise = 1 - open }
                    }
                    let k = j * n + i
                    pm[k] = m * (1 - c)
                    ph[k] = hl * (1 - c)
                    pc[k] = c
                    pr[k] = rise * c
                }
            }
        }}}}
        return f
    }
}
