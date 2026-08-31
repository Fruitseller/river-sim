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
    private static func productionConfig() -> SimConfig {
        var config = SimConfig()
        config.hydraulicSkipWaterSpawns = true
        config.meanderSpatialCutoffIndex = true
        return config
    }

    /// `var`, weil ein geladener Spielstand seine EIGENE Config mitbringt
    /// (Issue #8): die Datei-Config ist autoritativ, also wird das Terrain beim
    /// Laden ersetzt statt in-place überschrieben.
    private var terrain = Terrain(config: SimNode.productionConfig(),
                                  seed: RenderContract.defaultSeed)
    private var lastWorldBytes = 0

    /// Der gesamte Render-Zustand (die Renderer mit ihren EWMA-Feldern,
    /// Arbeitspuffern und Dirty-Snapshots plus der Material-Cache) liegt seit
    /// Issue #93 in `SimRender`. Die Brücke hält davon nichts mehr selbst und
    /// meldet nach JEDER Terrain-Änderung `render.invalidate` — den einen
    /// Einstieg dort.
    private let render = RenderState()

    // MARK: Steuerung

    @Callable func generate(seed: Int) {
        terrain.generate(seed: UInt32(truncatingIfNeeded: seed))
        render.invalidate(terrain, worldReplaced: true)
    }

    @Callable func step(years: Double) {
        terrain.step(dtYears: years)
        render.invalidate(terrain)
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
            // `worldReplaced` erledigt beides: die Δ-Karte zeigt ab jetzt, was
            // die Sim tut (nicht die Differenz zur alten Welt), und Bäume wie
            // Fluss-Bänder bauen im nächsten Frame neu. Dieselbe Politik wie
            // beim Generieren — Begründung an `RenderState.invalidate`.
            render.invalidate(terrain, worldReplaced: true)
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

    @Callable func heights() -> PackedFloat32Array { pack(terrain.h) }

    /// Höhenfeld als ROHE float32-Bytes — direkt als R32F-Textur hochladbar.
    /// GDScript hat vorher `heights().to_byte_array()` gerechnet: dieselben
    /// Bytes, aber eine zusätzliche ~2,7-MB-Kopie je Textur-Update (Issue #53).
    @Callable func heightsBytes() -> PackedByteArray { packBytes(terrain.h) }

    // Rendering bekommt den ratenbegrenzten SEESPIEGEL statt hf: Priority-Flood
    // springt beim Sill-Zuschütten instantan → hüpfende Seeflächen (s. Terrain.waterLevel).
    @Callable func filled() -> PackedFloat32Array { pack(terrain.waterLevel) }

    /// Seespiegel als rohe float32-Bytes — Begründung wie bei `heightsBytes`.
    @Callable func filledBytes() -> PackedByteArray { packBytes(terrain.waterLevel) }

    /// Aktuelle Höhenbänder (Issue #4) als
    /// `[vegFull, vegNone, rockStart, rockFull, snowStart, snowFull, coniferLow, coniferHigh]`.
    /// Sie kommen aus dem Sim-Kern (Perzentile der Landhöhen) — der Shader und die
    /// Diagnose lesen sie hier ab, statt eigene absolute Schwellen zu führen.
    /// **Ausnahme seit Issue #33:** `snowStart`/`snowFull` sind keine Perzentile
    /// mehr, sondern aus dem Schneefeld zurückgerechnet (s. `HeightBands`). An der
    /// Reihenfolge und Bedeutung der Werte ändert das nichts.
    @Callable func heightBands() -> PackedFloat32Array {
        let b = terrain.heightBands
        return PackedFloat32Array([
            Float(b.vegFull), Float(b.vegNone), Float(b.rockStart), Float(b.rockFull),
            Float(b.snowStart), Float(b.snowFull), Float(b.coniferLow), Float(b.coniferHigh),
        ])
    }

    @Callable func flowArea() -> PackedFloat32Array { pack(terrain.area) }

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

    // MARK: Wasser-Kalibrierung über die Brücke (Issue #91)

    // Die Tabelle (Namen + Werte) lebt godot-frei in `SimRender.WaterUniforms`;
    // hier wird sie nur als Packed*Arrays verpackt. `Main.gd` setzt die Werte
    // beim Aufbau auf alle Wasser-Materialien — Namen und Werte sind paarweise
    // über den Index verknüpft. Die Double→Float32-Verengung ist verlustfrei
    // genug: GLSL-Uniform-Floats sind ohnehin einfach genau, und der Vergleich
    // Uniform-Default ↔ Brückenwert läuft in `water_uniforms.gd` mit Toleranz.

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

    // MARK: Sculpting

    /// Hebt (dir > 0) oder senkt (dir < 0) das Terrain in einem Pinsel um
    /// Gitterzentrum (gx, gz) mit Radius in Welteinheiten. Koppelt in die Tektonik.
    @Callable func sculpt(gx: Double, gz: Double, radiusWorld: Double, dir: Double) {
        terrain.sculpt(gx: gx, gz: gz, radiusWorld: radiusWorld, dir: dir)
        render.invalidate(terrain)
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
        render.invalidate(terrain)
    }

    /// Nach Sculpting/Änderungen Entwässerung neu berechnen (für Live-Flüsse).
    /// WELCHE Pässe in welcher Reihenfolge dazugehören, steht seit Issue #93
    /// bei ihrem Besitzer: `Terrain.recomputeFlowAfterEdit`.
    @Callable func recomputeFlow() {
        terrain.recomputeFlowAfterEdit()
        render.invalidate(terrain)
    }

    /// Effektive Maximal-Breite der Spitzhacke (Welteinheiten) — fürs Ring-Visual.
    @Callable func pickaxeMaxRadiusWorld() -> Double {
        Terrain.pickaxeMaxCells * terrain.cfg.cellSize
    }

    // MARK: Baum-Instanzen (MultiMesh-Puffer — s. `TreeInstanceRenderer`)

    @Callable func treeVegMaxDelta() -> Double { render.treeVegMaxDelta(terrain) }

    @Callable func markTreesBuilt() { render.markTreesBuilt(terrain) }

    @Callable func treeInstanceBuffer(variant: Int, hscale: Double,
                                      coverage: Int) -> PackedFloat32Array {
        PackedFloat32Array(
            render.treeInstanceBuffer(terrain, variant: variant, hscale: hscale,
                                      coverage: coverage)
        )
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

    @Callable func riverRibbonVerts() -> PackedVector3Array {
        PackedVector3Array(render.riverRibbonMesh.vertices.map {
            Vector3(x: $0.x, y: $0.y, z: $0.z)
        })
    }
    @Callable func riverRibbonColors() -> PackedColorArray {
        PackedColorArray(render.riverRibbonMesh.colors.map {
            Color(r: $0.x, g: $0.y, b: $0.z, a: $0.w)
        })
    }
    @Callable func riverRibbonUVs() -> PackedVector2Array {
        PackedVector2Array(render.riverRibbonMesh.uvs.map { Vector2(x: $0.x, y: $0.y) })
    }
    /// Typ-Kanal des Vertex-Vertrags (UV2.x = `WaterRender.ribbonKind*`):
    /// Fluss / Delta-Arm / Altarm. Der Shader färbt und animiert danach.
    @Callable func riverRibbonUV2s() -> PackedVector2Array {
        PackedVector2Array(render.riverRibbonMesh.uv2s.map { Vector2(x: $0.x, y: $0.y) })
    }
    @Callable func riverRibbonIndices() -> PackedInt32Array {
        PackedInt32Array(render.riverRibbonMesh.indices)
    }
    /// Vertex-Index je Band-Anfang — für die Wächter (`game/tests`).
    @Callable func riverRibbonStripStarts() -> PackedInt32Array {
        PackedInt32Array(render.riverRibbonMesh.stripStarts)
    }

    // MARK: Marshalling

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

    /// Wie `pack`, aber als rohe float32-Bytes: Godot kann sie direkt als R32F-
    /// Bilddaten übernehmen (`Image.set_data`), ohne dass GDScript das
    /// Float-Array noch einmal konvertieren muss.
    private func packBytes(_ a: [Double]) -> PackedByteArray {
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
