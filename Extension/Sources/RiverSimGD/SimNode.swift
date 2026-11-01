import Foundation
import SwiftGodot
import SimCore
import SimRender

/// GDExtension-Brücke: hält die Welt-Sitzung (`SimRender.WorldSession`) und
/// reicht ihre Ergebnisse als Packed*Array an Godot. Alle @Callable-Methoden
/// sind aus GDScript aufrufbar.
///
/// Bewusst dünn (PLAN.md §1): die gesamte Physik lebt in `SimCore`, die
/// Render-Aufbereitung samt ihrem Zustand im godot-freien Target `SimRender`
/// (Issues #80/#82/#93), und seit Issue #212 auch die Regel der Brücke (vor
/// jedem Zugriff einen laufenden Schritt abwarten, nach jeder Weltänderung die
/// passende `TerrainChange` melden) in der Sitzung. Hier passiert nur
/// Marshalling Swift → Godot: Aufruf weiterreichen, `[UInt8]`/`[Float]`/
/// `RibbonMesh` als `Packed*Array` zurückgeben.
@Godot
final class SimNode: Node {
    /// Welt, Render-Zustand und Hintergrund-Job. Config UND Einlauf kommen als
    /// benannte Werte aus SimCore (`SimConfig.production`,
    /// `SimConfig.productionSettleYears`, Issue #97); die Brücke baut keine
    /// eigene Fassung. Nur der Produktionspfad läuft ein, die
    /// SimCore-Testwelten bleiben unverändert. Wächter:
    /// `SimCoreTests/RenderContractTests.swift`.
    private let session = WorldSession<VariantDictionary>(
        config: SimConfig.production,
        seed: RenderContract.defaultSeed,
        settleYears: SimConfig.productionSettleYears)
    private var lastWorldBytes = 0

    // MARK: Steuerung

    @Callable func generate(seed: Int) {
        session.generate(seed: UInt32(truncatingIfNeeded: seed),
                         settleYears: SimConfig.productionSettleYears)
    }

    @Callable func step(years: Double) { session.step(years: years) }

    // MARK: Hintergrund-Schritt (Zeitraffer)

    /// Zeitraffer-Schritt im Hintergrund; das Frame-Dictionary (Schlüssel wie
    /// `renderFrame`) holt `finishStep()` ab. Vertrag: `WorldSession.beginStep`.
    @Callable func beginStep(years: Double, trigger: Int, now: Double) {
        guard let frameTrigger = Self.frameTrigger(trigger, "beginStep") else { return }
        guard session.beginStep(years: years, trigger: frameTrigger, now: now,
                                pack: Self.packFrame) else {
            GD.pushError("beginStep: der vorige Schritt ist noch unterwegs — erst "
                         + "finishStep(), sonst ginge sein Frame verloren")
            return
        }
    }

    /// Ist ein Hintergrund-Schritt unterwegs (rechnet oder wartet aufs Abholen)?
    @Callable func stepInFlight() -> Bool { session.stepInFlight }

    /// Ist der Hintergrund-Schritt fertig? Blockiert nie.
    @Callable func stepReady() -> Bool { session.stepReady }

    /// Holt das Frame-Dictionary des Hintergrund-Schritts ab (wartet, falls er
    /// noch rechnet). Leer = es war keiner unterwegs.
    @Callable func finishStep() -> VariantDictionary { session.finishStep() ?? VariantDictionary() }

    /// Aufsummierte Zeit, die der Hauptthread auf Hintergrund-Schritte
    /// gewartet hat (ms), Messgröße für `docs/perf-measurements.md` §L: im
    /// Zeitraffer soll sie nicht wachsen.
    @Callable func stepWaitMilliseconds() -> Double { session.stepWaitedSeconds * 1000 }

    // MARK: Speichern / Laden (Issue #8)

    /// Schreibt die ganze Welt nach `path` (BETRIEBSSYSTEM-Pfad — GDScript muss
    /// `user://…` vorher durch `ProjectSettings.globalize_path()` schicken).
    /// Rückgabe: leerer String = Erfolg, sonst die Fehlermeldung für den Dialog.
    /// Godot kennt keine Swift-Fehler; ein String ist der ehrlichste Vertrag über
    /// die Brücke (Alternative wäre ein Bool + separates `lastError()`).
    @Callable func saveWorld(path: String) -> String {
        do {
            lastWorldBytes = try session.save(to: path)
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
            try session.load(from: path)
            lastWorldBytes = 0
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

    @Callable func gridSize() -> Int { session.config.n }
    @Callable func worldSize() -> Double { session.config.world }
    @Callable func seaLevel() -> Double { session.config.sea }
    @Callable func currentYear() -> Double { session.year }

    /// Zur Bauzeit eingebrannter Stempel der Quellen (Extension/Sources +
    /// SimCore/Sources, Verfahren: scripts/build-stamp.sh). Godot lädt die Library
    /// aus game/bin/ blind; smoke.gd vergleicht diesen Stempel mit dem
    /// Arbeitsverzeichnis und bricht bei einer veralteten .so laut ab, statt sie
    /// still zu benutzen (real passiert: "Nonexistent function brush").
    @Callable func buildStamp() -> String { BuildStamp.value }

    // MARK: Felder (row-major, Länge n*n)

    @Callable func heights() -> PackedFloat32Array { Self.pack(session.heights) }

    /// Höhenfeld als ROHE float32-Bytes — direkt als R32F-Textur hochladbar.
    /// GDScript hat vorher `heights().to_byte_array()` gerechnet: dieselben
    /// Bytes, aber eine zusätzliche ~2,7-MB-Kopie je Textur-Update (Issue #53).
    @Callable func heightsBytes() -> PackedByteArray { Self.packBytes(session.heights) }

    @Callable func flowArea() -> PackedFloat32Array { Self.pack(session.flowArea) }

    /// Abfluss-Nachbar je Zelle (-1 = Senke/Meer) — für Fluss-Geometrie.
    @Callable func receivers() -> PackedInt32Array { PackedInt32Array(session.receivers) }

    /// Höhenbänder (Issue #4) für den `bands`-Schlüssel des Frames:
    /// `[vegFull, vegNone, rockStart, rockFull, snowStart, snowFull, coniferLow, coniferHigh]`.
    /// **Ausnahme seit Issue #33:** `snowStart`/`snowFull` sind keine Perzentile
    /// mehr, sondern aus dem Schneefeld zurückgerechnet (s. `HeightBands`).
    private static func packBands(_ b: HeightBands) -> PackedFloat32Array {
        PackedFloat32Array([
            Float(b.vegFull), Float(b.vegNone), Float(b.rockStart), Float(b.rockFull),
            Float(b.snowStart), Float(b.snowFull), Float(b.coniferLow), Float(b.coniferHigh),
        ])
    }

    // MARK: Diagnose (Kennzahlen und Δ-Karte: `TerrainDiagnostics`)

    /// Setzt den Vergleichspunkt der Diagnose auf den aktuellen Zustand.
    @Callable func captureDebugReference() { session.captureDebugReference() }

    /// Kompakter Diagnosevertrag für GDScript — Reihenfolge und Bedeutung der
    /// Werte: `TerrainDiagnostics.stats`.
    @Callable func debugTerrainStats() -> PackedFloat32Array {
        PackedFloat32Array(session.debugTerrainStats())
    }

    /// Δ-Karte gegen den Vergleichspunkt (blau = abgetragen, rot = aufgebaut).
    @Callable func heightDifferenceBytes(scale: Double) -> PackedByteArray {
        PackedByteArray(session.heightDifferenceBytes(scale: scale))
    }

    // MARK: Frame-Protokoll (Issue #94)

    /// Die Puffer eines Frames — Reihenfolge und Drosseln: `RenderState.frame`.
    /// `trigger` = Rohwert von `FrameTrigger` (`FRAME_*` in `Main.gd`), `now` =
    /// `Time.get_ticks_msec() / 1000`. Schlüssel: s. `packFrame`.
    @Callable func renderFrame(trigger: Int, now: Double) -> VariantDictionary {
        guard let frameTrigger = Self.frameTrigger(trigger, "renderFrame") else {
            return VariantDictionary()
        }
        return Self.packFrame(session.renderFrame(frameTrigger, now: now))
    }

    private static func frameTrigger(_ raw: Int, _ caller: String) -> FrameTrigger? {
        guard let trigger = FrameTrigger(rawValue: raw) else {
            GD.pushError("\(caller): unbekannter Auslöser \(raw) — FRAME_* (Main.gd) "
                         + "und FrameTrigger sind auseinandergelaufen")
            return nil
        }
        return trigger
    }

    /// Ein Frame als Dictionary, für `renderFrame` (Hauptthread) und
    /// `beginStep` (Hintergrund) derselbe Weg. Statisch und ohne Zugriff auf
    /// den Knoten: der Hintergrund-Job verpackt damit selbst, und der
    /// Hauptthread bekommt fertige Packed-Arrays. Das sind Godots eingebaute
    /// Werttypen, kein `Object`; sie auf einem anderen Thread anzulegen und
    /// danach zu übergeben, ist erlaubt.
    ///
    /// Schlüssel:
    /// - immer: `trigger` (Rohwert), `year`, `heights` (R32F-Rohbytes),
    /// - mit Overlays (nur gemeinsam): `water`, `water_blend`, `color`,
    ///   `surface`, `cover`, `flow`, `protect`, `forest`, `plume`, `filled`
    ///   (Seespiegel, R32F) und `bands` (Höhenbänder wie früher `heightBands`),
    /// - nach einem Band-Bau: `ribbons` plus das Mesh in `ribbon_verts`,
    ///   `ribbon_colors`, `ribbon_uvs`, `ribbon_uv2s`, `ribbon_indices` und
    ///   `ribbon_strip_starts` (Vertex-Index je Band-Anfang; Main malt einen
    ///   Dreiecks-Supp und braucht ihn nicht, die Godot-Wächter zählen je Band).
    /// Fehlende Schlüssel heißen „in diesem Frame nicht neu".
    private static func packFrame(_ world: WorldFrame) -> VariantDictionary {
        let out = VariantDictionary()
        out[Variant("trigger")] = Variant(world.trigger.rawValue)
        out[Variant("year")] = Variant(world.year)
        out[Variant("heights")] = packBytes(world.heights).toVariant()
        if let o = world.frame.overlays {
            out[Variant("water")] = PackedByteArray(o.water).toVariant()
            out[Variant("water_blend")] = Variant(o.waterBlend)
            out[Variant("color")] = PackedByteArray(o.colors).toVariant()
            out[Variant("surface")] = PackedByteArray(o.surfaces).toVariant()
            out[Variant("cover")] = PackedByteArray(o.covers).toVariant()
            out[Variant("flow")] = PackedByteArray(o.flowDetail).toVariant()
            out[Variant("protect")] = PackedByteArray(o.protectMask).toVariant()
            out[Variant("forest")] = PackedByteArray(o.forestMask).toVariant()
            // Sedimentfahnen (#174 C): Float32-Rohbytes für eine RF-Textur.
            out[Variant("plume")] = packFloatBytes(o.plume).toVariant()
            out[Variant("filled")] = packBytes(world.waterLevel).toVariant()
            out[Variant("bands")] = packBands(world.bands).toVariant()
        }
        if world.frame.ribbonsRebuilt {
            out[Variant("ribbons")] = Variant(true)
            out[Variant("ribbon_verts")] = ribbonVerts(world.ribbons).toVariant()
            out[Variant("ribbon_colors")] = ribbonColors(world.ribbons).toVariant()
            out[Variant("ribbon_uvs")] = ribbonUVs(world.ribbons).toVariant()
            out[Variant("ribbon_uv2s")] = ribbonUV2s(world.ribbons).toVariant()
            out[Variant("ribbon_indices")] = PackedInt32Array(world.ribbons.indices).toVariant()
            out[Variant("ribbon_strip_starts")] = PackedInt32Array(world.ribbons.stripStarts).toVariant()
        }
        return out
    }

    private static func ribbonVerts(_ mesh: RibbonMesh) -> PackedVector3Array {
        PackedVector3Array(mesh.vertices.map { Vector3(x: $0.x, y: $0.y, z: $0.z) })
    }
    private static func ribbonColors(_ mesh: RibbonMesh) -> PackedColorArray {
        PackedColorArray(mesh.colors.map { Color(r: $0.x, g: $0.y, b: $0.z, a: $0.w) })
    }
    private static func ribbonUVs(_ mesh: RibbonMesh) -> PackedVector2Array {
        PackedVector2Array(mesh.uvs.map { Vector2(x: $0.x, y: $0.y) })
    }
    private static func ribbonUV2s(_ mesh: RibbonMesh) -> PackedVector2Array {
        PackedVector2Array(mesh.uv2s.map { Vector2(x: $0.x, y: $0.y) })
    }

    /// `RS_WATER_GPU`: Frames liefern das rohe Wasserfeld, Blur/EWMA laufen in
    /// der GPU-Kette von `Main.gd`.
    @Callable func setDeferWaterTail(enabled: Bool) { session.deferWaterTail = enabled }

    // MARK: Render-Buffer
    //
    // Issue #214: Es gibt keine Einzelschritt-Callables mehr — Wasserfeld,
    // Farben, Material, Masken und Fahnen entstehen NUR im Frame
    // (`renderFrame`/`beginStep`, Reihenfolge und Drosseln: `RenderState.frame`)
    // und reisen in dessen `overlays`. Was die Godot-Wächter brauchen, lesen
    // sie aus dem Frame-Dictionary; die Einzelschritte sind `internal` in
    // SimRender und gehören den headless XCTest-Wächtern.

    // MARK: Kalibrier-Register über die Brücke (Issue #213)

    /// Name → Wert EINER Gruppe aus `SimRender.CalibrationRegistry` (`water`,
    /// `water_contract`, `relief`, `canopy`, `material`, `contract`), in
    /// Deklarationsreihenfolge. Skalare reisen als `float`, Farben als
    /// `Vector3`. Uniform-Gruppen werden auf Float32 verengt (GLSL-Uniforms
    /// sind ohnehin einfach genau, und GDScript rechnet mit genau dem Wert,
    /// den der Shader sieht); Vertragsgruppen bleiben Double, damit die
    /// Godot-Wächter exakt die Kalibrierung vergleichen. Eine unbekannte Gruppe
    /// liefert ein leeres Dictionary, `Main.calibration` meldet das laut.
    @Callable func calibration(group: String) -> VariantDictionary {
        let out = VariantDictionary()
        guard let group = CalibrationRegistry.Group(rawValue: group) else { return out }
        for entry in CalibrationRegistry.entries(group) {
            switch entry.value {
            case .scalar(let v):
                out[Variant(entry.name)] = Variant(group.isUniform ? Double(Float(v)) : v)
            case .color(let r, let g, let b):
                out[Variant(entry.name)] = Variant(Vector3(x: Float(r), y: Float(g), z: Float(b)))
            }
        }
        return out
    }

    // MARK: Pass-Plan des GPU-Wasser-Schwanzes (Issue #95)

    // Struktur der GPU-Kette in `game/scripts/WaterGpuTail.gd`: Pass-Zahl,
    // Kanal-Masken (2 Werte je Pass, R dann G) und Priming des ersten Ticks.
    // Quelle ist `SimRender.WaterTailPlan` — dieselbe Quelle, aus der der
    // CPU-Pfad (`WaterFieldRenderer`) seine Pass-Zahlen nimmt; die Brücke
    // hält keine eigene Zahl. Die Blende je Tick reist seit jeher im Frame
    // (`water_blend`), nicht hier.

    @Callable func waterTailBlurPassCount() -> Int {
        WaterTailPlan.blurPassCount
    }

    @Callable func waterTailBlurMasks() -> PackedFloat32Array {
        PackedFloat32Array(WaterTailPlan.blurMasks().map { Float($0) })
    }

    @Callable func waterTailPrimeBlend() -> Float {
        Float(WaterTailPlan.primeBlend)
    }

    // MARK: Sculpting

    /// Pinsel-Werkzeug mit Stärke. `mode` ist der Rohwert von `BrushTool` — die
    /// Werkzeug-Tabelle in `Main.gd` hält dieselbe Reihenfolge (Issue #53).
    /// (Das alte `sculpt`-Callable ist mit Issue #214 weg: das Spiel hebt und
    /// senkt über den Pinsel, und `BrushTool.raise/lower` fährt auf Swift-Seite
    /// denselben `terrain.sculpt`-Weg. Die Sitzung hält `sculpt` weiterhin
    /// bereit, die Wächter laufen headless in `WorldSessionTests`.)
    @Callable func brush(mode: Int, gx: Double, gz: Double, radiusWorld: Double,
                         strength: Double, target: Double) {
        guard let tool = BrushTool(rawValue: mode) else {
            // Laut statt still: ein unbekannter Modus hieß vorher „nichts tun",
            // ein Werkzeug ohne Wirkung sah im Spiel wie ein Physik-Bug aus.
            GD.pushError("brush: unbekannter Modus \(mode) — Werkzeug-Tabelle (Main.gd) "
                         + "und BrushTool sind auseinandergelaufen")
            return
        }
        session.brush(tool, gx: gx, gz: gz, radiusWorld: radiusWorld,
                      strength: strength, target: target)
    }

    /// Nach Sculpting/Änderungen Entwässerung neu berechnen (für Live-Flüsse).
    /// WELCHE Pässe in welcher Reihenfolge dazugehören, steht seit Issue #93
    /// bei ihrem Besitzer: `Terrain.recomputeFlowAfterEdit`.
    @Callable func recomputeFlow() {
        session.recomputeFlow()
    }

    /// Effektive Maximal-Breite der Spitzhacke (Welteinheiten) — fürs Ring-Visual.
    @Callable func pickaxeMaxRadiusWorld() -> Double {
        session.pickaxeMaxRadiusWorld
    }

    /// Meldet die Auflösung des Terrain-Render-Gitters (Main.gd `terrain_grid`),
    /// damit die Land-Bänder ihre Höhen von der SICHTBAREN Oberfläche sampeln
    /// (`renderSurfaceHeight`) statt von den Sim-Höhen. Ohne Aufruf gilt volle
    /// Auflösung — die Headless-Wächter bleiben damit unverändert.
    @Callable func setRenderGrid(grid: Int) {
        session.renderGrid = grid
    }

    // MARK: Marshalling

    private static func pack(_ a: [Double]) -> PackedFloat32Array {
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

    /// `[Float]` als rohe float32-Bytes (RF-Textur), ohne Umweg über Double.
    private static func packFloatBytes(_ a: [Float]) -> PackedByteArray {
        PackedByteArray(a.withUnsafeBytes { Array($0) })
    }

    /// Wie `pack`, aber als rohe float32-Bytes: Godot kann sie direkt als R32F-
    /// Bilddaten übernehmen (`Image.set_data`), ohne dass GDScript das
    /// Float-Array noch einmal konvertieren muss.
    private static func packBytes(_ a: [Double]) -> PackedByteArray {
        var bytes = [UInt8](repeating: 0, count: a.count * 4)
        a.withUnsafeBufferPointer { ab in
        bytes.withUnsafeMutableBufferPointer { bb in
            let pa = ab.baseAddress!
            // `storeBytes` schreibt ausrichtungsfrei — der Byte-Puffer muss also
            // nicht 4-Byte-ausgerichtet sein.
            let raw = UnsafeMutableRawPointer(bb.baseAddress!)
            parallelChunks(a.count) { lo, hi in
                for i in lo..<hi {
                    raw.storeBytes(of: Float(pa[i]), toByteOffset: i * 4, as: Float.self)
                }
            }
        }}
        return PackedByteArray(bytes)
    }
}

#initSwiftExtension(cdecl: "swift_entry_point", types: [SimNode.self])
