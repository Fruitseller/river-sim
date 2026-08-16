import Foundation
import SwiftGodot
import SimCore

/// GDExtension-Brücke: hält den reinen `SimCore.Terrain` und reicht seine Felder
/// als Packed*Array an Godot. Alle @Callable-Methoden sind aus GDScript aufrufbar.
///
/// Bewusst dünn (PLAN.md §1): die gesamte Physik lebt in SimCore (headless
/// getestet), die Render-AUFBEREITUNG in eigenen Modulen daneben
/// (`WaterFieldRenderer`, `RiverRibbonRenderer`, `TerrainColorRenderer`,
/// `TreeInstanceRenderer`, `TerrainDiagnostics` — Issue #53). Hier passiert nur
/// Marshalling Swift → Godot: Aufruf weiterreichen, Ergebnis als Packed*Array
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

    // Render-Aufbereitung (Issue #53). Alle vier halten reinen RENDER-Zustand
    // (EWMA-Felder, Arbeitspuffer, Dirty-Snapshots) und keine Physik; sie lesen
    // das Terrain, sie ändern es nie.
    private let waterField = WaterFieldRenderer()
    private let ribbons = RiverRibbonRenderer()
    private let trees = TreeInstanceRenderer()
    private let diagnostics = TerrainDiagnostics()

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
            // Bäume neu bauen lassen (leerer Vergleichsstand ⇒ treeVegMaxDelta = 1)
            // und Fluss-Ribbons ebenso (riversMaxDelta ⇒ „riesig").
            trees.invalidateSnapshot()
            ribbons.invalidateSnapshot()
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
    @Callable func captureDebugReference() { diagnostics.capture(terrain) }

    /// Kompakter Diagnosevertrag für GDScript — Reihenfolge und Bedeutung der
    /// Werte: `TerrainDiagnostics.stats`.
    @Callable func debugTerrainStats() -> PackedFloat32Array { diagnostics.stats(terrain) }

    /// Δ-Karte gegen den Vergleichspunkt (blau = abgetragen, rot = aufgebaut).
    @Callable func heightDifferenceBytes(scale: Double) -> PackedByteArray {
        diagnostics.differenceBytes(terrain, scale: scale)
    }

    // MARK: Render-Buffer (in Swift berechnet → GDScript setzt nur zusammen)

    /// Biom-/Höhen-Färbung als RGBA8-Byte-Buffer (n*n*4) — s. `TerrainColorRenderer`.
    @Callable func terrainColorBytes() -> PackedByteArray { TerrainColorRenderer.bytes(terrain) }

    /// Wasser-Feld (Flüsse/Seen/Altarme) als RGBA8-Byte-Buffer — Kanäle und
    /// Kalibrierung: `WaterFieldRenderer`. `blend` glättet zeitlich (1 = Sprung
    /// sofort übernehmen).
    @Callable func waterFieldBytes(blend: Double) -> PackedByteArray {
        // `bandChannelFlags` koppelt die beiden Wasser-Pfade über das echte
        // Bau-Ergebnis: nur Kanäle MIT Band werden im Feld zum Saum gedeckelt.
        waterField.bytes(terrain, blend: blend, geometryMode: SimNode.waterGeometryEnabled,
                         bandChannelFlags: ribbons.bandChannelFlags)
    }

    /// Legacy-A/B ohne Rebuild (Muster `RS_NO_MEANDER_PAINT`): gesetzt = der
    /// alte Stempel-Pfad malt Mäander und Altarme wieder voll ins Wasserfeld,
    /// und es entsteht keine Band-Geometrie. Standard ist seit #34 die
    /// Geometrie; der Schalter existiert nur noch für den A/B-Vergleich.
    /// `Main.gd` liest dieselbe Variable und baut dann kein Ribbon-Mesh.
    private static var waterGeometryEnabled: Bool {
        ProcessInfo.processInfo.environment["RS_WATER_STAMP"] == nil
    }

    // MARK: Sculpting

    /// Hebt (dir > 0) oder senkt (dir < 0) das Terrain in einem Pinsel um
    /// Gitterzentrum (gx, gz) mit Radius in Welteinheiten. Koppelt in die Tektonik.
    @Callable func sculpt(gx: Double, gz: Double, radiusWorld: Double, dir: Double) {
        terrain.sculpt(gx: gx, gz: gz, radiusWorld: radiusWorld, dir: dir)
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
    }

    /// Nach Sculpting/Änderungen Entwässerung neu berechnen (für Live-Flüsse).
    /// Seespiegel snappt mit: Spieler-Feedback soll instantan sein, nur die
    /// Sim-Dynamik (Plug/Breach am Auslass) ist träge.
    @Callable func recomputeFlow() {
        terrain.computeFlow()
        terrain.snapWaterLevel()
        // Temperatur (Issue #33) mitziehen: sie hängt direkt an der Höhe, ein
        // Strich muss sie im selben Frame verschieben. `dt = 0` lässt die
        // Schnee-BILANZ exakt unverändert (e⁰ = 1) — die ist Zustand und darf
        // nicht am Pinsel hängen, sondern nur an der Sim-Zeit.
        terrain.updateClimate(dt: 0)
        // Höhenbänder (Issue #4) mitziehen: ein Sculpt-Strich verschiebt die
        // Landhöhen-Verteilung, und die Färbung liest sie im selben Frame.
        terrain.updateHeightBands()
    }

    /// Effektive Maximal-Breite der Spitzhacke (Welteinheiten) — fürs Ring-Visual.
    @Callable func pickaxeMaxRadiusWorld() -> Double {
        Terrain.pickaxeMaxCells * terrain.cfg.cellSize
    }

    // MARK: Baum-Instanzen (MultiMesh-Puffer — s. `TreeInstanceRenderer`)

    @Callable func treeVegMaxDelta() -> Double { trees.maxDelta(terrain) }

    @Callable func markTreesBuilt() { trees.markBuilt(terrain) }

    @Callable func treeInstanceBuffer(variant: Int, hscale: Double,
                                      coverage: Int) -> PackedFloat32Array {
        trees.buffer(terrain, variant: variant, hscale: hscale, coverage: coverage)
    }

    // MARK: Wasser-Geometrie (Band-Puffer — s. `RiverRibbonRenderer`)

    @Callable func riversMaxDelta() -> Double { ribbons.maxDelta(terrain) }

    @Callable func markRiversBuilt() { ribbons.markBuilt(terrain) }

    /// Baut die Bänder der Mäander-Hauptläufe, Delta-Arme und Altarme.
    /// `hscale` = Render-Überhöhung, `lift` = Anhebung über Gelände (Welt-Y).
    @Callable func buildRiverRibbons(hscale: Double, lift: Double) {
        ribbons.build(terrain, hscale: hscale, lift: lift)
    }

    /// Meldet die Auflösung des Terrain-Render-Gitters (Main.gd `terrain_grid`),
    /// damit die Land-Bänder ihre Höhen von der SICHTBAREN Oberfläche sampeln
    /// (`renderSurfaceHeight`) statt von den Sim-Höhen. Ohne Aufruf gilt volle
    /// Auflösung — die Headless-Wächter bleiben damit unverändert.
    @Callable func setRenderGrid(grid: Int) {
        ribbons.renderGrid = grid
    }

    @Callable func riverRibbonVerts() -> PackedVector3Array { ribbons.verts }
    @Callable func riverRibbonColors() -> PackedColorArray { ribbons.colors }
    @Callable func riverRibbonUVs() -> PackedVector2Array { ribbons.uvs }
    /// Typ-Kanal des Vertex-Vertrags (UV2.x = `WaterRender.ribbonKind*`):
    /// Fluss / Delta-Arm / Altarm. Der Shader färbt und animiert danach.
    @Callable func riverRibbonUV2s() -> PackedVector2Array { ribbons.uv2s }
    @Callable func riverRibbonIndices() -> PackedInt32Array { ribbons.indices }
    /// Vertex-Index je Band-Anfang — für die Wächter (`game/tests`).
    @Callable func riverRibbonStripStarts() -> PackedInt32Array { ribbons.stripStarts }

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
