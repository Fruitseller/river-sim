import Foundation
import XCTest

@testable import SimCore
@testable import SimRender

/// Wächter der Welt-Sitzung (Issue #212): die Regel der Brücke, ausgeführt
/// statt per Quelltext-Grep. Bis #212 stand sie an jeder Methode von
/// `SimNode` und war nur in CI ausführbar geprüft.
///
/// - Jede Weltänderung meldet die passende `TerrainChange`, und danach liefert
///   der Render-Zustand den frischen Stand.
/// - Ein laufender Hintergrund-Schritt wird vor jedem Lese- und
///   Schreibzugriff abgewartet.
/// - Im Zeitraffer läuft höchstens ein Schritt zur Zeit.
/// - Hintergrund-Schritte sind bit-gleich zu synchronen.
final class WorldSessionTests: XCTestCase {

    private func session(seed: UInt32 = 1337) -> WorldSession<WorldFrame> {
        WorldSession(config: renderConfig(), seed: seed, render: RenderState(geometryMode: true))
    }

    // MARK: - Art der Änderung

    /// Je Änderungsart kommt genau die `TerrainChange` an, die das
    /// Gedächtnis der Render-Pässe braucht (Issue #167: ein Pinsel als
    /// `.advanced` ließe veralteten Wald stehen, ein Sim-Schritt als `.edited`
    /// schaltete das Gedächtnis ab), und danach liefert der Material-Cache den
    /// Stand der JETZIGEN Welt.
    func testEveryChangeReportsItsKindAndLeavesFreshMaterials() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("world-session-\(UUID().uuidString).\(WorldSnapshot.fileExtension)")
            .path
        _ = try WorldSnapshot.write(Terrain(config: renderConfig(), seed: 4711), to: path)
        defer { try? FileManager.default.removeItem(atPath: path) }

        // `prepare` läuft VOR dem Warmlaufen des Caches: so prüft der Fall nur
        // die Invalidierung seines eigenen Einstiegs.
        let changes: [(name: String, kind: TerrainChange,
                       prepare: (WorldSession<WorldFrame>) -> Void,
                       apply: (WorldSession<WorldFrame>) throws -> Void)] = [
            ("generate", .replaced, { _ in }, { $0.generate(seed: 4711) }),
            ("load", .replaced, { _ in }, { try $0.load(from: path) }),
            ("step", .advanced, { _ in }, { $0.step(years: 200) }),
            ("beginStep", .advanced, { _ in }, { session in
                XCTAssertTrue(session.beginStep(years: 200, trigger: .timelapse, now: 0) { $0 })
                XCTAssertNotNil(session.finishStep())
            }),
            ("sculpt", .edited, { _ in }, { $0.sculpt(gx: 48, gz: 48, radiusWorld: 14, dir: 1) }),
            ("brush", .edited, { _ in }, {
                $0.brush(.flatten, gx: 48, gz: 48, radiusWorld: 14, strength: 1, target: 0.6)
            }),
            ("recomputeFlow", .edited, { session in
                session.sculpt(gx: 30, gz: 60, radiusWorld: 14, dir: -1)
                session.step(years: 1)   // eine andere Art davor, damit `.edited` neu ankommt
            }, { $0.recomputeFlow() }),
        ]
        for (name, kind, prepare, apply) in changes {
            let world = session()
            prepare(world)
            let stale = world.terrainColorBytes()   // Cache warmlaufen
            try apply(world)
            XCTAssertEqual(world.lastChange, kind, "\(name) meldet die falsche Art")
            XCTAssertNotEqual(world.terrainColorBytes(), stale,
                              "\(name): Farb-Cache steht noch auf dem alten Stand")
            XCTAssertNotEqual(world.terrainSurfaceBytes(), [],
                              "\(name): Material-Cache leer")
        }
    }

    /// Ein fehlgeschlagenes Laden lässt Welt und Render-Zustand stehen.
    func testFailedLoadLeavesTheWorldUntouched() {
        let world = session()
        world.step(years: 50)
        let year = world.year
        XCTAssertThrowsError(try world.load(from: "/nonexistent/\(UUID().uuidString)"))
        XCTAssertEqual(world.year, year)
        XCTAssertEqual(world.lastChange, .advanced)
    }

    // MARK: - Abwarten

    /// Jeder Zugriff wartet einen RECHNENDEN Schritt ab und sieht danach
    /// dessen Ergebnis. Der Job hält hier an einer Schranke, bis der Zugriff
    /// sicher begonnen hat; ohne Abwarten läse er die alte Welt.
    func testAccessWaitsForTheRunningStep() {
        let accesses: [(name: String, access: (WorldSession<WorldFrame>) -> Void)] = [
            ("year", { _ = $0.year }),
            ("heights", { _ = $0.heights }),
            ("renderFrame", { _ = $0.renderFrame(.settled, now: 1) }),
            ("terrainColorBytes", { _ = $0.terrainColorBytes() }),
            ("step", { $0.step(years: 1) }),
            ("brush", { $0.brush(.raise, gx: 48, gz: 48, radiusWorld: 4, strength: 1, target: 0) }),
            ("generate", { $0.generate(seed: 7) }),
        ]
        for (name, access) in accesses {
            let world = session()
            let before = world.year
            let gate = DispatchSemaphore(value: 0)
            XCTAssertTrue(world.beginStep(years: 100, trigger: .timelapse, now: 0) { frame in
                gate.wait()
                return frame
            })
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { gate.signal() }
            access(world)
            XCTAssertEqual(world.stepWaits, 1, "\(name) wartet den Schritt nicht ab")
            XCTAssertTrue(world.stepReady, "\(name): danach ist der Schritt fertig")
            let frame = world.finishStep()
            XCTAssertEqual(frame?.year, before + 100, "\(name): Ergebnis bleibt liegen")
        }
    }

    // MARK: - Ein Schritt zur Zeit

    /// Solange ein Schritt unterwegs ist (auch fertig, aber nicht abgeholt),
    /// startet `beginStep` nichts: der liegende Frame ginge sonst verloren.
    func testOnlyOneStepRunsAtATime() throws {
        let world = session()
        let before = world.year
        XCTAssertFalse(world.stepInFlight)
        XCTAssertTrue(world.beginStep(years: 10, trigger: .timelapse, now: 0) { $0 })
        XCTAssertTrue(world.stepInFlight)
        XCTAssertFalse(world.beginStep(years: 1000, trigger: .timelapse, now: 0) { $0 },
                       "zweiter Start, während der erste rechnet")
        _ = world.year   // wartet ab, holt nicht ab
        XCTAssertTrue(world.stepInFlight, "Abwarten ist kein Abholen")
        XCTAssertFalse(world.beginStep(years: 1000, trigger: .timelapse, now: 0) { $0 },
                       "zweiter Start, während der erste aufs Abholen wartet")
        let frame = try XCTUnwrap(world.finishStep())
        XCTAssertEqual(frame.year, before + 10)
        XCTAssertEqual(world.year, before + 10, "der abgewiesene Start hat nichts gerechnet")
        XCTAssertFalse(world.stepInFlight)
        XCTAssertNil(world.finishStep(), "Ergebnis genau einmal")
    }

    // MARK: - Determinismus

    /// Dieselbe Folge von Schritten über `beginStep` ergibt bit-gleich dieselbe
    /// Welt und dieselben Frames wie `step` + `renderFrame` — auch mit einem
    /// Pinselstrich zwischen zwei Schritten, den `Main.gd` erst nach dem
    /// Abholen setzt (`_settle_sim`).
    func testBackgroundStepsAreBitIdenticalToSynchronousSteps() throws {
        let sync = session(), background = session()
        for world in [sync, background] {
            for _ in 0..<2 { world.step(years: 1000) }
            world.recomputeFlow()
        }
        XCTAssertEqual(sync.fingerprint(), background.fingerprint())

        var now = 0.0
        for (index, years) in [15.0, 15.0, 240.0, 15.0, 60.0, 15.0].enumerated() {
            now += 0.35
            if index == 3 {
                // Pinsel zwischen zwei Schritten: erst abgeholt, dann gemalt.
                for world in [sync, background] {
                    world.brush(.raise, gx: 48, gz: 48, radiusWorld: 4, strength: 1, target: 0)
                    world.recomputeFlow()
                }
            }
            sync.step(years: years)
            let expected = sync.renderFrame(.timelapse, now: now)
            XCTAssertTrue(background.beginStep(years: years, trigger: .timelapse, now: now) { $0 })
            let got = try XCTUnwrap(background.finishStep())

            XCTAssertEqual(background.fingerprint(), sync.fingerprint(),
                           "Welt nach Schritt \(index) weicht ab")
            XCTAssertEqual(got.heights, expected.heights)
            XCTAssertEqual(got.year, expected.year)
            XCTAssertEqual(got.frame.ribbonsRebuilt, expected.frame.ribbonsRebuilt)
            XCTAssertEqual(got.frame.overlays == nil, expected.frame.overlays == nil)
            if let a = got.frame.overlays, let b = expected.frame.overlays {
                XCTAssertEqual(a.water, b.water, "Wasserfeld nach Schritt \(index)")
                XCTAssertEqual(a.colors, b.colors)
                XCTAssertEqual(a.surfaces, b.surfaces)
                XCTAssertEqual(a.covers, b.covers)
                XCTAssertEqual(a.flowDetail, b.flowDetail)
                XCTAssertEqual(a.protectMask, b.protectMask)
                XCTAssertEqual(a.forestMask, b.forestMask)
                XCTAssertEqual(a.plume, b.plume)
            }
            XCTAssertEqual(got.ribbons.vertices, expected.ribbons.vertices)
        }
    }

    // MARK: - Quelltext: die Brücke fasst nur die Sitzung an

    /// Der Strukturrest der früheren Brücken-Wächter: `SimNode` hält weder
    /// Welt noch Render-Zustand noch Job selbst und ruft die Sitzung. Abwarten
    /// und Invalidierung prüfen die Verhaltenstests oben.
    func testBridgeTouchesOnlyTheSession() throws {
        let bridge = try RepoSource.probe("\(RepoSource.extensionDirectory)/SimNode.swift")
        for owned in ["Terrain", "RenderState", "BackgroundJob", "TerrainChange"] {
            XCTAssertEqual(bridge.count(ofIdentifier: owned), 0,
                           "SimNode fasst `\(owned)` wieder selbst an — das gehört in "
                           + "`WorldSession` (Issue #212)")
        }
        for bypass in ["WorldSnapshot.read(", "WorldSnapshot.write(", ".apply(to:"] {
            XCTAssertFalse(bridge.contains(bypass),
                           "SimNode ändert oder liest die Welt an der Sitzung vorbei: `\(bypass)`")
        }
        assertContains(bridge, "WorldSession<VariantDictionary>(",
                       hint: "SimNode hält die Sitzung")
    }
}
