import Foundation
import SwiftGodot
import SimCore

/// Datenparallel über disjunkte Index-Bereiche — nur für Pässe, deren Zellen
/// unabhängig sind (jede schreibt ausschließlich ihren eigenen Index): das
/// Ergebnis ist BIT-IDENTISCH zur sequenziellen Schleife. Gleiche Idee wie
/// `Terrain.parallel` in SimCore; die Render-Aufbereitung läuft sonst komplett
/// auf dem Godot-Hauptthread.
private let hostCoreCount = ProcessInfo.processInfo.activeProcessorCount
@inline(__always) private func parallelChunks(_ count: Int, _ body: (Int, Int) -> Void) {
    let chunks = min(count, max(1, hostCoreCount * 4))
    if chunks <= 1 { body(0, count); return }
    DispatchQueue.concurrentPerform(iterations: chunks) { c in
        body(count * c / chunks, count * (c + 1) / chunks)
    }
}

/// GDExtension-Brücke: hält den reinen `SimCore.Terrain` und reicht seine Felder
/// als Packed*Array an Godot. Alle @Callable-Methoden sind aus GDScript aufrufbar.
///
/// Bewusst dünn: die gesamte Physik lebt in SimCore (headless getestet), hier
/// passiert nur Marshalling Swift → Godot.
@Godot
final class SimNode: Node {
    private static func productionConfig() -> SimConfig {
        var config = SimConfig()
        config.hydraulicSkipWaterSpawns = true
        config.meanderSpatialCutoffIndex = true
        return config
    }

    /// `var`, weil ein geladener Spielstand seine EIGENE Config mitbringt
    /// (Issue #8): die Datei-Config ist autoritativ, also wird das Terrain beim
    /// Laden ersetzt statt in-place überschrieben.
    private var terrain = Terrain(config: SimNode.productionConfig(), seed: 1337)
    private var debugReferenceHeights: [Double] = []
    private var debugReferenceYear = 0.0
    private var lastWorldBytes = 0

    // MARK: Steuerung

    @Callable func generate(seed: Int) {
        terrain.generate(seed: UInt32(truncatingIfNeeded: seed))
        captureDebugReference()
    }

    @Callable func step(years: Double) {
        terrain.step(dtYears: years)
    }

    // MARK: Speichern / Laden (Issue #8)

    /// Schreibt die ganze Welt nach `path` (BETRIEBSSYSTEM-Pfad — GDScript muss
    /// `user://…` vorher durch `ProjectSettings.globalize_path()` schicken).
    /// Rückgabe: leerer String = Erfolg, sonst die Fehlermeldung für den Dialog.
    /// Godot kennt keine Swift-Fehler; ein String ist der ehrlichste Vertrag über
    /// die Brücke (Alternative wäre ein Bool + separates `lastError()`).
    @Callable func saveWorld(path: String) -> String {
        do {
            lastWorldBytes = try WorldSnapshot.write(terrain, to: path)
            return ""
        } catch let error as SnapshotError {
            return error.description
        } catch {
            return "Speichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    /// Lädt eine Welt aus `path`. Bei Erfolg ist der Zustand SOFORT vollständig
    /// (Seespiegel, Höhenbänder, Flüsse) — der Aufrufer muss nur seine Texturen
    /// neu ziehen, keinen Sim-Schritt erzwingen. Rückgabe wie `saveWorld`; im
    /// Fehlerfall bleibt die aktuelle Welt unangetastet.
    @Callable func loadWorld(path: String) -> String {
        do {
            let loaded = try WorldSnapshot.read(from: path)
            terrain = loaded
            lastWorldBytes = 0
            // Diagnose-Referenz auf den geladenen Stand: die Δ-Karte soll zeigen,
            // was die Sim AB JETZT tut, nicht die Differenz zur alten Welt.
            captureDebugReference()
            // Bäume neu bauen lassen (leerer Vergleichsstand ⇒ treeVegMaxDelta = 1).
            treeVegSnapshot = []
            // Fluss-Ribbons ebenso (riversMaxDelta ⇒ „riesig").
            riverSnapshot = []
            return ""
        } catch let error as SnapshotError {
            return error.description
        } catch {
            return "Laden fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    /// Gitterauflösung `n` der Welt in `path`, OHNE die Felder zu laden
    /// (−1 = Datei nicht lesbar/kein Spielstand — die Meldung dazu liefert dann
    /// `loadWorld`). Das Frontend baut seine Texturen und Meshes je Sitzung für
    /// EIN `n`; eine Welt mit abweichender Auflösung muss es ablehnen können,
    /// bevor die alte Welt ersetzt ist.
    @Callable func worldFileGridSize(path: String) -> Int {
        (try? WorldSnapshot.peekConfig(at: path).n) ?? -1
    }

    /// Kantenlänge der Welt in Welteinheiten aus `path`, ebenfalls ohne die
    /// Felder zu laden (−1 = nicht lesbar). Zweite Hälfte der Geometrie-Prüfung
    /// des Frontends: `n` ALLEIN genügt nicht — Mesh-Größe, Kamera-Distanz,
    /// Raycast-Skala und die Welt→Zelle-Umrechnung der Werkzeuge hängen an
    /// `world`. Bei gleicher Auflösung, aber anderer Weltgröße würde die
    /// geladene Simulation in anderen Weltkoordinaten laufen als Darstellung und
    /// Pinsel (`n` und `world` gehören in diesem Projekt zusammen, aber die
    /// DATEI garantiert das nicht).
    @Callable func worldFileWorldSize(path: String) -> Double {
        (try? WorldSnapshot.peekConfig(at: path).world) ?? -1
    }

    /// Größe der letzten geschriebenen Welt-Datei in Byte (0 = unbekannt) — für
    /// die Statusanzeige.
    @Callable func lastWorldFileBytes() -> Int { lastWorldBytes }

    /// Übliche Dateiendung für Welt-Dateien (ohne Punkt).
    @Callable func worldFileExtension() -> String { WorldSnapshot.fileExtension }

    // MARK: Konstanten

    @Callable func gridSize() -> Int { terrain.cfg.n }
    @Callable func worldSize() -> Double { terrain.cfg.world }
    @Callable func seaLevel() -> Double { terrain.cfg.sea }
    @Callable func floorLevel() -> Double { terrain.cfg.floor }
    @Callable func currentYear() -> Double { terrain.years }

    /// Zur Bauzeit eingebrannter Stempel der Quellen (Extension/Sources +
    /// SimCore/Sources, Verfahren: scripts/build-stamp.sh). Godot lädt die Library
    /// aus game/bin/ blind; smoke.gd vergleicht diesen Stempel mit dem
    /// Arbeitsverzeichnis und bricht bei einer veralteten .so laut ab, statt sie
    /// still zu benutzen (real passiert: "Nonexistent function brush").
    @Callable func buildStamp() -> String { BuildStamp.value }

    // MARK: Felder (row-major, Länge n*n)

    @Callable func heights() -> PackedFloat32Array { pack(terrain.h) }
    // Rendering bekommt den ratenbegrenzten SEESPIEGEL statt hf: Priority-Flood
    // springt beim Sill-Zuschütten instantan → hüpfende Seeflächen (s. Terrain.waterLevel).
    @Callable func filled() -> PackedFloat32Array { pack(terrain.waterLevel) }
    @Callable func sediment() -> PackedFloat32Array { pack(terrain.sed) }
    @Callable func rainField() -> PackedFloat32Array { pack(terrain.rain) }
    @Callable func vegetation() -> PackedFloat32Array { pack(terrain.veg) }

    /// Aktuelle Höhenbänder (Issue #4) als
    /// `[vegFull, vegNone, rockStart, rockFull, snowStart, snowFull, coniferLow, coniferHigh]`.
    /// Sie kommen aus dem Sim-Kern (Perzentile der Landhöhen) — der Shader und die
    /// Diagnose lesen sie hier ab, statt eigene absolute Schwellen zu führen.
    @Callable func heightBands() -> PackedFloat32Array {
        let b = terrain.heightBands
        return PackedFloat32Array([
            Float(b.vegFull), Float(b.vegNone), Float(b.rockStart), Float(b.rockFull),
            Float(b.snowStart), Float(b.snowFull), Float(b.coniferLow), Float(b.coniferHigh),
        ])
    }

    /// Vegetations-Klasse je Zelle (0 kahl · 1 Gras · 2 Wald · 3 Auwald) —
    /// fürs Rendering (z. B. eigene Baum-Art auf Auwald).
    @Callable func vegClasses() -> PackedByteArray { PackedByteArray(terrain.vegClass) }
    @Callable func flowArea() -> PackedFloat32Array { pack(terrain.area) }

    /// Abfluss-Nachbar je Zelle (-1 = Senke/Meer) — für Fluss-Geometrie.
    @Callable func receivers() -> PackedInt32Array { PackedInt32Array(terrain.receiver) }

    // MARK: Diagnose

    /// Setzt den Vergleichspunkt der Diagnose auf den aktuellen Zustand. Das ist
    /// besonders nach manuellem Einebnen nützlich: danach zeigt die Differenzkarte
    /// ausschließlich, was die Simulation selbst auf- oder abgebaut hat.
    @Callable func captureDebugReference() {
        debugReferenceHeights = terrain.h
        debugReferenceYear = terrain.years
    }

    /// Kompakter Diagnosevertrag für GDScript (alles Float32, damit kein Dictionary-
    /// Marshalling im Renderpfad anfällt):
    /// min, mean, max, Landrelief, deltaMean, deltaMax, Volumen unter Referenz,
    /// Volumen über Referenz, Nettovolumen, maxAbtrag, maxAufbau, Relief-Servo/100 J.,
    /// abklingende Hebung U(t)/100 J., Reliefziel, Referenzjahr, ungültige Zellen,
    /// robustes Relief-Signal (das REGELSIGNAL des Servo-Bodens, p95 − Median),
    /// mittlere Grat-Krümmung (Alterungs-Kennzahl: negativ = spitz, → 0 = rund).
    @Callable func debugTerrainStats() -> PackedFloat32Array {
        if debugReferenceHeights.count != terrain.h.count { captureDebugReference() }
        let h = terrain.h
        let reference = debugReferenceHeights
        guard !h.isEmpty else { return PackedFloat32Array() }

        var minimum = Double.greatestFiniteMagnitude
        var maximum = -Double.greatestFiniteMagnitude
        var referenceMaximum = -Double.greatestFiniteMagnitude
        var sum = 0.0, referenceSum = 0.0
        var belowReference = 0.0, aboveReference = 0.0
        var maxRemoved = 0.0, maxAdded = 0.0
        var valid = 0, invalid = 0
        for k in h.indices {
            let value = h[k], baseline = reference[k]
            guard value.isFinite && baseline.isFinite else { invalid += 1; continue }
            minimum = min(minimum, value)
            maximum = max(maximum, value)
            referenceMaximum = max(referenceMaximum, baseline)
            sum += value
            referenceSum += baseline
            valid += 1
            let delta = value - baseline
            if delta >= 0 {
                aboveReference += delta
                maxAdded = max(maxAdded, delta)
            } else {
                belowReference -= delta
                maxRemoved = max(maxRemoved, -delta)
            }
        }
        if valid == 0 {
            minimum = 0; maximum = 0; referenceMaximum = 0
        }
        let divisor = Double(max(1, valid))
        let cellArea = terrain.cfg.cellSize * terrain.cfg.cellSize
        let relief = terrain.landRelief()
        // Regelsignal und Servo-Wert kommen aus SimCore selbst — die Anzeige darf
        // die Formel nicht duplizieren, sonst zeigt sie etwas anderes als wirkt.
        let reliefSignal = terrain.landReliefRobust()
        // Talseiten-Gegenprobe (Issue #26): das Regelsignal ist die HOCHseite
        // (p95 − Median). Nach einer großflächigen Einebnung bleibt sie lange
        // bei ~0, während sich die Fläche längst nach UNTEN differenziert —
        // ohne die zweite Hälfte liest die Diagnose das als „keine Erholung".
        let reliefLow = terrain.landReliefLow()
        let servo = terrain.reliefServoRate()
        return PackedFloat32Array([
            Float(minimum), Float(sum / divisor), Float(maximum), Float(relief),
            Float((sum - referenceSum) / divisor), Float(maximum - referenceMaximum),
            Float(belowReference * cellArea), Float(aboveReference * cellArea),
            Float((aboveReference - belowReference) * cellArea), Float(maxRemoved), Float(maxAdded),
            Float(servo), Float(terrain.upliftDecayRatePer100y()), Float(terrain.cfg.reliefTarget),
            Float(debugReferenceYear), Float(invalid), Float(reliefSignal),
            Float(terrain.ridgeCurvature()), Float(reliefLow),
        ])
    }

    /// Blau = unter der Referenz, hellgrau = unverändert, Rot = darüber. `scale`
    /// ist die Höhenänderung, bei der die Farbe voll gesättigt ist.
    @Callable func heightDifferenceBytes(scale: Double) -> PackedByteArray {
        if debugReferenceHeights.count != terrain.h.count { captureDebugReference() }
        let h = terrain.h, reference = debugReferenceHeights
        let safeScale = max(scale, 1e-9)
        var out = [UInt8](repeating: 255, count: h.count * 4)
        h.withUnsafeBufferPointer { hb in
        reference.withUnsafeBufferPointer { rb in
        out.withUnsafeMutableBufferPointer { ob in
            let ph = hb.baseAddress!, pref = rb.baseAddress!, pout = ob.baseAddress!
            parallelChunks(h.count) { lo, hi in
                for k in lo..<hi {
                    let delta = ph[k] - pref[k]
                    let amount = delta.isFinite
                        ? sqrt(min(1, abs(delta) / safeScale))
                        : 1
                    let neutral = 0.78
                    let r: Double, g: Double, b: Double
                    if !delta.isFinite {
                        (r, g, b) = (1.0, 0.0, 1.0) // Magenta = ungültiger Höhenwert
                    } else if delta >= 0 {
                        (r, g, b) = (neutral + 0.17 * amount,
                                     neutral - 0.55 * amount,
                                     neutral - 0.58 * amount)
                    } else {
                        (r, g, b) = (neutral - 0.58 * amount,
                                     neutral - 0.25 * amount,
                                     neutral + 0.17 * amount)
                    }
                    let o = k * 4
                    pout[o] = UInt8(min(max(r, 0), 1) * 255)
                    pout[o + 1] = UInt8(min(max(g, 0), 1) * 255)
                    pout[o + 2] = UInt8(min(max(b, 0), 1) * 255)
                }
            }
        }}}
        return PackedByteArray(out)
    }

    // MARK: Render-Buffer (in Swift berechnet → GDScript setzt nur zusammen)

    /// Biom-/Höhen-Färbung (aus dem Prototyp) als RGBA8-Byte-Buffer (n*n*4) —
    /// direkt als Farb-Textur hochladbar, kein GDScript-Loop nötig.
    @Callable func terrainColorBytes() -> PackedByteArray {
        let n = terrain.cfg.n
        let sea = terrain.cfg.sea
        let h = terrain.h, rain = terrain.rain, veg = terrain.veg
        let salt = terrain.saltCrust
        // Lithologie (Issue #12): Gesteinshärte je Zelle (−1 weich … +1 hart) für
        // eine DEZENTE Färbung der Schichten. Nur `lithologyEnabled = false` lässt
        // das Feld leer — dann greift der 1-Element-Dummy und die Farben sind exakt
        // die von vorher. Der MESS-Referenzarm (`lithContrast = 0`) hat das Feld
        // dagegen gefüllt: dort ist die Physik uniform, die Bänder werden aber
        // trotzdem gemalt. Das ist gewollt — so lässt sich die Färbung gegen ein
        // Terrain vergleichen, das die Härte nicht gespürt hat.
        let lith = terrain.lithHardness.count == n * n ? terrain.lithHardness : [0.0]
        let lithOn = lith.count == n * n
        // Höhenbänder (Issue #4): einmal je Puffer gelesen — sie kommen aus dem
        // Sim-Kern (Perzentile der Landhöhen), nicht aus einer zweiten Kopie hier.
        let bands = terrain.heightBands
        var out = [UInt8](repeating: 255, count: n * n * 4)
        // Wasser (Flüsse/Seen/Altarme) zeichnet das separate Wasser-Feld (waterFieldBytes)
        // als glattes, geshadetes Overlay — hier nur Land-Biome + Meeresgrund.
        // Jede Zelle schreibt nur ihre 4 Bytes → zeilenparallel, bit-identisch.
        h.withUnsafeBufferPointer { hb in
        rain.withUnsafeBufferPointer { rnb in
        veg.withUnsafeBufferPointer { vgb in
        salt.withUnsafeBufferPointer { slb in
        lith.withUnsafeBufferPointer { ltb in
        out.withUnsafeMutableBufferPointer { ob in
        let ph = hb.baseAddress!, prain = rnb.baseAddress!
        let pveg = vgb.baseAddress!, psalt = slb.baseAddress!, pout = ob.baseAddress!
        let plith = ltb.baseAddress!
        parallelChunks(n) { jLo, jHi in
        for j in jLo..<jHi {
            for i in 0..<n {
                let k = j * n + i
                var r = 0.0, g = 0.0, b = 0.0
                let v = ph[k]
                if v <= sea + 0.012 {
                    (r, g, b) = gradColor(v)
                } else {
                    // Fels-first, naturalistisch entsättigt (Vorbild nickmcd): grauer
                    // Fels dominiert, Grün nur in feuchten flachen Tälern, helle
                    // Gipfel/Schnee. Die Zerklüftung/Schattierung macht das Licht.
                    // Steigung GROB (±2 Zellen, Terrain.macroSlope): seit der
                    // Pre-Erosion trägt jede Zelle feine Rinnen — die Per-Zell-
                    // Steigung wäre überall „steil" und würde die Vegetation aus
                    // allen Tälern waschen. Für die Biom-Färbung zählt der
                    // Hang-Charakter, nicht die Rinnen-Textur.
                    var slope = 0.0
                    if i > 1 && i < n - 2 && j > 1 && j < n - 2 {
                        slope = Terrain.macroSlope(ph, k, n)
                    }
                    let steep = min(1, slope * 45)                // 0 flach … 1 steil
                    r = 0.38 + 0.05 * steep                       // grauer Fels; steiler nur LEICHT heller
                    g = 0.39 + 0.05 * steep                       // (0.11 wusch die dichten 100k-Rinnen weiß)
                    b = 0.40 + 0.05 * steep
                    // Grünanteil aus DERSELBEN Standort-Eignung, die auch das
                    // veg-Ziel im Sim-Kern setzt (Issue #4) — vorher lagen hier
                    // eigene Konstanten (Höhenabfall ab 0.6 statt 0.5, Regen 1.2
                    // statt 1.3), die Färbung zeigte also nicht ganz das, was die
                    // Sim rechnet. `pveg` bleibt der zeitliche Zustand darüber.
                    // 0.85-Dämpfung: das Boden-Grün leicht entsättigen, damit die
                    // 3D-Bäume (MultiMesh, treeInstanceBuffer) sich vom Boden abheben —
                    // vorher konkurrierte das satte Moosgrün mit den Baumkronen.
                    let habitat = Terrain.vegetationSuitability(height: v, slope: slope,
                                                                rain: prain[k], bands: bands)
                    let vegAmt = min(1, (0.5 + 0.5 * pveg[k]) * habitat * 1.3) * 0.85
                    r += (0.19 - r) * vegAmt; g += (0.42 - g) * vegAmt; b += (0.14 - b) * vegAmt // kräftigeres Moosgrün
                    // Hochlagen: neutral-grauer Fels (nicht pastell/weiß), darüber
                    // Schnee auf den Gipfeln. Beide Grenzen sind PERZENTILE der
                    // aktuellen Landhöhen (Issue #4, Terrain.heightBands): die alten
                    // absoluten 0.58/1.05 trafen 1.1 % bzw. 0 % des Landes.
                    let wg = bands.rockAmount(v)
                    if wg > 0 {
                        r += (0.43 - r) * wg; g += (0.44 - g) * wg; b += (0.45 - b) * wg
                    }
                    let ws = bands.snowAmount(v)
                    if ws > 0 {
                        r += (0.93 - r) * ws; g += (0.94 - g) * ws; b += (0.96 - b) * ws
                    }
                    // Salzpfanne/Playa (Issue #11): der trockengefallene Boden
                    // eines abflusslosen Beckens ist NICHT mehr blau (das
                    // Wasser-Overlay malt dort nichts mehr) — als graugrünes Land
                    // wäre er aber auch nicht als das erkennbar, was er ist.
                    // Deshalb der Verdunstungsrückstand: helle, leicht warme
                    // Kruste (Terrain.saltCrust, 0 außerhalb solcher Becken).
                    // Deckel 0.9: die Kruste bleibt unter dem Gipfel-Schnee
                    // (0.93+) und liest sich als matter Salzboden, nicht als
                    // Schneefeld im Tal.
                    let sc = min(1, max(0, psalt[k])) * 0.9
                    if sc > 0 {
                        r += (0.87 - r) * sc; g += (0.86 - g) * sc; b += (0.80 - b) * sc
                    }
                    // Gesteinsbänder (Issue #12): hartes Gestein dunkler und
                    // wärmer, weiches heller — damit Schichtstufen und Härtekanten
                    // auch dort ablesbar sind, wo die Kante flach angeschnitten
                    // ist. Amplitude bewusst klein (±0.05): das Biom-Signal
                    // (Fels/Moos/Schnee) bleibt dominant, die Bänder sind Textur,
                    // keine zweite Farbskala.
                    if lithOn {
                        let hard = min(1, max(-1, plith[k])) * 0.05
                        r -= hard * 0.85; g -= hard; b -= hard * 1.25
                    }
                }
                let o = k * 4
                pout[o] = UInt8(min(max(r, 0), 1) * 255)
                pout[o + 1] = UInt8(min(max(g, 0), 1) * 255)
                pout[o + 2] = UInt8(min(max(b, 0), 1) * 255)
                // pout[o+3] bleibt 255 (Alpha)
            }
        }
        }
        }}}}}}
        return PackedByteArray(out)
    }

    // Höhen-Farbverlauf (Schwelle, r, g, b) — portiert aus dem Prototyp.
    private let stops: [(Double, Double, Double, Double)] = [
        (-0.3, 0.02, 0.07, 0.20), (0.00, 0.08, 0.22, 0.45), (0.15, 0.20, 0.42, 0.60),
        (0.17, 0.76, 0.70, 0.50), (0.28, 0.25, 0.48, 0.22), (0.45, 0.16, 0.34, 0.16),
        (0.58, 0.42, 0.38, 0.34), (0.70, 0.55, 0.53, 0.51), (0.80, 0.95, 0.96, 0.98),
    ]
    private func gradColor(_ v: Double) -> (Double, Double, Double) {
        for k in 0..<(stops.count - 1) {
            if v <= stops[k + 1].0 {
                let a = stops[k], c = stops[k + 1]
                let t = min(max((v - a.0) / (c.0 - a.0), 0), 1)
                return (a.1 + (c.1 - a.1) * t, a.2 + (c.2 - a.2) * t, a.3 + (c.3 - a.3) * t)
            }
        }
        let c = stops[stops.count - 1]
        return (c.1, c.2, c.3)
    }

    // MARK: Sculpting

    /// Hebt (dir > 0) oder senkt (dir < 0) das Terrain in einem Pinsel um
    /// Gitterzentrum (gx, gz) mit Radius in Welteinheiten. Koppelt in die Tektonik.
    @Callable func sculpt(gx: Double, gz: Double, radiusWorld: Double, dir: Double) {
        terrain.sculpt(gx: gx, gz: gz, radiusWorld: radiusWorld, dir: dir)
    }

    /// Generisches Pinsel-Werkzeug mit Stärke. Modi: 0 Anheben, 1 Absenken,
    /// 2 Glätten, 3 Einebnen (auf `target`-Höhe), 4 Aufrauen (fraktales Rauschen),
    /// 5 Spitzhacke (tiefer, spitzer Hieb — leitet Flüsse um).
    @Callable func brush(mode: Int, gx: Double, gz: Double, radiusWorld: Double,
                         strength: Double, target: Double) {
        switch mode {
        case 0: terrain.sculpt(gx: gx, gz: gz, radiusWorld: radiusWorld, dir: 1, strength: strength)
        case 1: terrain.sculpt(gx: gx, gz: gz, radiusWorld: radiusWorld, dir: -1, strength: strength)
        case 2: terrain.smooth(gx: gx, gz: gz, radiusWorld: radiusWorld, strength: strength)
        case 3: terrain.flatten(gx: gx, gz: gz, radiusWorld: radiusWorld,
                                targetHeight: target, strength: strength)
        case 4: terrain.roughen(gx: gx, gz: gz, radiusWorld: radiusWorld, strength: strength)
        case 5: terrain.pickaxe(gx: gx, gz: gz, radiusWorld: radiusWorld, strength: strength)
        default: break
        }
    }

    /// Nach Sculpting/Änderungen Entwässerung neu berechnen (für Live-Flüsse).
    /// Seespiegel snappt mit: Spieler-Feedback soll instantan sein, nur die
    /// Sim-Dynamik (Plug/Breach am Auslass) ist träge.
    @Callable func recomputeFlow() {
        terrain.computeFlow()
        terrain.snapWaterLevel()
        // Höhenbänder (Issue #4) mitziehen: ein Sculpt-Strich verschiebt die
        // Landhöhen-Verteilung, und die Färbung liest sie im selben Frame.
        terrain.updateHeightBands()
    }

    /// Effektive Maximal-Breite der Spitzhacke (Welteinheiten) — fürs Ring-Visual.
    @Callable func pickaxeMaxRadiusWorld() -> Double {
        Terrain.pickaxeMaxCells * terrain.cfg.cellSize
    }

    // MARK: Wasser-Feld (glattes Overlay statt Geometrie — nickmcd-Stream/Pool-Map)

    /// Kontinuierliches Wasser-Feld als RGBA8-Textur (n×n), das der Terrain-Shader
    /// linear gefiltert und geshadet als glattes Overlay rendert — statt blockiger
    /// Pro-Zell-Quads und Ribbon-Meshes. Kanäle:
    ///   R = Fluss-Intensität (Stream-Map: log-skalierter, dilatierter Abfluss)
    ///   G = See-GATE (wo Seen/Altarme sichtbar sind: Komponenten-Fade, geblurt —
    ///       die Ufer-KONTUR und die Tiefe zeichnet der Shader per Pixel aus
    ///       waterLevel − h, Issue #32)
    ///   B,A = Fließrichtung (aus dem Empfänger, kodiert *0.5+0.5) für die Animation
    // Persistente, zeitlich geglättete Wasserfelder (EWMA-Gedächtnis über Rebuilds).
    // Ohne sie wird das Feld jeden Tick frisch aus `hf` berechnet und flackert/springt;
    // mit ihnen BLENDET der Lauf zwischen Positionen (`blend` klein im Zeitraffer,
    // 1.0 bei Sprüngen/Sculpting = sofort übernehmen). Reiner Render-Zustand.
    private var sdS: [Double] = []
    private var lakeS: [Double] = []
    private var dxS: [Double] = []
    private var dzS: [Double] = []
    // Die Wasseraufbereitung läuft über viele Vollbild-Pässe. Diese temporären
    // Felder gehören deshalb zum Node statt bei jedem Render-Tick neu zu allokieren.
    private var waterStream: [Double] = []
    private var waterWiden: [Double] = []
    private var waterLake: [Double] = []
    private var waterBlur: [Double] = []
    private var waterRawWet: [Bool] = []
    private var waterMask: [Bool] = []
    private var waterComponentFade: [Double] = []
    private var waterSeen: [Bool] = []
    private var waterMDX: [Double] = []
    private var waterMDZ: [Double] = []
    private var waterStamp: [Bool] = []
    private var waterOxbow: [Double] = []
    private var waterBytes: [UInt8] = []
    private var waterComponent: [Int] = []
    private var waterStack: [Int] = []

    @Callable func waterFieldBytes(blend: Double) -> PackedByteArray {
        let n = terrain.cfg.n
        let cnt = n * n
        let sea = terrain.cfg.sea
        let cellArea = terrain.cfg.cellSize * terrain.cfg.cellSize
        let creek = terrain.cfg.renderMinCells // Render-Schwelle sichtbarer Läufe — ENTKOPPELT vom Braid-Physik-Gate (braidMinCells): 30→120→280 erhöht (User: „zu viele Flüsse"), die Braiding-Physik behält ihr eigenes Gate. Die Mäander-Hauptläufe kommen ohnehin direkt aus den Zentrumslinien.
        // areaMFD (Multi-Flow): stetige Fluss-Intensität → Läufe gleiten statt zu
        // springen und können sich um Bänke teilen. Erosion nutzt weiter D8-`area`.
        // Seetiefe/Nässe aus dem ratenbegrenzten Seespiegel statt hf — das Overlay
        // muss zur (ebenfalls waterLevel-gehobenen) See-Geometrie passen und nicht
        // mit jedem hf-Sprung flackern (s. Terrain.waterLevel).
        let h = terrain.h, hf = terrain.waterLevel, area = terrain.areaMFD, rec = terrain.receiver

        if waterStream.count != cnt {
            waterStream = [Double](repeating: 0, count: cnt)
            waterWiden = [Double](repeating: 0, count: cnt)
            waterLake = [Double](repeating: 0, count: cnt)
            waterBlur = [Double](repeating: 0, count: cnt)
            waterMDX = [Double](repeating: 0, count: cnt)
            waterMDZ = [Double](repeating: 0, count: cnt)
            waterOxbow = [Double](repeating: 0, count: cnt)
            waterRawWet = [Bool](repeating: false, count: cnt)
            waterMask = [Bool](repeating: false, count: cnt)
            waterComponentFade = [Double](repeating: 0, count: cnt)
            waterSeen = [Bool](repeating: false, count: cnt)
            waterStamp = [Bool](repeating: false, count: cnt)
            waterBytes = [UInt8](repeating: 0, count: cnt * 4)
            waterComponent.removeAll(keepingCapacity: false)
            waterStack.removeAll(keepingCapacity: false)
        }

        // Lokale Variablen halten die Hot-Loops schnell; durch das Tauschen mit
        // persistentem Speicher bleiben sie dabei über Render-Ticks allokationsfrei.
        var sd: [Double] = []; swap(&sd, &waterStream)
        var b: [Double] = []; swap(&b, &waterWiden)
        var lk: [Double] = []; swap(&lk, &waterLake)
        var blur: [Double] = []; swap(&blur, &waterBlur)
        var rawWet: [Bool] = []; swap(&rawWet, &waterRawWet)
        var mask: [Bool] = []; swap(&mask, &waterMask)
        var componentFade: [Double] = []; swap(&componentFade, &waterComponentFade)
        var seen: [Bool] = []; swap(&seen, &waterSeen)
        var mdx: [Double] = []; swap(&mdx, &waterMDX)
        var mdz: [Double] = []; swap(&mdz, &waterMDZ)
        var mstamp: [Bool] = []; swap(&mstamp, &waterStamp)
        var oxb: [Double] = []; swap(&oxb, &waterOxbow)
        var out: [UInt8] = []; swap(&out, &waterBytes)
        defer {
            swap(&sd, &waterStream); swap(&b, &waterWiden)
            swap(&lk, &waterLake); swap(&blur, &waterBlur)
            swap(&rawWet, &waterRawWet); swap(&mask, &waterMask)
            swap(&componentFade, &waterComponentFade); swap(&seen, &waterSeen)
            swap(&mdx, &waterMDX); swap(&mdz, &waterMDZ)
            swap(&mstamp, &waterStamp); swap(&oxb, &waterOxbow)
            swap(&out, &waterBytes)
        }

        // Stream-Map mit ABFLUSS-ABHÄNGIGER BREITE: ein Fluss wird stromab breiter &
        // kräftiger (Hauptflüsse breit + tiefblau, Bäche dünn). Effizient über
        // schwellen-gestufte Max-Dilatation: dünne Intensität ∝ log(Einzugsgebiet)
        // je Fluss-Zelle, dann 3 Dilatations-Pässe, in denen höhere Pässe nur noch
        // KRÄFTIGE Flüsse weiter verbreitern → Breiten-Hierarchie. Sequenziell,
        // cache-freundlich (kein Scheiben-Stempeln mit verstreuten Zugriffen).
        sd.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) }
        // nickmcd-Rendering: gemalt wird die STREAM-MAP (zeitgemittelte Tropfen-
        // Pfade = wo Wasser wirklich fließt, scharfe Fäden), die Intensität/
        // Breiten-Hierarchie kommt weiter aus dem Abfluss (areaMFD). Die reine
        // Abflussfläche als Maske malte dispergierten Sheet-Flow auf frisch
        // entwässerte Ebenen als flächigen Wash. Nicht unter substanziellen Seen
        // (Tiefe > 0.03) malen: dort deckt die Seefläche.
        let smap = terrain.streamMap
        // Per-Zelle unabhängig → parallel (bit-identisch zur sequenziellen Schleife).
        sd.withUnsafeMutableBufferPointer { sdb in
        h.withUnsafeBufferPointer { hb in hf.withUnsafeBufferPointer { hfb in
        area.withUnsafeBufferPointer { ab in smap.withUnsafeBufferPointer { smb in
            let psd = sdb.baseAddress!, ph = hb.baseAddress!, phf = hfb.baseAddress!
            let pa = ab.baseAddress!, psm = smb.baseAddress!
            parallelChunks(cnt) { lo, hi in
                for k in lo..<hi where phf[k] > sea && ph[k] > sea && phf[k] - ph[k] <= 0.01 {
                    let cu = pa[k] / cellArea
                    if cu < creek { continue }
                    let m = min(max((psm[k] - 0.18) / 0.24, 0), 1) // Track-Maske 0.18..0.42 (von 0.12..0.35 angehoben: Zufallspfad-Speckle bleibt drunter, konsistente Läufe drüber)
                    if m <= 0 { continue }
                    psd[k] = min(1, 0.4 + log(cu / creek + 1) / 4) * (0.35 + 0.65 * m)
                }
            }
        }}}}}
        // WASSERSPIEGEL-BEWUSST dilatieren: Wasser verbreitert sich nur auf Zellen,
        // die nicht nennenswert über dem WASSERSPIEGEL (hf) des Nachbarlaufs liegen
        // (barTol < braidBarHeight). Mittelbänke (Braiding!) und Ufer-/Talkanten
        // bleiben trocken, statt von der Kosmetik-Breite übermalt zu werden —
        // flache Auen und geflutete Ebenen tragen weiter die volle Breiten-
        // Hierarchie (hf, nicht h: seichtes Ponding blockt die Breite nicht).
        // KONTINUITÄT: Intensität dem D8-Empfänger entlang bergab propagieren
        // (leichter Abfall je Zelle). Die Track-Maske lässt sonst Lücken — seit
        // der Alle-Zellen-Dilatations-Pass weg ist (der überbrückte sie), zerfielen
        // gealterte Läufe in Punktketten. Ein sichtbarer Fluss läuft jetzt
        // garantiert durchgängig bis Mündung/See — 1 Zelle breit, Breite macht
        // weiterhin nur die (schwellen-gestufte) Dilatation darunter.
        for start in 0..<(n * n) where sd[start] > 0 {
            var val = sd[start] - 0.015
            var r = rec[start]
            while r >= 0 && val > 0.3 {
                let ri = Int(r)
                if sd[ri] >= val { break }   // Kette ab hier schon (stärker) gemalt
                sd[ri] = val
                val -= 0.015
                r = rec[ri]
            }
        }
        let barTol = 0.004
        // NUR kräftige Läufe verbreitern (kein Alle-Läufe-Pass mehr): Bäche bleiben
        // fadendünn (1 Zelle), Hauptflüsse verlieren ~1 Zelle Breite — die Breiten-
        // Hierarchie bleibt, ihr Absolutniveau sinkt (User: „proportional zu dick";
        // die alte Kalibrierung stammt von der kleineren 640er-Map).
        let widenThresh = [0.55, 0.80]
        for thresh in widenThresh {
            // Liest sd/h/hf, schreibt nur b[k] → zeilenparallel, bit-identisch.
            sd.withUnsafeBufferPointer { sdb in
            b.withUnsafeMutableBufferPointer { bb in
            h.withUnsafeBufferPointer { hb in hf.withUnsafeBufferPointer { hfb in
                let psd = sdb.baseAddress!, pb = bb.baseAddress!
                let ph = hb.baseAddress!, phf = hfb.baseAddress!
                parallelChunks(n) { jLo, jHi in
                for j in jLo..<jHi {
                    for i in 0..<n {
                        let k = j * n + i
                        var m = psd[k]
                        if i > 0 && psd[k - 1] > thresh && ph[k] - phf[k - 1] < barTol { m = max(m, psd[k - 1] - 0.09) }
                        if i < n - 1 && psd[k + 1] > thresh && ph[k] - phf[k + 1] < barTol { m = max(m, psd[k + 1] - 0.09) }
                        if j > 0 && psd[k - n] > thresh && ph[k] - phf[k - n] < barTol { m = max(m, psd[k - n] - 0.09) }
                        if j < n - 1 && psd[k + n] > thresh && ph[k] - phf[k + n] < barTol { m = max(m, psd[k + n] - 0.09) }
                        pb[k] = m
                    }
                }
                }
            }}}}
            swap(&sd, &b)
        }

        // DIREKT-RENDERING der Mäander-Entitäten: die persistenten Zentrumslinien und
        // Altarme werden GARANTIERT ins Feld gestempelt — unabhängig davon, ob die
        // D8-Drainage dem gecarvten sinuosen Bett folgt. Erst so werden „Arme, die
        // sich schlängeln und als Altarm-Seen abschnüren" wirklich sichtbar (der
        // Mäander IST die Fluss-Entität, nicht ein Nebenprodukt der D8-Karte).
        mdx.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) }
        mdz.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) }
        mstamp.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: false, count: cnt) }
        oxb.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) } // Altarm-See-Overlay (mit Alter ausgeblendet)
        let noMeanderPaint = ProcessInfo.processInfo.environment["RS_NO_MEANDER_PAINT"] != nil // Debug-Schalter
        // RIBBON-MODUS (Issue #31, RS_RIVER_RIBBONS): das Wasser der Mäander rendert
        // dann die Band-Geometrie (riverRibbon*-Puffer), NICHT mehr dieses Feld.
        // Der Korridor wird trotzdem gestempelt — aber nur mit SAUM-Intensität:
        // unter der Wasser-Schwelle des Terrain-Shaders (0.16, riverMask-smoothstep
        // in terrain.gdshader — derselbe Wert ist unten die Kohärenz-Schwelle des
        // keep-Filters), über seiner Ufer-Schwelle (0.09, shore-smoothstep ebd.).
        // Wer eine der Shader-Schwellen ändert, muss haloIntensity mitziehen.
        // Das Ribbon liegt so in einem weichen Nass-Halo aus dem bestehenden
        // Ufer-Saum — adressiert die dokumentierte Rückbau-Ursache von f3556c8
        // („harte Kanten am Ribbon↔Ufer-Übergang").
        let ribbonMode = riverRibbonsEnabled
        let haloIntensity = 0.14
        for ch in noMeanderPaint ? [] : terrain.meander.channels {
            let nodes = ch.nodes
            if nodes.count < 2 { continue }
            for i in 0..<(nodes.count - 1) {
                let ax = nodes[i].x, az = nodes[i].z, bx = nodes[i + 1].x, bz = nodes[i + 1].z
                let q = 0.5 * (ch.discharge[i] + ch.discharge[i + 1])   // Abfluss (Zellen) am Segment
                // Render-Gate wie beim Abfluss-Feld: Mäander-ENTITÄTEN existieren ab
                // meanderMinCells (85) und migrieren weiter, GEMALT werden Segmente
                // erst ab der Render-Schwelle — sonst stempeln hunderte Mini-Läufe
                // an renderMinCells vorbei (User: „zu viele Flüsse").
                if q < creek { continue }
                // Halbbreite ∝ log(Abfluss), Deckel 1 Zelle (war 3): über 10k+ Jahre
                // verknäulen die migrierten Linien auf den Ebenen — breite Stempel
                // machten aus den Knäueln blaue Blob-Felder („zu viele Flüsse").
                // Im Ribbon-Modus folgt der Saum-Radius stattdessen der Ribbon-
                // Halbbreite (+1 Zelle Rand), damit der Halo das Band ganz umfasst.
                let hw = ribbonMode
                    ? ribbonHalfWidthCells(q) + 1.0
                    : max(0.0, min(1.0, 0.3 + log(max(q, 1) / creek + 1) / 2.6))
                let rad = Int(hw.rounded())
                let intens = ribbonMode ? haloIntensity
                    : min(1.0, 0.6 + log(max(q, 1) / creek + 1) / 4)
                var tx = bx - ax, tz = bz - az
                let tl = (tx * tx + tz * tz).squareRoot(); if tl > 1e-6 { tx /= tl; tz /= tl }
                let steps = max(1, Int(tl.rounded()))
                for s in 0...steps {
                    let t = Double(s) / Double(steps)
                    let cx = Int((ax + (bx - ax) * t).rounded()), cy = Int((az + (bz - az) * t).rounded())
                    let jLo = max(0, cy - rad), jHi = min(n - 1, cy + rad)
                    let iLo = max(0, cx - rad), iHi = min(n - 1, cx + rad)
                    if jLo > jHi || iLo > iHi { continue }
                    for jj in jLo...jHi {
                        for ii in iLo...iHi {
                            let dd = (ii - cx) * (ii - cx) + (jj - cy) * (jj - cy)
                            if dd > rad * rad { continue }
                            let kk = jj * n + ii
                            // Intensität mit der Stream-Map gewichten: wo dem gestempelten
                            // Bett real kein Wasser folgt (verwaiste/verknäulte Linien),
                            // verblasst der Stempel, statt voll zu leuchten.
                            let mM = min(max((smap[kk] - 0.10) / 0.20, 0), 1)
                            let iM = intens * (0.30 + 0.70 * mM)
                            if sd[kk] < iM { sd[kk] = iM }
                            mstamp[kk] = true; mdx[kk] = tx; mdz[kk] = tz
                        }
                    }
                }
            }
        }
        // Ribbon-Modus: im gestempelten Korridor darf auch das D8-Abflussfeld nur
        // noch Saum-Intensität tragen — die D8-Drainage folgt dem gecarvten Bett
        // und würde sonst die „sprenklige" Textur-Version UNTER dem Band rendern.
        if ribbonMode {
            for k in 0..<cnt where mstamp[k] && sd[k] > haloIntensity { sd[k] = haloIntensity }
        }

        // Altarme (abgeschnürte Schleifen) als See-Overlay — verblassen mit dem Alter.
        // NUR substanzielle Schleifen (≥ 10 Knoten ≈ 15 Zellen Bogen): die Mäander-
        // Migration schnürt auch winzige 2–4-Knoten-Schlingen ab, die als
        // gestreute 3–6-Zell-Blobs die Ebenen sprenkelten („zu viele Flüsse/Seen"-
        // Eindruck) — erst ab dieser Länge liest sich ein Altarm als Altarm. Die
        // Cutoff-Enden liegen per Definition eng beieinander; würden wir sie beide
        // breit stempeln, schlösse sich der Altarm zu einem unnatürlichen Wasserring.
        // Deshalb Hals-Enden trimmen/ausblenden und nur Zellen mit echter Wassersäule
        // markieren: sichtbar bleibt der offene, physisch gefüllte Hufeisenbogen.
        let minimumOxbowNodes = 10
        let maximumTrimmedNodes = 3
        let fullEndFadeSteps = 3.0
        // KEINE eigene Tiefen-Rampe mehr (Issue #32): der Shader multipliziert den
        // G-Kanal mit der per-Pixel-Uferkontur smoothstep(pondContourLo,
        // pondContourHi, pond). Eine zweite Rampe hier hätte sie QUADRIERT — frische
        // Altarme verloren so 40–60 % Deckkraft (bei 0.01 Wassersäule: 0,25 → 0,05).
        // Die Kontur macht dasselbe besser: per Pixel statt zell-quantisiert.
        // Gestempelt wird deshalb nur noch PRÄSENZ (echte Wassersäule über dem
        // Kontur-Fuß) mit der Alters-/Rand-Deckkraft; die Ausblendung im seichten
        // Bogen-Ende übernimmt die Kontur. Präsenz-Schwelle == Kontur-Fuß: was der
        // Shader nicht mehr zeichnen kann, muss auch nicht gestempelt werden — und
        // umgekehrt darf der Stempel nicht früher aufhören als die Kontur, sonst
        // fehlen genau die seichten Enden. Im Ribbon-Modus (#31) ist das der EINZIGE
        // Altarm-Pfad: der Zentrumslinien-Stempel trägt dort nur Saum-Intensität
        // (0.14 < riverMaskLo), der Fluss-Kanal deckt Altarme also nicht mehr mit.
        let minimumPondDepth = WaterRender.pondContourLo
        let maximumOxbowOpacity = 0.7
        for oxbowIndex in terrain.meander.oxbows.indices {
            let oxbow = terrain.meander.oxbows[oxbowIndex]
            if oxbow.count < minimumOxbowNodes { continue }
            let age = oxbowIndex < terrain.meander.oxbowAge.count
                ? terrain.meander.oxbowAge[oxbowIndex]
                : 0
            let fade = max(0, 1 - age / terrain.cfg.oxbowMaxAge)
            if fade <= 0 { continue }
            let trim = min(maximumTrimmedNodes, max(1, oxbow.count / 8))
            let first = trim, last = oxbow.count - trim - 1
            if first > last { continue }
            for nodeIndex in first...last {
                let node = oxbow[nodeIndex]
                let edgeSteps = min(nodeIndex - first, last - nodeIndex)
                let endFade = min(1, Double(edgeSteps + 1) / fullEndFadeSteps)
                let centerX = Int(node.x.rounded()), centerY = Int(node.z.rounded())
                for (offsetX, offsetY) in [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let neighborX = centerX + offsetX, neighborY = centerY + offsetY
                    if neighborX < 0 || neighborX >= n || neighborY < 0 || neighborY >= n {
                        continue
                    }
                    let cellIndex = neighborY * n + neighborX
                    let pondDepth = hf[cellIndex] - h[cellIndex]
                    if hf[cellIndex] <= sea || h[cellIndex] <= sea || pondDepth <= minimumPondDepth {
                        continue
                    }
                    let value = maximumOxbowOpacity * fade * endFade
                    if oxb[cellIndex] < value { oxb[cellIndex] = value }
                }
            }
        }

        // See-Feld (substanzielle Seen, Tiefe > 0.03 — seichte Flutungs-Pfützen
        // NICHT malen, User: „zu viele Seen") + Altarm-Overlay.
        // KOHÄRENZ-FILTER über Fluss- UND See-Zellen GEMEINSAM: die rauen Braid-
        // Ebenen tragen tausende isolierte Wasser-Fetzen (Pfützen-Cluster +
        // Stream-Map-Patches, seit die Track-Maske Zufallspfade strenger schneidet),
        // die als blaue Punktfelder dithern („zu viele Flüsse/Seen"-Eindruck im
        // gealterten Terrain). Zusammenhängende Wasser-Komponenten (4er-Nachbar-
        // schaft) unter `componentFadeLoCells` bleiben unsichtbar, bis
        // `componentFadeHiCells` steigt die Deckkraft linear (Issue #32: FADE statt
        // hartem Cutoff bei 25 — beim Überschreiten PLOPPTEN wachsende Seen).
        // Echte Flüsse sind dank der Downstream-Propagation LANGE Ketten bis See/Meer,
        // echte Seen große Flächen — beide liegen weit über dem Fenster. Zubringer,
        // die in einen See münden, überleben über die gemeinsame Komponente.
        // Flood-Fill ist O(n²) und läuft eh nur je Render-Tick. Altarme separat
        // via oxb.
        // Fenster (`WaterRender.componentFadeLo/HiCells`) so gelegt, dass VOLLE
        // Sichtbarkeit nahe der alten Schwelle bleibt — die Herleitung inkl. der
        // Shader-Fenster und der verworfenen „symmetrischen" Variante steht dort,
        // headless abgesichert durch `SimCoreTests/WaterRenderTests.swift`.
        rawWet.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: false, count: cnt) }
        for k in 0..<cnt { rawWet[k] = hf[k] > sea && hf[k] - h[k] > 0.03 }
        for k in 0..<cnt { mask[k] = rawWet[k] || sd[k] >= 0.16 }
        componentFade.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) }
        seen.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: false, count: cnt) }
        waterComponent.removeAll(keepingCapacity: true)
        waterStack.removeAll(keepingCapacity: true)
        for start in 0..<cnt where mask[start] && !seen[start] {
            waterComponent.removeAll(keepingCapacity: true)
            waterStack.removeAll(keepingCapacity: true)
            waterStack.append(start); seen[start] = true
            while let k = waterStack.popLast() {
                waterComponent.append(k)
                let i = k % n, j = k / n
                if i > 0 && mask[k - 1] && !seen[k - 1] { seen[k - 1] = true; waterStack.append(k - 1) }
                if i < n - 1 && mask[k + 1] && !seen[k + 1] { seen[k + 1] = true; waterStack.append(k + 1) }
                if j > 0 && mask[k - n] && !seen[k - n] { seen[k - n] = true; waterStack.append(k - n) }
                if j < n - 1 && mask[k + n] && !seen[k + n] { seen[k + n] = true; waterStack.append(k + n) }
            }
            // Verschmelzen zweier Komponenten kann `fade` in einem Tick springen
            // (Teich berührt Flusskette) — im Zeitraffer dämpft das die EWMA
            // unten, bei Sprüngen (blend = 1) ist Sofort-Übernahme gewollt.
            let fade = WaterRender.componentFade(cells: waterComponent.count)
            if fade > 0 {
                for k in waterComponent { componentFade[k] = fade }
            }
        }
        // G-Kanal = See-GATE statt Tiefen-Rampe (Issue #32): WO ein See sichtbar
        // ist (inkl. Komponenten-Fade), sagt dieses Feld — die FORM der Uferlinie
        // und die Tiefe fürs Shading rechnet der Shader per Pixel aus
        // waterLevel − h (volle Sim-Auflösung, bilinear). Ein zell-binär
        // geschwelltes Tiefenfeld kann nach Blur + Smoothstep nur Zell-Treppen
        // liefern; das Gate darf grob sein, die pond-Kontur schneidet es
        // pixelgenau zu.
        lk.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) }
        for k in 0..<cnt {
            // Der Ribbon-Saum (haloIntensity) liegt unter der Kohärenz-Schwelle
            // (0.16) und würde vom Fade gedämpft — Korridor-Zellen sind aber per
            // Definition Teil eines echten Laufs (Zentrumslinie), nicht Speckle:
            // sie behalten ihre Saum-Intensität ungedämpft (Issue #31).
            if !(ribbonMode && mstamp[k]) { sd[k] *= componentFade[k] }
            // See-Gate NICHT vom Korridor ausnehmen: ein Ribbon-Korridor darf
            // keine Kleinst-Pfütze als See malen, deshalb bleibt lk am Fade.
            if rawWet[k] { lk[k] = componentFade[k] }
            if oxb[k] > lk[k] { lk[k] = oxb[k] }
        }
        // RÄUMLICH glätten: die Felder sind zell-binär geschwellt (creek/Tiefe) →
        // ohne Glättung wirken Flussränder und Seeufer als Pixel-Grieß. max(Kern,
        // 3×3-Blur) statt reinem Blur: die Kern-Intensität bleibt voll (sonst
        // verblassen dünne Läufe in der Übersicht), nur die Ränder bekommen einen
        // weichen Saum, den der Shader sauber smoothstept.
        func blur3(_ src: [Double], into dst: inout [Double]) {
            // Schreibt nur dst[k] → zeilenparallel, bit-identisch.
            src.withUnsafeBufferPointer { sb in
            dst.withUnsafeMutableBufferPointer { db in
                let ps = sb.baseAddress!, pd = db.baseAddress!
                parallelChunks(n) { jLo, jHi in
                for j in jLo..<jHi {
                    for i in 0..<n {
                        let k = j * n + i
                        var s = 0.0, c = 0.0
                        for dj in max(0, j-1)...min(n-1, j+1) {
                            for di in max(0, i-1)...min(n-1, i+1) {
                                s += ps[dj * n + di]; c += 1
                            }
                        }
                        pd[k] = s / c
                    }
                }
                }
            }}
        }
        // max(Kern, Blur) statt reinem Blur: Kern-Intensität bleibt voll, nur die
        // Ränder bekommen einen weichen Saum.
        func blurMax(_ field: inout [Double], passes: Int) {
            for _ in 0..<passes {
                blur3(field, into: &blur)
                for k in 0..<cnt { field[k] = max(field[k], blur[k]) }
            }
        }
        blurMax(&sd, passes: 1)
        // See-Gate ZWEIMAL bluren: es muss den seichten Ufersaum (Wassersäule
        // unter der rawWet-Schwelle 0.03) überdecken, damit die per-Pixel-Kontur
        // im Shader dort nicht vom Gate abgeschnitten wird — der Überstand aufs
        // Trockene ist unsichtbar, weil pond dort 0 ist.
        blurMax(&lk, passes: 2)

        // EWMA-Puffer bei Bedarf initialisieren (erstes Feld = sofort übernehmen).
        if sdS.count != cnt {
            sdS = [Double](repeating: 0, count: cnt)
            lakeS = [Double](repeating: 0, count: cnt)
            dxS = [Double](repeating: 0, count: cnt)
            dzS = [Double](repeating: 0, count: cnt)
        }
        let bl = min(max(blend, 0), 1) // 1 = Sprung sofort, klein = weiches Blenden

        // Per-Zelle unabhängig (schreibt nur die eigenen EWMA-Felder + 4 Bytes)
        // → parallel, bit-identisch.
        sdS.withUnsafeMutableBufferPointer { s1 in
        lakeS.withUnsafeMutableBufferPointer { s2 in
        dxS.withUnsafeMutableBufferPointer { s3 in
        dzS.withUnsafeMutableBufferPointer { s4 in
        out.withUnsafeMutableBufferPointer { ob in
        rec.withUnsafeBufferPointer { rcb in
            let psdS = s1.baseAddress!, plakeS = s2.baseAddress!
            let pdxS = s3.baseAddress!, pdzS = s4.baseAddress!
            let pout = ob.baseAddress!, prec = rcb.baseAddress!
            parallelChunks(cnt) { lo, hi in
            for k in lo..<hi {
                let lake = lk[k]
                // Richtung: gestempelte Mäander-Tangente, sonst rohe D8-Nachbardifferenz
                // (∈ {-1,0,1}; der Shader normalisiert selbst → kein sqrt hier). Wird
                // mitgeglättet, damit die Strömungsrichtung nicht schlagartig kippt.
                var dx = 0.0, dz = 0.0
                if mstamp[k] {
                    dx = mdx[k]; dz = mdz[k]
                } else {
                    let r = prec[k]
                    if r >= 0 { dx = Double(Int(r) % n - k % n); dz = Double(Int(r) / n - k / n) }
                }
                // EWMA: geglättetes Feld Richtung frischem Wert ziehen (Gedächtnis über Rebuilds).
                psdS[k]   += bl * (sd[k] - psdS[k])
                plakeS[k] += bl * (lake  - plakeS[k])
                pdxS[k]   += bl * (dx    - pdxS[k])
                pdzS[k]   += bl * (dz    - pdzS[k])
                let o = k * 4
                pout[o] = UInt8(min(max(psdS[k], 0), 1) * 255)
                pout[o + 1] = UInt8(min(max(plakeS[k], 0), 1) * 255)
                pout[o + 2] = UInt8((min(max(pdxS[k], -1), 1) * 0.5 + 0.5) * 255)
                pout[o + 3] = UInt8((min(max(pdzS[k], -1), 1) * 0.5 + 0.5) * 255)
            }
            }
        }}}}}}
        return PackedByteArray(out)
    }

    // MARK: Baum-Instanzen (MultiMesh-Puffer — reine Optik, NULL Sim-Rückwirkung)

    /// veg-Feld beim letzten Baum-Rebuild — Grundlage der Rebuild-Heuristik
    /// (Bäume nicht jeden Frame neu bauen, sondern nur wenn sich die Vegetation
    /// merklich geändert hat). Reiner Render-Zustand.
    private var treeVegSnapshot: [Double] = []

    /// Maximale |Δveg| seit dem letzten `markTreesBuilt()` — GDScript rebuildet
    /// die Baum-MultiMeshes erst ab einer Schwelle (Heuristik: 0.1). Vor dem
    /// ersten Build (kein Snapshot) immer 1 → erzwingt den Initial-Build.
    @Callable func treeVegMaxDelta() -> Double {
        let veg = terrain.veg
        if treeVegSnapshot.count != veg.count { return 1.0 }
        var maxD = 0.0
        for k in 0..<veg.count { maxD = max(maxD, abs(veg[k] - treeVegSnapshot[k])) }
        return maxD
    }

    /// Setzt den Rebuild-Vergleichspunkt auf das aktuelle veg-Feld.
    @Callable func markTreesBuilt() { treeVegSnapshot = terrain.veg }

    /// FNV-1a über (i, j, salt) → deterministischer Per-Zelle-Zufall für Jitter/
    /// Varianten/Verdünnung. KEIN Frame-Random: gleiche Zelle → gleicher Baum,
    /// sonst flackert der Wald bei jedem Rebuild.
    @inline(__always) private func treeHash01(_ i: Int, _ j: Int, _ salt: UInt32) -> Double {
        var x: UInt32 = 2_166_136_261
        x = (x ^ UInt32(truncatingIfNeeded: i)) &* 16_777_619
        x = (x ^ UInt32(truncatingIfNeeded: j)) &* 16_777_619
        x = (x ^ salt) &* 16_777_619
        // Avalanche-Mix (fmix32): FNV allein korreliert auf Rastern sichtbar.
        x ^= x >> 16; x = x &* 0x85eb_ca6b; x ^= x >> 13
        return Double(x) / Double(UInt32.max)
    }

    /// Feldwert an kontinuierlicher Grid-Position (bilinear, randgeklemmt).
    @inline(__always) private func bilinearGrid(_ field: [Double], _ gx: Double, _ gz: Double) -> Double {
        let n = terrain.cfg.n
        let xi = min(max(Int(gx), 0), n - 2), yi = min(max(Int(gz), 0), n - 2)
        let fx = min(max(gx - Double(xi), 0), 1), fy = min(max(gz - Double(yi), 0), 1)
        let k = yi * n + xi
        return field[k] * (1 - fx) * (1 - fy) + field[k + 1] * fx * (1 - fy)
             + field[k + n] * (1 - fx) * fy + field[k + n + 1] * fx * fy
    }

    /// Geländehöhe an kontinuierlicher Grid-Position (bilinear auf terrain.h).
    @inline(__always) private func treeBilinearH(_ gx: Double, _ gz: Double) -> Double {
        bilinearGrid(terrain.h, gx, gz)
    }

    /// MultiMesh-Transform-Puffer je Baum-Variante (0 Laubbaum, 1 Nadelbaum,
    /// 2 Busch): 12 Floats pro Instanz im Godot-Buffer-Layout (3×4-Zeilen der
    /// Basis + Origin) — GDScript setzt ihn direkt (`multimesh.buffer`), ohne
    /// je Instanz ein Transform3D zu bauen. `hscale` = vertikale Render-
    /// Überhöhung aus Main.gd (reine Render-Konstante, kennt SimCore nicht).
    ///
    /// Maske je Kandidat (jede 2. Zelle — Verdünnung auf ~20–60k Instanzen bei
    /// n=832): bewachsen (veg > 0.45 Baum bzw. 0.32..0.45 Busch), trocken
    /// (hf−h < 0.02, nicht im Flussbett/See), Grob-Steigung flach (±2 Zellen wie
    /// in updateVegetation, slope·40 < 0.3) und über der Strandlinie. Jitter,
    /// Varianten-Wahl, Größe und Drehung kommen aus dem (i,j)-Hash.
    @Callable func treeInstanceBuffer(variant: Int, hscale: Double) -> PackedFloat32Array {
        let n = terrain.cfg.n
        let sea = terrain.cfg.sea
        let cs = terrain.cfg.cellSize
        let half = terrain.cfg.world / 2
        let h = terrain.h, hf = terrain.hf, veg = terrain.veg
        let bands = terrain.heightBands
        var out: [Float] = []
        out.reserveCapacity(30_000 * 12)
        for j in stride(from: 2, to: n - 2, by: 2) {
            for i in stride(from: 2, to: n - 2, by: 2) {
                let k = j * n + i
                let v = veg[k]
                if v <= 0.32 { continue }
                if h[k] <= sea + 0.012 { continue }          // Strand/Meer
                if hf[k] - h[k] >= 0.02 { continue }          // nass: Flussbett/See/Aue
                // WALDGRENZE an der Schneelinie (Issue #4): das Vegetationsband
                // reicht höher als die Schneegrenze (vegNone ≈ 0.685 gegen
                // snowStart ≈ 0.570), die Sim hält dort also noch veg — Bäume auf
                // verschneiten Gipfeln wären aber sichtbar falsch. Regel und
                // Messwerte: HeightBands.bearsTrees.
                if !bands.bearsTrees(h[k]) { continue }
                // Grob-Steigung (±2 Zellen) wie in updateVegetation — dieselbe
                // Quelle (Terrain.macroSlope): der Hang-Charakter zählt, nicht die
                // feine Rinnen-Textur.
                let slope = Terrain.macroSlope(h, k, n)
                if slope * 40 >= 0.3 { continue }
                let isBush = v <= 0.45
                // Verdünnung ∝ veg-Dichte: dichter Bewuchs → mehr Bäume; der
                // Hash entscheidet deterministisch je Zelle.
                let keep = isBush ? 0.35 : min(0.9, (v - 0.45) * 2.5 + 0.35)
                if treeHash01(i, j, 0x51ed) >= keep { continue }
                // Varianten-Wahl: Nadel wird mit der Höhe wahrscheinlicher
                // (Vegetations-Stufen), unten dominiert Laub. Höhenband aus dem
                // Sim-Kern (Issue #4) statt der alten absoluten 0.26…0.48 — sonst
                // kippt der Wald mit jeder Neukalibrierung des Höhenbereichs
                // komplett auf eine Variante.
                let wanted: Int
                if isBush {
                    wanted = 2
                } else {
                    wanted = treeHash01(i, j, 0xc0f4) < bands.coniferShare(h[k]) ? 1 : 0
                }
                if wanted != variant { continue }
                // Jitter ±1 Zelle (bricht das 2er-Raster), Höhe bilinear an der
                // gejitterten Position, minimal versenkt (kein Schweben am Hang).
                let jx = (treeHash01(i, j, 0x9e37) - 0.5) * 2.0
                let jz = (treeHash01(i, j, 0x79b9) - 0.5) * 2.0
                let gx = Double(i) + jx, gz = Double(j) + jz
                let y = treeBilinearH(gx, gz) * hscale - 0.05
                let x = gx * cs - half
                let z = gz * cs - half
                let s = (isBush ? 0.7 : 0.8) + 0.5 * treeHash01(i, j, 0x5ca1)
                let ang = treeHash01(i, j, 0x2b2b) * 2 * Double.pi
                let c = s * cos(ang), sn = s * sin(ang)
                // Godot-MultiMesh-Layout (TRANSFORM_3D, ohne Color/CustomData):
                // Zeile0(xx yx zx ox) Zeile1(xy yy zy oy) Zeile2(xz yz zz oz).
                out.append(Float(c)); out.append(0); out.append(Float(sn)); out.append(Float(x))
                out.append(0); out.append(Float(s)); out.append(0); out.append(Float(y))
                out.append(Float(-sn)); out.append(0); out.append(Float(c)); out.append(Float(z))
            }
        }
        return PackedFloat32Array(out)
    }

    // MARK: Fluss-Ribbons (Issue #31 — Band-Geometrie entlang der Mäander-
    // Zentrumslinien statt Stempel→Raster→Render-Gitter-Doppelquantisierung).
    // Reine Optik, NULL Sim-Rückwirkung; A/B-Schalter RS_RIVER_RIBBONS.

    /// A/B-Schalter ohne Rebuild (Muster RS_NO_MEANDER_PAINT): gesetzt = Ribbons
    /// rendern die Mäander, das Wasserfeld stempelt nur noch den Ufer-Saum.
    private var riverRibbonsEnabled: Bool {
        ProcessInfo.processInfo.environment["RS_RIVER_RIBBONS"] != nil
    }

    /// Halbbreite (Zellen) aus dem Abfluss `q` (Zellen Einzugsgebiet):
    /// hydraulische Geometrie w ∝ √Q (Leopold/Maddock, Exponent b ≈ 0.5) statt
    /// des 1-Zellen-Deckels des Stempels. Referenzpunkt renderMinCells → dort
    /// 0.8 Zellen Halbbreite (≈ heutige Stempel-Optik); Boden 0.12 hält Oberläufe
    /// als feine Fäden sichtbar, Deckel 3.2 verhindert Ströme-als-Seen auf den
    /// verknäulten Ebenen (Lehre aus dem Blob-Felder-Rückbau des Stempels).
    @inline(__always) private func ribbonHalfWidthCells(_ q: Double) -> Double {
        let w = 0.8 * (max(q, 0) / terrain.cfg.renderMinCells).squareRoot()
        return min(max(w, 0.12), 3.2)
    }

    /// Zentrumslinien-Stand beim letzten Ribbon-Build (Dirty-Vertrag wie
    /// treeVegSnapshot): Knotenzahlen + Positionen, flach. Abfluss ändert sich
    /// nur zusammen mit Positionen (Migration/computeFlow) — Positionen genügen.
    private var riverSnapshot: [Double] = []
    private var rrVerts: [Vector3] = []
    private var rrCols: [Color] = []
    private var rrUVs: [Vector2] = []
    private var rrIdx: [Int32] = []

    private func flattenedChannelPositions() -> [Double] {
        var flat: [Double] = []
        for ch in terrain.meander.channels {
            flat.append(Double(ch.nodes.count))
            for nd in ch.nodes { flat.append(nd.x); flat.append(nd.z) }
        }
        return flat
    }

    /// Maximale Knoten-Verschiebung (Zellen) seit `markRiversBuilt()`; bei
    /// Struktur-Änderung (Cutoff, Resample, Neu-Saat, Laden) bewusst „riesig",
    /// damit GDScript sofort rebuildet. Vor dem ersten Build ebenso.
    /// EHRLICHE ERWARTUNG: während die Sim läuft, triggert das praktisch jeden
    /// Schritt (Meander.migrate resampled unconditional → Knotenzahl ändert
    /// sich). Der Vertrag spart im Pause-/Idle-/Sculpt-Zustand (kein Schritt →
    /// Delta exakt 0 → kein Rebuild); im Zeitraffer deckelt Main.gd den Mesh-
    /// Rebuild auf 1 Hz (gemessen: 0,30 s kosteten ~4 % FPS).
    @Callable func riversMaxDelta() -> Double {
        let flat = flattenedChannelPositions()
        if flat.count != riverSnapshot.count { return 1e9 }
        var maxD = 0.0
        for i in 0..<flat.count { maxD = max(maxD, abs(flat[i] - riverSnapshot[i])) }
        return maxD
    }

    /// Setzt den Rebuild-Vergleichspunkt auf die aktuellen Zentrumslinien.
    @Callable func markRiversBuilt() { riverSnapshot = flattenedChannelPositions() }

    /// Baut die Ribbon-Geometrie aus den Mäander-Zentrumslinien: Catmull-Rom-
    /// geglättetes Band, Breite ∝ √Abfluss, Oberläufe laufen über Enden-Taper
    /// fein aus. Vertex-Vertrag (konsumiert von water.gdshader):
    ///   COLOR.rg = Fließrichtung (kodiert *0.5+0.5), COLOR.b = Strahler-Rang/6,
    ///   COLOR.a = Deckkraft (Abfluss-Rampe × Kanal-Kohärenz × Taper),
    ///   UV.x = Quer-Position 0..1 (Kanten-Feathering), UV.y = Bogenlänge (Welt).
    /// `hscale` = Render-Überhöhung, `lift` = Anhebung über Gelände (Welt-Y) —
    /// deckt den Diskretisierungs-Fehler des gröberen Render-Gitters im Talgrund.
    @Callable func buildRiverRibbons(hscale: Double, lift: Double) {
        rrVerts.removeAll(keepingCapacity: true)
        rrCols.removeAll(keepingCapacity: true)
        rrUVs.removeAll(keepingCapacity: true)
        rrIdx.removeAll(keepingCapacity: true)
        let n = terrain.cfg.n
        let cs = terrain.cfg.cellSize
        let half = terrain.cfg.world / 2
        let creek = terrain.cfg.renderMinCells
        let smap = terrain.streamMap
        // Strahler-Rang (D8-Netz ab Mäander-Schwelle): Rang-Maß für die
        // Render-Hierarchie — hohe Ordnungen bleiben auch dort sichtbar, wo die
        // Abfluss-Rampe allein sie ausblenden würde. Bewusst je Build frisch:
        // computeFlow ändert receiver UND die area-Netzmaske auch ohne
        // Knoten-Cutoff; ein Cache nur nach Mäander-Struktur wäre fachlich alt.
        // Die Allokationsrate deckelt Main.gd gemeinsam für Echtzeit/_jump auf 1 Hz.
        let orders = terrain.strahlerOrders(minCells: terrain.cfg.meanderMinCells)

        let subdivisions = 3 // Samples je Knoten-Segment (Knotenabstand ~1.5 Zellen)
        for ch in terrain.meander.channels {
            let nodes = ch.nodes
            let m = nodes.count
            if m < 2 { continue }
            // Catmull-Rom-Subdivision der Zentrumslinie; Abfluss linear je Segment.
            var px: [Double] = [], pz: [Double] = [], pq: [Double] = []
            px.reserveCapacity(m * subdivisions)
            pz.reserveCapacity(m * subdivisions)
            pq.reserveCapacity(m * subdivisions)
            for i in 0..<(m - 1) {
                let p0 = nodes[max(i - 1, 0)], p1 = nodes[i]
                let p2 = nodes[i + 1], p3 = nodes[min(i + 2, m - 1)]
                for s in 0..<subdivisions {
                    let t = Double(s) / Double(subdivisions)
                    let t2 = t * t, t3 = t2 * t
                    px.append(0.5 * (2 * p1.x + (p2.x - p0.x) * t
                        + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2
                        + (3 * p1.x - p0.x - 3 * p2.x + p3.x) * t3))
                    pz.append(0.5 * (2 * p1.z + (p2.z - p0.z) * t
                        + (2 * p0.z - 5 * p1.z + 4 * p2.z - p3.z) * t2
                        + (3 * p1.z - p0.z - 3 * p2.z + p3.z) * t3))
                    pq.append(ch.discharge[i] + (ch.discharge[i + 1] - ch.discharge[i]) * t)
                }
            }
            px.append(nodes[m - 1].x); pz.append(nodes[m - 1].z); pq.append(ch.discharge[m - 1])
            let cnt = px.count

            // Deckkraft: Abfluss-Rampe je Sample (fein auslaufen statt harter
            // renderMinCells-Kante) × Stream-Map-Kohärenz des ganzen Kanals
            // (verwaiste/verknäulte Linien als Einheit ausblenden) × Strahler-Boden.
            var alpha = [Double](repeating: 0, count: cnt)
            var rank = [Double](repeating: 0, count: cnt)
            var supportSum = 0.0, supportWeight = 0.0
            for a in 0..<cnt {
                let ci = min(max(Int(px[a].rounded()), 0), n - 1)
                let cj = min(max(Int(pz[a].rounded()), 0), n - 1)
                // D8 und Lagrange-Zentrumslinie liegen nicht zellgenau
                // übereinander. Ein 1-Zellen-Stützsaum verhindert, dass ein
                // Band beim Überqueren EINER Zellgrenze zwischen Ordnung 3/4
                // komplett ein-/ausblendet (räumliche Hysterese ohne Zustand).
                var localOrder: Int32 = 0
                for oj in max(0, cj - 1)...min(n - 1, cj + 1) {
                    for oi in max(0, ci - 1)...min(n - 1, ci + 1) {
                        localOrder = max(localOrder, orders[oj * n + oi])
                    }
                }
                let ord = Double(localOrder)
                rank[a] = min(ord / 6.0, 1.0)
                // Die Zentrumslinie ist kontinuierlich; die Sichtbarkeit ebenso
                // bilinear aus der Stream-Map lesen. Nearest-Cell erzeugte bei
                // Zellwechseln einzelne Alpha-Spitzen (sichtbare Dreiecksfächer).
                let stream = bilinearGrid(smap, px[a], pz[a])
                let mM = min(max((stream - 0.10) / 0.20, 0), 1)
                let x = min(max(pq[a] / creek, 0), 1)
                let ramp = x * x * (3 - 2 * x) // smoothstep(0, creek, q)
                var aQ = ramp
                if ord >= 3 { aQ = max(aQ, 0.5) }
                alpha[a] = aQ
                // Die Stream-Map entscheidet auf KANAL-Ebene: lokale
                // Raster-Spitzen als Alpha zu übernehmen erzeugt isolierte
                // Dreiecksfächer. Ein kohärent durchflossener Kanal bleibt
                // stattdessen als ganzes Band sichtbar, inklusive Oberlauf.
                let weight = max(ramp, 0.05)
                supportSum += mM * weight
                supportWeight += weight
            }
            let supportMean = supportSum / max(supportWeight, 1e-9)
            let supportX = min(max((supportMean - 0.35) / 0.30, 0), 1)
            let channelOpacity = supportX * supportX * (3 - 2 * supportX)
            for a in 0..<cnt { alpha[a] *= channelOpacity }

            // Diskrete Strahler-Zellen können an Netz-Kreuzungen verbleibende
            // Sprünge erzeugen. Symmetrisch längs filtern: keine zeitliche
            // Verzögerung, längere aktive Reaches bleiben unverändert.
            let alphaRadius = 6 // Samples à ~0.5 Zellen → ±3 Zellen
            var prefix = [Double](repeating: 0, count: cnt + 1)
            for a in 0..<cnt { prefix[a + 1] = prefix[a] + alpha[a] }
            for a in 0..<cnt {
                let aLo = max(0, a - alphaRadius)
                let aHi = min(cnt, a + alphaRadius + 1)
                alpha[a] = (prefix[aHi] - prefix[aLo]) / Double(aHi - aLo)
            }
            // Unsichtbare Schwänze (Deckkraft ≈ 0) nicht emittieren; 2 Samples
            // Vorlauf bleiben für den weichen Einstieg.
            guard var lo = alpha.firstIndex(where: { $0 > 0.02 }),
                  let hi = alpha.lastIndex(where: { $0 > 0.02 }) else { continue }
            lo = max(0, lo - 2)
            if hi - lo < 2 { continue }
            // Kartografische Hierarchie: nur Zentrumslinien, die wenigstens
            // Strahler 4 erreichen. Der feine Oberlauf DESSELBEN Bands bleibt
            // vollständig erhalten; Ordnung 3 ließ im fokussierten 20k-A/B noch
            // hunderte überlagerte Mäander auf der Ebene sichtbar werden.
            if !rank[lo...hi].contains(where: { $0 >= 0.65 }) { continue }

            // Bogenlängen (Welt) für Taper und UV.y.
            var arc = [Double](repeating: 0, count: cnt)
            for a in (lo + 1)...hi {
                let dx = (px[a] - px[a - 1]) * cs, dz = (pz[a] - pz[a - 1]) * cs
                arc[a] = arc[a - 1] + (dx * dx + dz * dz).squareRoot()
            }
            let total = arc[hi]

            let base = rrVerts.count
            for a in lo...hi {
                let a0 = max(lo, a - 1), a1 = min(hi, a + 1)
                var tx = px[a1] - px[a0], tz = pz[a1] - pz[a0]
                let tl = (tx * tx + tz * tz).squareRoot()
                if tl > 1e-9 { tx /= tl; tz /= tl }
                // Enden-Taper: Quelle läuft über ~4 Zellen zur Spitze aus,
                // Mündung über ~2 Zellen (dort übernimmt Meer/See).
                let taper = min(1, min(arc[a] / (4 * cs), (total - arc[a]) / (2 * cs)))
                let hw = ribbonHalfWidthCells(pq[a]) * cs * max(taper, 0.0)
                let wx = px[a] * cs - half, wz = pz[a] * cs - half
                let perpx = -tz * hw, perpz = tx * hw
                // Jede Kante folgt ihrer eigenen lokalen Höhe. Eine gemeinsame
                // Zentrumslinien-Höhe schneidet das Band an Quergefällen ins
                // Terrain; sichtbar bleiben dann nur radiale Dreiecksfragmente.
                let edgeGX = perpx / cs, edgeGZ = perpz / cs
                let yLeft = Float(treeBilinearH(px[a] - edgeGX, pz[a] - edgeGZ) * hscale + lift)
                let yRight = Float(treeBilinearH(px[a] + edgeGX, pz[a] + edgeGZ) * hscale + lift)
                rrVerts.append(Vector3(x: Float(wx - perpx), y: yLeft, z: Float(wz - perpz)))
                rrVerts.append(Vector3(x: Float(wx + perpx), y: yRight, z: Float(wz + perpz)))
                let col = Color(r: Float(tx * 0.5 + 0.5), g: Float(tz * 0.5 + 0.5),
                                b: Float(rank[a]), a: Float(alpha[a] * taper))
                rrCols.append(col); rrCols.append(col)
                rrUVs.append(Vector2(x: 0, y: Float(arc[a])))
                rrUVs.append(Vector2(x: 1, y: Float(arc[a])))
                if a > lo {
                    let v = Int32(base + (a - lo - 1) * 2)
                    rrIdx.append(v); rrIdx.append(v + 2); rrIdx.append(v + 1)
                    rrIdx.append(v + 1); rrIdx.append(v + 2); rrIdx.append(v + 3)
                }
            }
        }
    }

    @Callable func riverRibbonVerts() -> PackedVector3Array { PackedVector3Array(rrVerts) }
    @Callable func riverRibbonColors() -> PackedColorArray { PackedColorArray(rrCols) }
    @Callable func riverRibbonUVs() -> PackedVector2Array { PackedVector2Array(rrUVs) }
    @Callable func riverRibbonIndices() -> PackedInt32Array { PackedInt32Array(rrIdx) }

    private func pack(_ a: [Double]) -> PackedFloat32Array {
        var f = [Float](repeating: 0, count: a.count)
        a.withUnsafeBufferPointer { ab in
        f.withUnsafeMutableBufferPointer { fb in
            let pa = ab.baseAddress!, pf = fb.baseAddress!
            parallelChunks(a.count) { lo, hi in
                for i in lo..<hi { pf[i] = Float(pa[i]) }
            }
        }}
        return PackedFloat32Array(f)
    }
}

#initSwiftExtension(cdecl: "swift_entry_point", types: [SimNode.self])
