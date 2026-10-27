import Foundation
import SimCore

/// Die Welt-Sitzung (Issue #212): besitzt die Welt (`Terrain`), ihren
/// Render-Zustand (`RenderState`) und den Hintergrund-Job des Zeitraffers
/// (`BackgroundJob`). Die GDExtension (`SimNode`) hält nur noch diese Sitzung
/// und verpackt ihre Ergebnisse in `Packed*Array`.
///
/// Die Regel der Brücke steht damit genau EINMAL, hier:
/// - Jeder Zugriff wartet zuerst einen laufenden Hintergrund-Schritt ab
///   (`world`/`render` unten). Sein Ergebnis bleibt liegen: abholen muss der
///   Aufrufer (`finishStep`), sonst zeigte Godot einen anderen Stand als den,
///   den `RenderState` für sichtbar hält.
/// - Jede Weltänderung meldet die passende `TerrainChange` (`change`). Eine
///   Änderung ohne Invalidierung lässt sich nicht schreiben: die Welt verlässt
///   die Sitzung nie, nach außen gibt es nur die benannten Änderungen und
///   gelesene Werte.
///
/// Bis #212 stand beides an jeder Methode der Brücke, geprüft nur per
/// Quelltext-Grep und ausführbar nur in CI. Jetzt prüft es
/// `SimCoreTests/WorldSessionTests.swift` headless.
///
/// `Packed` ist die Form, in der ein Frame die Sitzung verlässt (in Godot das
/// fertige Frame-Dictionary): der Hintergrund-Job verpackt selbst, damit der
/// Hauptthread nur noch hochlädt. Die Sitzung bleibt dadurch godot-frei.
///
/// Vertrag wie `BackgroundJob`: EIN Besitzer-Thread (in Godot der
/// Hauptthread) ruft alle Methoden.
public final class WorldSession<Packed> {
    /// Angefasst nur über `world` (s. dort); direkt nur in `beginStep`, das
    /// sie dem Job übergibt, und in `load`, das sie nach dem Abwarten ersetzt.
    private var storedWorld: Terrain
    private let storedRender: RenderState
    private let job: BackgroundJob<Packed>

    /// Alle Brücken-Wege fahren den Produktions-Einlauf selbst
    /// (`settleYears`), Testwelten nicht; deshalb ist er ein Argument.
    public init(config: SimConfig, seed: UInt32, settleYears: Double = 0,
                render: RenderState = RenderState()) {
        storedWorld = Terrain(config: config, seed: seed, settleYears: settleYears)
        storedRender = render
        job = BackgroundJob(label: "river-sim.step")
    }

    /// Ein laufender Job darf seine Sitzung nicht überleben: beim Beenden
    /// entlädt Godot danach die Library, deren Code er gerade ausführt.
    deinit {
        job.wait()
    }

    /// DER Zugang zur Welt: wartet zuerst einen laufenden Hintergrund-Schritt
    /// ab. Ohne laufenden Job kostet das eine Sperre.
    private var world: Terrain {
        job.wait()
        return storedWorld
    }

    /// Wie `world`, für den Render-Zustand.
    private var render: RenderState {
        job.wait()
        return storedRender
    }

    /// Zuletzt gemeldete Art der Änderung, für die Wächter. Gehört wie die
    /// Welt dem Job, solange er rechnet.
    private var storedLastChange: TerrainChange?
    var lastChange: TerrainChange? {
        job.wait()
        return storedLastChange
    }

    /// DER Abschluss jeder Weltänderung.
    private func change(_ kind: TerrainChange) {
        invalidate(world, render, kind)
    }

    /// Die eine Stelle, an der eine Änderung den Render-Zustand erreicht —
    /// auch für den Hintergrund-Schritt, der am Tor vorbei arbeiten muss.
    private func invalidate(_ terrain: Terrain, _ render: RenderState, _ kind: TerrainChange) {
        render.invalidate(terrain, kind)
        storedLastChange = kind
    }

    // MARK: - Weltänderungen

    public func generate(seed: UInt32, settleYears: Double = 0) {
        world.generate(seed: seed, settleYears: settleYears)
        change(.replaced)
    }

    public func step(years: Double) {
        world.step(dtYears: years)
        change(.advanced)
    }

    /// Hebt (dir > 0) oder senkt (dir < 0) das Terrain im Pinsel um (gx, gz).
    public func sculpt(gx: Double, gz: Double, radiusWorld: Double, dir: Double) {
        world.sculpt(gx: gx, gz: gz, radiusWorld: radiusWorld, dir: dir)
        change(.edited)
    }

    public func brush(_ tool: BrushTool, gx: Double, gz: Double, radiusWorld: Double,
                      strength: Double, target: Double) {
        tool.apply(to: world, gx: gx, gz: gz, radiusWorld: radiusWorld,
                   strength: strength, target: target)
        change(.edited)
    }

    /// Nachzug nach einem Pinselstrich: `Terrain.recomputeFlowAfterEdit`.
    public func recomputeFlow() {
        world.recomputeFlowAfterEdit()
        change(.edited)
    }

    /// Lädt eine Welt aus `path` und ERSETZT die aktuelle (die Datei bringt
    /// ihre eigene Config mit, Issue #8). Im Fehlerfall bleibt alles, wie es
    /// war. Bei Erfolg ist der Zustand sofort vollständig (Seespiegel,
    /// Höhenbänder, Flüsse).
    public func load(from path: String) throws {
        let loaded = try WorldSnapshot.read(from: path)
        job.wait()
        storedWorld = loaded
        // `.replaced` erledigt alles: die Δ-Karte zeigt ab jetzt, was die Sim
        // tut (nicht die Differenz zur alten Welt), Fluss-Bänder bauen im
        // nächsten Frame neu, der Wald vergisst sein Gedächtnis. Dieselbe
        // Politik wie beim Generieren — Begründung an `RenderState.invalidate`.
        change(.replaced)
    }

    /// Schreibt die Welt nach `path`; Rückgabe: geschriebene Byte.
    public func save(to path: String) throws -> Int {
        try WorldSnapshot.write(world, to: path)
    }

    // MARK: - Hintergrund-Schritt (Zeitraffer)

    /// Startet `step(years)` und danach den Frame `trigger` (wie
    /// `renderFrame`) auf einem Hintergrund-Thread und kehrt sofort zurück;
    /// `pack` verpackt den Frame noch dort. Abholen: `stepReady` fragt, ohne
    /// zu blockieren, `finishStep` liefert das Ergebnis.
    ///
    /// Bis zum Abholen ist der Schritt UNTERWEGS (`stepInFlight`). Ein Start,
    /// solange einer unterwegs ist, ist ein Fehler und startet nichts
    /// (Rückgabe `false`): das liegende Ergebnis ginge sonst verloren, und mit
    /// ihm etwa ein Band-Bau, den der Render-Zustand schon für ausgeliefert
    /// hält.
    ///
    /// Determinismus: der Job rechnet genau `step` + `renderFrame`, nur auf
    /// einem anderen Thread, und niemand sonst fasst die Welt dabei an.
    @discardableResult
    public func beginStep(years: Double, trigger: FrameTrigger, now: Double,
                          pack: @escaping (WorldFrame) -> Packed) -> Bool {
        guard !job.isPending else { return false }
        // Ohne Job unterwegs gehören Welt und Render-Zustand ab hier dem Job.
        let terrain = storedWorld, render = storedRender
        return job.start { [self] in
            terrain.step(dtYears: years)
            invalidate(terrain, render, .advanced)
            return pack(Self.frame(terrain, render, trigger, now: now))
        }
    }

    /// Ist ein Hintergrund-Schritt unterwegs (rechnet oder wartet aufs Abholen)?
    public var stepInFlight: Bool { job.isPending }

    /// Ist der Hintergrund-Schritt fertig? Blockiert nie.
    public var stepReady: Bool { job.isReady }

    /// Holt das Ergebnis des Hintergrund-Schritts ab (wartet, falls er noch
    /// rechnet). `nil` = es war keiner unterwegs.
    public func finishStep() -> Packed? { job.take() }

    /// Wie lange (Sekunden) der Besitzer-Thread auf Hintergrund-Schritte
    /// gewartet hat (`docs/perf-measurements.md` §L); wie oft, für die Wächter.
    public var stepWaitedSeconds: Double { job.waitedSeconds }
    var stepWaits: Int { job.waits }

    // MARK: - Frame (Issue #94)

    /// Die Puffer eines Frames — Reihenfolge und Drosseln: `RenderState.frame`.
    public func renderFrame(_ trigger: FrameTrigger, now: Double) -> WorldFrame {
        Self.frame(world, render, trigger, now: now)
    }

    /// Für `renderFrame` (Besitzer-Thread) und `beginStep` (Hintergrund)
    /// derselbe Weg.
    private static func frame(_ terrain: Terrain, _ render: RenderState,
                              _ trigger: FrameTrigger, now: Double) -> WorldFrame {
        let frame = render.frame(terrain, trigger, now: now)
        return WorldFrame(frame: frame, trigger: trigger, heights: terrain.h,
                          year: terrain.years, waterLevel: terrain.waterLevel,
                          bands: terrain.heightBands, ribbons: render.riverRibbonMesh)
    }

    // MARK: - Lesen

    public var config: SimConfig { world.cfg }
    public var year: Double { world.years }
    public var heights: [Double] { world.h }
    /// Der ratenbegrenzte SEESPIEGEL, nicht `hf` (s. `Terrain.waterLevel`).
    public var waterLevel: [Double] { world.waterLevel }
    public var heightBands: HeightBands { world.heightBands }
    public var flowArea: [Double] { world.area }
    public var receivers: [Int32] { world.receiver }
    /// Fingerabdruck des kompletten Zustands-Inventars, für die Wächter.
    func fingerprint() -> UInt64 { world.fingerprint() }
    /// Effektive Maximal-Breite der Spitzhacke (Welteinheiten).
    public var pickaxeMaxRadiusWorld: Double { Terrain.pickaxeMaxCells * world.cfg.cellSize }

    // MARK: - Render-Zustand (liest die Welt, ändert sie nie)

    public func captureDebugReference() { render.captureDebugReference(world) }
    public func debugTerrainStats() -> [Float] { render.debugTerrainStats(world) }
    public func heightDifferenceBytes(scale: Double) -> [UInt8] {
        render.heightDifferenceBytes(world, scale: scale)
    }

    public var deferWaterTail: Bool {
        get { render.deferWaterTail }
        set { render.deferWaterTail = newValue }
    }

    /// Auflösung des Terrain-Render-Gitters (s. `RenderState.renderGrid`).
    public var renderGrid: Int {
        get { render.renderGrid }
        set { render.renderGrid = newValue }
    }

    public func terrainColorBytes() -> [UInt8] { render.terrainColorBytes(world) }
    public func terrainSurfaceBytes() -> [UInt8] { render.terrainSurfaceBytes(world) }
    public func terrainCoverBytes() -> [UInt8] { render.terrainCoverBytes(world) }
    public func waterFieldBytes(blend: Double, deferTail: Bool = false) -> [UInt8] {
        render.waterFieldBytes(world, blend: blend, deferTail: deferTail)
    }
    public func flowDetailBytes() -> [UInt8] { render.flowDetailBytes(world) }
    public func protectMaskBytes() -> [UInt8] { render.protectMaskBytes(world) }
    public func forestMaskBytes() -> [UInt8] { render.forestMaskBytes(world) }

    public func riversMaxDelta() -> Double { render.riversMaxDelta(world) }
    public func markRiversBuilt() { render.markRiversBuilt(world) }
    public func buildRiverRibbons(hscale: Double, lift: Double) {
        render.buildRiverRibbons(world, hscale: hscale, lift: lift)
    }
    public var riverRibbonMesh: RibbonMesh { render.riverRibbonMesh }
}

/// Ein Frame samt der Welt-Werte, die er mitnimmt (Höhe, Jahr, Seespiegel,
/// Höhenbänder, Band-Mesh) — godot-frei; die Brücke verpackt ihn
/// (`SimNode.packFrame`).
public struct WorldFrame {
    public let frame: RenderFrame
    public let trigger: FrameTrigger
    public let heights: [Double]
    public let year: Double
    public let waterLevel: [Double]
    public let bands: HeightBands
    public let ribbons: RibbonMesh
}
