import Foundation
import SwiftGodot
import SimCore
import SimRender

/// GDExtension-Brücke: hält den reinen `SimCore.Terrain` und reicht seine Felder
/// als Packed*Array an Godot. Alle @Callable-Methoden sind aus GDScript aufrufbar.
///
/// Bewusst dünn (PLAN.md §1): die gesamte Physik lebt in `SimCore`, die
/// Render-Aufbereitung samt ihrem Zustand im godot-freien Target `SimRender`
/// (Issues #80/#82/#93). Hier passiert nur Marshalling Swift → Godot: Aufruf
/// weiterreichen, `[UInt8]`/`[Float]`/`RibbonMesh` als `Packed*Array`
/// zurückgeben.
@Godot
final class SimNode: Node {
    /// `var`, weil ein geladener Spielstand seine EIGENE Config mitbringt
    /// (Issue #8): die Datei-Config ist autoritativ, also wird das Terrain beim
    /// Laden ersetzt statt in-place überschrieben.
    ///
    /// Config UND Einlauf kommen als benannte Werte aus SimCore
    /// (`SimConfig.production`, `SimConfig.productionSettleYears`, Issue #97);
    /// die Brücke baut hier keine eigene Fassung mehr — sie stand sonst als
    /// eine von sechs handgepflegten Kopien da, die nichts verband. Nur der
    /// Produktionspfad läuft ein, die SimCore-Testwelten (`generate`-Default 0)
    /// bleiben unverändert. Wächter: `SimCoreTests/RenderContractTests.swift`.
    ///
    /// Angefasst wird die Welt nur über `terrain` (s. dort); direkt nur in
    /// `beginStep`, das sie dem Hintergrund-Job übergibt.
    private var world = Terrain(config: SimConfig.production,
                                seed: RenderContract.defaultSeed,
                                settleYears: SimConfig.productionSettleYears)
    private var lastWorldBytes = 0

    /// Der gesamte Render-Zustand (die Renderer mit ihren EWMA-Feldern,
    /// Arbeitspuffern und Dirty-Snapshots plus der Material-Cache) liegt seit
    /// Issue #93 in `SimRender`. Die Brücke hält davon nichts mehr selbst und
    /// meldet nach JEDER Terrain-Änderung `render.invalidate` — den einen
    /// Einstieg dort. Angefasst wird er nur über `render` (s. dort).
    private let renderState = RenderState()

    /// Sim-Schritt plus Frame-Aufbereitung auf einem Hintergrund-Thread
    /// (`beginStep`): im Zeitraffer wartet der Hauptthread nicht mehr darauf.
    /// Das Ergebnis ist das fertig verpackte Frame-Dictionary.
    private let job = BackgroundJob<VariantDictionary>(label: "river-sim.step")

    /// DER Zugang zur Welt für jeden Aufruf der Brücke: wartet zuerst einen
    /// laufenden Hintergrund-Schritt ab. Damit kann kein Aufruf die Welt
    /// anfassen, während der Job sie rechnet, und vergessen lässt sich das
    /// nicht, weil es keinen zweiten Weg gibt (Wächter:
    /// `BackgroundJobTests.testBridgeTouchesTheWorldOnlyThroughTheGate`).
    /// Ohne laufenden Job kostet das eine Sperre.
    private var terrain: Terrain {
        get { job.wait(); return world }
        set { job.wait(); world = newValue }
    }

    /// Wie `terrain`, für den Render-Zustand.
    private var render: RenderState {
        job.wait()
        return renderState
    }

    /// Ein laufender Job darf seinen Knoten nicht überleben: beim Beenden
    /// entlädt Godot danach die Library, deren Code er gerade ausführt.
    deinit {
        job.wait()
    }

    // MARK: Steuerung

    @Callable func generate(seed: Int) {
        terrain.generate(seed: UInt32(truncatingIfNeeded: seed),
                         settleYears: SimConfig.productionSettleYears)
        render.invalidate(terrain, .replaced)
    }

    @Callable func step(years: Double) {
        terrain.step(dtYears: years)
        render.invalidate(terrain, .advanced)
    }

    // MARK: Hintergrund-Schritt (Zeitraffer)

    /// Startet `step(years)` und danach den Frame `trigger` (wie `renderFrame`)
    /// auf einem Hintergrund-Thread und kehrt sofort zurück. Abholen:
    /// `stepReady()` fragt, ohne zu blockieren, `finishStep()` liefert das
    /// Frame-Dictionary (dieselben Schlüssel wie `renderFrame`).
    ///
    /// Bis zum Abholen ist der Schritt UNTERWEGS (`stepInFlight`). Jeder
    /// andere Aufruf, der Welt oder Render-Zustand braucht, wartet ihn ab
    /// (`terrain`/`render`), lässt sein Ergebnis aber liegen: hochladen muss
    /// es der Aufrufer, sonst zeigt Godot einen anderen Stand als den, den
    /// `RenderState` für sichtbar hält. Ein Start, solange ein Schritt
    /// unterwegs ist, ist deshalb ein Fehler und startet nichts.
    ///
    /// Determinismus: der Job rechnet genau `step` + `renderFrame`, nur auf
    /// einem anderen Thread, und niemand sonst fasst die Welt dabei an.
    @Callable func beginStep(years: Double, trigger: Int, now: Double) {
        guard let frameTrigger = Self.frameTrigger(trigger, "beginStep") else { return }
        guard !job.isPending else {
            GD.pushError("beginStep: der vorige Schritt ist noch unterwegs — erst "
                         + "finishStep(), sonst ginge sein Frame verloren")
            return
        }
        // Ohne Job unterwegs gehören Welt und Render-Zustand ab hier dem Job.
        let terrain = world, render = renderState
        job.start {
            terrain.step(dtYears: years)
            render.invalidate(terrain, .advanced)
            let frame = render.frame(terrain, frameTrigger, now: now)
            return Self.packFrame(frame, frameTrigger, heights: terrain.h, year: terrain.years,
                                  waterLevel: terrain.waterLevel, bands: terrain.heightBands,
                                  ribbons: render.riverRibbonMesh)
        }
    }

    /// Ist ein Hintergrund-Schritt unterwegs (rechnet oder wartet aufs Abholen)?
    @Callable func stepInFlight() -> Bool { job.isPending }

    /// Ist der Hintergrund-Schritt fertig? Blockiert nie.
    @Callable func stepReady() -> Bool { job.isReady }

    /// Holt das Frame-Dictionary des Hintergrund-Schritts ab (wartet, falls er
    /// noch rechnet). Leer = es war keiner unterwegs.
    @Callable func finishStep() -> VariantDictionary { job.take() ?? VariantDictionary() }

    /// Aufsummierte Zeit, die der Hauptthread auf Hintergrund-Schritte
    /// gewartet hat (ms), Messgröße für `docs/perf-measurements.md` §L: im
    /// Zeitraffer soll sie nicht wachsen.
    @Callable func stepWaitMilliseconds() -> Double { job.waitedSeconds * 1000 }

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
            // `.replaced` erledigt alles: die Δ-Karte zeigt ab jetzt, was
            // die Sim tut (nicht die Differenz zur alten Welt), Fluss-Bänder
            // bauen im nächsten Frame neu, der Wald vergisst sein Gedächtnis.
            // Dieselbe Politik wie beim Generieren — Begründung an
            // `RenderState.invalidate`.
            render.invalidate(terrain, .replaced)
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
    @Callable func currentYear() -> Double { terrain.years }

    /// Zur Bauzeit eingebrannter Stempel der Quellen (Extension/Sources +
    /// SimCore/Sources, Verfahren: scripts/build-stamp.sh). Godot lädt die Library
    /// aus game/bin/ blind; smoke.gd vergleicht diesen Stempel mit dem
    /// Arbeitsverzeichnis und bricht bei einer veralteten .so laut ab, statt sie
    /// still zu benutzen (real passiert: "Nonexistent function brush").
    @Callable func buildStamp() -> String { BuildStamp.value }

    // MARK: Felder (row-major, Länge n*n)

    @Callable func heights() -> PackedFloat32Array { Self.pack(terrain.h) }

    /// Höhenfeld als ROHE float32-Bytes — direkt als R32F-Textur hochladbar.
    /// GDScript hat vorher `heights().to_byte_array()` gerechnet: dieselben
    /// Bytes, aber eine zusätzliche ~2,7-MB-Kopie je Textur-Update (Issue #53).
    @Callable func heightsBytes() -> PackedByteArray { Self.packBytes(terrain.h) }

    // Rendering bekommt den ratenbegrenzten SEESPIEGEL statt hf: Priority-Flood
    // springt beim Sill-Zuschütten instantan → hüpfende Seeflächen (s. Terrain.waterLevel).
    @Callable func filled() -> PackedFloat32Array { Self.pack(terrain.waterLevel) }

    /// Seespiegel als rohe float32-Bytes — Begründung wie bei `heightsBytes`.
    @Callable func filledBytes() -> PackedByteArray { Self.packBytes(terrain.waterLevel) }

    /// Aktuelle Höhenbänder (Issue #4) als
    /// `[vegFull, vegNone, rockStart, rockFull, snowStart, snowFull, coniferLow, coniferHigh]`.
    /// Sie kommen aus dem Sim-Kern (Perzentile der Landhöhen) — der Shader und die
    /// Diagnose lesen sie hier ab, statt eigene absolute Schwellen zu führen.
    /// **Ausnahme seit Issue #33:** `snowStart`/`snowFull` sind keine Perzentile
    /// mehr, sondern aus dem Schneefeld zurückgerechnet (s. `HeightBands`). An der
    /// Reihenfolge und Bedeutung der Werte ändert das nichts.
    @Callable func heightBands() -> PackedFloat32Array { Self.packBands(terrain.heightBands) }

    private static func packBands(_ b: HeightBands) -> PackedFloat32Array {
        PackedFloat32Array([
            Float(b.vegFull), Float(b.vegNone), Float(b.rockStart), Float(b.rockFull),
            Float(b.snowStart), Float(b.snowFull), Float(b.coniferLow), Float(b.coniferHigh),
        ])
    }

    @Callable func flowArea() -> PackedFloat32Array { Self.pack(terrain.area) }

    /// Abfluss-Nachbar je Zelle (-1 = Senke/Meer) — für Fluss-Geometrie.
    @Callable func receivers() -> PackedInt32Array { PackedInt32Array(terrain.receiver) }

    // MARK: Diagnose (Kennzahlen und Δ-Karte: `TerrainDiagnostics`)

    /// Setzt den Vergleichspunkt der Diagnose auf den aktuellen Zustand.
    @Callable func captureDebugReference() { render.captureDebugReference(terrain) }

    /// Kompakter Diagnosevertrag für GDScript — Reihenfolge und Bedeutung der
    /// Werte: `TerrainDiagnostics.stats`.
    @Callable func debugTerrainStats() -> PackedFloat32Array {
        PackedFloat32Array(render.debugTerrainStats(terrain))
    }

    /// Δ-Karte gegen den Vergleichspunkt (blau = abgetragen, rot = aufgebaut).
    @Callable func heightDifferenceBytes(scale: Double) -> PackedByteArray {
        PackedByteArray(render.heightDifferenceBytes(terrain, scale: scale))
    }

    // MARK: Frame-Protokoll (Issue #94)

    /// Die Puffer eines Frames — Reihenfolge und Drosseln: `RenderState.frame`.
    /// `trigger` = Rohwert von `FrameTrigger` (`FRAME_*` in `Main.gd`), `now` =
    /// `Time.get_ticks_msec() / 1000`. Schlüssel: s. `packFrame`.
    @Callable func renderFrame(trigger: Int, now: Double) -> VariantDictionary {
        guard let frameTrigger = Self.frameTrigger(trigger, "renderFrame") else {
            return VariantDictionary()
        }
        let frame = render.frame(terrain, frameTrigger, now: now)
        return Self.packFrame(frame, frameTrigger, heights: terrain.h, year: terrain.years,
                              waterLevel: terrain.waterLevel, bands: terrain.heightBands,
                              ribbons: render.riverRibbonMesh)
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
    ///   (Seespiegel, R32F) und `bands` (Höhenbänder wie `heightBands`),
    /// - nach einem Band-Bau: `ribbons` plus das Mesh in `ribbon_verts`,
    ///   `ribbon_colors`, `ribbon_uvs`, `ribbon_uv2s`, `ribbon_indices`.
    /// Fehlende Schlüssel heißen „in diesem Frame nicht neu".
    private static func packFrame(_ frame: RenderFrame, _ trigger: FrameTrigger,
                                  heights: [Double], year: Double, waterLevel: [Double],
                                  bands: HeightBands, ribbons: RibbonMesh) -> VariantDictionary {
        let out = VariantDictionary()
        out[Variant("trigger")] = Variant(trigger.rawValue)
        out[Variant("year")] = Variant(year)
        out[Variant("heights")] = packBytes(heights).toVariant()
        if let o = frame.overlays {
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
            out[Variant("filled")] = packBytes(waterLevel).toVariant()
            out[Variant("bands")] = packBands(bands).toVariant()
        }
        if frame.ribbonsRebuilt {
            out[Variant("ribbons")] = Variant(true)
            out[Variant("ribbon_verts")] = ribbonVerts(ribbons).toVariant()
            out[Variant("ribbon_colors")] = ribbonColors(ribbons).toVariant()
            out[Variant("ribbon_uvs")] = ribbonUVs(ribbons).toVariant()
            out[Variant("ribbon_uv2s")] = ribbonUV2s(ribbons).toVariant()
            out[Variant("ribbon_indices")] = PackedInt32Array(ribbons.indices).toVariant()
        }
        return out
    }

    /// `RS_WATER_GPU`: Frames liefern das rohe Wasserfeld, Blur/EWMA laufen in
    /// der GPU-Kette von `Main.gd`.
    @Callable func setDeferWaterTail(enabled: Bool) { render.deferWaterTail = enabled }

    // MARK: Render-Buffer (in Swift berechnet → GDScript setzt nur zusammen)

    /// Großräumige Biom-/Höhen-Farbe als RGBA8-Puffer. Die eigentlichen
    /// Materialgewichte kommen getrennt aus `terrainSurfaceBytes`.
    @Callable func terrainColorBytes() -> PackedByteArray {
        PackedByteArray(render.terrainColorBytes(terrain))
    }

    /// R = Vegetation, G = freier Fels, B = Schnee/Eis,
    /// A = Lithologie-Härte. Beide Puffer werden gemeinsam berechnet.
    @Callable func terrainSurfaceBytes() -> PackedByteArray {
        PackedByteArray(render.terrainSurfaceBytes(terrain))
    }

    /// Bodenbedeckung (Issue #174 D): R = Schutthalde, G = blankes Gletschereis,
    /// B = Rohboden, A = Talboden-Wiese. Gemeinsam mit den beiden Puffern oben
    /// berechnet.
    @Callable func terrainCoverBytes() -> PackedByteArray {
        PackedByteArray(render.terrainCoverBytes(terrain))
    }

    /// Wie `waterFieldBytes`, aber ohne Blur/EWMA/Glättung: die erledigt der
    /// GPU-Pass in `Main.gd` (`game/shaders/water_field_*.gdshader`). Gleiches
    /// Kanal-Layout, gleiche Kalibrierung — nur die letzten 4,3 ms des Passes
    /// bleiben liegen. Kein `blend`-Argument: der Mischfaktor ist GPU-seitig ein
    /// Uniform.
    @Callable func waterFieldRawBytes() -> PackedByteArray {
        PackedByteArray(render.waterFieldBytes(terrain, blend: 1.0, deferTail: true))
    }

    /// Wasser-Feld (Flüsse/Seen/Altarme) als RGBA8-Byte-Buffer — Kanäle und
    /// Kalibrierung: `WaterFieldRenderer`. `blend` glättet zeitlich (1 = Sprung
    /// sofort übernehmen).
    ///
    /// Kanal-Kopplung und Legacy-A/B (`RS_WATER_STAMP`) liegen im Zustand:
    /// `RenderState` kennt das Bau-Ergebnis der Bänder selbst.
    @Callable func waterFieldBytes(blend: Double) -> PackedByteArray {
        PackedByteArray(render.waterFieldBytes(terrain, blend: blend))
    }

    /// Abfluss-Dichte fürs Shader-Detail als R8-Byte-Buffer (n×n) — Kalibrierung
    /// und Begründung: `WaterRender.flowDetailIntensity`.
    @Callable func flowDetailBytes() -> PackedByteArray {
        PackedByteArray(render.flowDetailBytes(terrain))
    }

    /// Schutzmaske für Kronendach und Render-Verschiebung als R8-Byte-Buffer (n×n, Issue #154).
    /// Sperrt Wasserflächen (sichtbares Rasterwasser + gebaute Flussbänder + Saum ~2 Zellen).
    @Callable func protectMaskBytes() -> PackedByteArray {
        PackedByteArray(render.protectMaskBytes(terrain))
    }

    /// Waldmaske des Kronendachs als R8-Byte-Buffer (n×n, Issue #152) — s.
    /// `ForestCanopyMask`. Endet an der Schutzmaske.
    @Callable func forestMaskBytes() -> PackedByteArray {
        PackedByteArray(render.forestMaskBytes(terrain))
    }

    // MARK: Wasser-Kalibrierung über die Brücke (Issues #91/#92)

    // Die Tabellen (Namen + Werte) leben godot-frei in `SimRender.WaterUniforms`;
    // hier werden sie nur als Packed*Arrays verpackt. `Main.gd` setzt die
    // Uniform-Werte beim Aufbau auf alle Wasser-Materialien — Namen und Werte
    // sind paarweise über den Index verknüpft. Die Double→Float32-Verengung ist
    // verlustfrei genug: GLSL-Uniform-Floats sind ohnehin einfach genau.

    @Callable func waterScalarUniformNames() -> PackedStringArray {
        PackedStringArray(WaterUniforms.scalars.map(\.name))
    }

    @Callable func waterScalarUniformValues() -> PackedFloat32Array {
        PackedFloat32Array(WaterUniforms.scalars.map { Float($0.value) })
    }

    @Callable func waterColorUniformNames() -> PackedStringArray {
        PackedStringArray(WaterUniforms.colors.map(\.name))
    }

    @Callable func waterColorUniformValues() -> PackedVector3Array {
        PackedVector3Array(WaterUniforms.colors.map {
            Vector3(x: Float($0.value.r), y: Float($0.value.g), z: Float($0.value.b))
        })
    }

    // MARK: Kalibrierung der Render-Verschiebung (Issue #153)

    // Tabelle in `SimRender.ReliefUniforms`; `Main.gd` setzt die Werte auf den
    // Back-Pass und das Terrain-Material und dekodiert damit die Backtextur
    // für Pinselring und Kameraziel.

    @Callable func reliefUniformNames() -> PackedStringArray {
        PackedStringArray(ReliefUniforms.scalars.map(\.name))
    }

    @Callable func reliefUniformValues() -> PackedFloat32Array {
        PackedFloat32Array(ReliefUniforms.scalars.map { Float($0.value) })
    }

    // MARK: Kalibrierung des Kronendachs (Issue #152)

    // Tabelle in `SimRender.CanopyUniforms`; `Main.gd` setzt die Werte auf das
    // Terrain-Material.

    @Callable func canopyUniformNames() -> PackedStringArray {
        PackedStringArray(CanopyUniforms.scalars.map(\.name))
    }

    @Callable func canopyUniformValues() -> PackedFloat32Array {
        PackedFloat32Array(CanopyUniforms.scalars.map { Float($0.value) })
    }

    // MARK: Material-Kalibrierung (Issue #174 D)

    // Tabelle in `SimRender.MaterialUniforms`; `Main.gd` setzt die Werte auf das
    // Terrain-Material.

    @Callable func materialUniformNames() -> PackedStringArray {
        PackedStringArray(MaterialUniforms.scalars.map(\.name))
    }

    @Callable func materialUniformValues() -> PackedFloat32Array {
        PackedFloat32Array(MaterialUniforms.scalars.map { Float($0.value) })
    }

    // Vertragswerte der Godot-Wächter (`water_geometry.gd`, `river_ribbons.gd`,
    // Issue #92) — als Float64, damit die GDScript-Seite exakt die Doubles der
    // Kalibrierung vergleicht statt einer verengten Kopie.

    @Callable func waterContractNames() -> PackedStringArray {
        PackedStringArray(WaterUniforms.contract.map(\.name))
    }

    @Callable func waterContractValues() -> PackedFloat64Array {
        PackedFloat64Array(WaterUniforms.contract.map(\.value))
    }

    // MARK: Sculpting

    /// Hebt (dir > 0) oder senkt (dir < 0) das Terrain in einem Pinsel um
    /// Gitterzentrum (gx, gz) mit Radius in Welteinheiten. Koppelt in die Tektonik.
    @Callable func sculpt(gx: Double, gz: Double, radiusWorld: Double, dir: Double) {
        terrain.sculpt(gx: gx, gz: gz, radiusWorld: radiusWorld, dir: dir)
        render.invalidate(terrain, .edited)
    }

    /// Pinsel-Werkzeug mit Stärke. `mode` ist der Rohwert von `BrushTool` — die
    /// Werkzeug-Tabelle in `Main.gd` hält dieselbe Reihenfolge (Issue #53).
    @Callable func brush(mode: Int, gx: Double, gz: Double, radiusWorld: Double,
                         strength: Double, target: Double) {
        guard let tool = BrushTool(rawValue: mode) else {
            // Laut statt still: ein unbekannter Modus hieß vorher „nichts tun",
            // ein Werkzeug ohne Wirkung sah im Spiel wie ein Physik-Bug aus.
            GD.pushError("brush: unbekannter Modus \(mode) — Werkzeug-Tabelle (Main.gd) "
                         + "und BrushTool sind auseinandergelaufen")
            return
        }
        tool.apply(to: terrain, gx: gx, gz: gz, radiusWorld: radiusWorld,
                   strength: strength, target: target)
        render.invalidate(terrain, .edited)
    }

    /// Nach Sculpting/Änderungen Entwässerung neu berechnen (für Live-Flüsse).
    /// WELCHE Pässe in welcher Reihenfolge dazugehören, steht seit Issue #93
    /// bei ihrem Besitzer: `Terrain.recomputeFlowAfterEdit`.
    @Callable func recomputeFlow() {
        terrain.recomputeFlowAfterEdit()
        render.invalidate(terrain, .edited)
    }

    /// Effektive Maximal-Breite der Spitzhacke (Welteinheiten) — fürs Ring-Visual.
    @Callable func pickaxeMaxRadiusWorld() -> Double {
        Terrain.pickaxeMaxCells * terrain.cfg.cellSize
    }

    // MARK: Wasser-Geometrie (Band-Puffer — s. `RiverRibbonRenderer`)

    @Callable func riversMaxDelta() -> Double { render.riversMaxDelta(terrain) }

    @Callable func markRiversBuilt() { render.markRiversBuilt(terrain) }

    /// Baut die Bänder der Mäander-Hauptläufe, Delta-Arme und Altarme.
    /// `hscale` = Render-Überhöhung, `lift` = Anhebung über Gelände (Welt-Y).
    @Callable func buildRiverRibbons(hscale: Double, lift: Double) {
        render.buildRiverRibbons(terrain, hscale: hscale, lift: lift)
    }

    /// Meldet die Auflösung des Terrain-Render-Gitters (Main.gd `terrain_grid`),
    /// damit die Land-Bänder ihre Höhen von der SICHTBAREN Oberfläche sampeln
    /// (`renderSurfaceHeight`) statt von den Sim-Höhen. Ohne Aufruf gilt volle
    /// Auflösung — die Headless-Wächter bleiben damit unverändert.
    @Callable func setRenderGrid(grid: Int) {
        render.renderGrid = grid
    }

    @Callable func riverRibbonVerts() -> PackedVector3Array { Self.ribbonVerts(render.riverRibbonMesh) }
    @Callable func riverRibbonColors() -> PackedColorArray { Self.ribbonColors(render.riverRibbonMesh) }
    @Callable func riverRibbonUVs() -> PackedVector2Array { Self.ribbonUVs(render.riverRibbonMesh) }
    /// Typ-Kanal des Vertex-Vertrags (UV2.x = `WaterRender.ribbonKind*`):
    /// Fluss / Delta-Arm / Altarm. Der Shader färbt und animiert danach.
    @Callable func riverRibbonUV2s() -> PackedVector2Array { Self.ribbonUV2s(render.riverRibbonMesh) }

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
    @Callable func riverRibbonIndices() -> PackedInt32Array {
        PackedInt32Array(render.riverRibbonMesh.indices)
    }
    /// Vertex-Index je Band-Anfang — für die Wächter (`game/tests`).
    @Callable func riverRibbonStripStarts() -> PackedInt32Array {
        PackedInt32Array(render.riverRibbonMesh.stripStarts)
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
