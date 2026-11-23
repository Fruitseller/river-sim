import Foundation
import XCTest

@testable import SimCore
@testable import SimRender

final class BackgroundJobTests: XCTestCase {

    func testResultIsTakenExactlyOnce() {
        let job = BackgroundJob<Int>(label: "test.once")
        XCTAssertFalse(job.isPending)
        XCTAssertNil(job.take(), "Ohne Job gibt es nichts abzuholen")
        XCTAssertTrue(job.start { 42 })
        XCTAssertTrue(job.isPending)
        XCTAssertEqual(job.take(), 42)
        XCTAssertFalse(job.isPending, "Nach dem Abholen ist kein Job mehr unterwegs")
        XCTAssertNil(job.take())
    }

    func testStartRefusesWhileAJobIsPending() {
        let job = BackgroundJob<Int>(label: "test.refuse")
        let gate = DispatchSemaphore(value: 0)
        XCTAssertTrue(job.start { gate.wait(); return 1 })
        XCTAssertFalse(job.start { 2 }, "Zweiter Start, während der erste rechnet")
        gate.signal()
        job.wait()
        XCTAssertTrue(job.isReady)
        XCTAssertFalse(job.start { 3 }, "Zweiter Start, während das Ergebnis liegt")
        XCTAssertEqual(job.take(), 1, "Das erste Ergebnis bleibt unberührt")
        XCTAssertTrue(job.start { 4 })
        XCTAssertEqual(job.take(), 4)
    }

    func testReadinessNeverBlocksAndOnlyRealWaitsCount() {
        let job = BackgroundJob<Int>(label: "test.ready")
        job.wait()
        XCTAssertEqual(job.waits, 0, "Ohne Job wartet niemand")
        let gate = DispatchSemaphore(value: 0)
        XCTAssertTrue(job.start { gate.wait(); return 7 })
        for _ in 0..<100 {
            XCTAssertFalse(job.isReady, "Der Job ist am Tor blockiert")
        }
        XCTAssertEqual(job.waits, 0, "isReady hat gewartet")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { gate.signal() }
        job.wait()
        XCTAssertEqual(job.waits, 1)
        XCTAssertGreaterThan(job.waitedSeconds, 0.02, "Die Wartezeit wird gemessen")
        XCTAssertTrue(job.isReady)
        job.wait()
        XCTAssertEqual(job.waits, 1, "Auf einen fertigen Job wartet niemand")
        XCTAssertEqual(job.take(), 7)
    }

    func testWaitPublishesTheJobsWrites() {
        final class Box { var values = [Int](repeating: 0, count: 4096); var thread = "" }
        let box = Box()
        let job = BackgroundJob<Void>(label: "test.publish")
        let caller = Thread.current
        XCTAssertTrue(job.start {
            box.thread = Thread.current == caller ? "caller" : "worker"
            usleep(20_000)
            for k in box.values.indices { box.values[k] = k * 3 }
        })
        job.wait()
        XCTAssertEqual(box.thread, "worker", "Der Job muss im Hintergrund laufen")
        XCTAssertTrue(box.values.enumerated().allSatisfy { $0.element == $0.offset * 3 })
        XCTAssertNotNil(job.take())
    }

    func testMainNeverWaitsInTheTimelapseAndSettlesBeforeTouchingTheWorld() throws {
        let main = try RepoSource.probe("game/scripts/Main.gd")
        let functions = Self.gdFunctions(main.code)

        let process = try XCTUnwrap(functions["_process"])
        XCTAssertTrue(process.contains("sim.beginStep("), "Zeitraffer beginnt Hintergrund-Schritte")
        XCTAssertTrue(process.contains("if sim.stepReady():"), "Abholen nur, wenn fertig")
        XCTAssertTrue(process.contains("not sim.stepInFlight()"), "Ein Schritt zur Zeit")
        for blocking in ["sim.step(", "sim.renderFrame(", "_render_frame("] {
            XCTAssertFalse(process.contains(blocking),
                           "_process ruft \(blocking) — der Zeitraffer wartet dann wieder")
        }
        XCTAssertEqual(main.count(of: "sim.finishStep()"), 2,
                       "Abgeholt wird nur in _process (wenn fertig) und in _settle_sim")

        let settle = try XCTUnwrap(functions["_settle_sim"])
        XCTAssertTrue(settle.contains("if sim.stepInFlight():")
                      && settle.contains("_apply_step(sim.finishStep())"),
                      "_settle_sim wartet ab UND lädt hoch")

        let worldCalls = ["sim.step(", "sim.brush(", "sim.generate(", "sim.loadWorld(",
                          "sim.saveWorld(", "sim.recomputeFlow(", "sim.captureDebugReference(",
                          "sim.renderFrame(", "sim.flowArea(", "sim.receivers(",
                          "sim.debugTerrainStats(", "sim.heightDifferenceBytes("]
        let exempt: [String: String] = [
            "_ready": "Aufbau, vor dem ersten _process",
            "_update_debug_ui": "nur aus _refresh_debug",
            "_update_debug_difference_texture": "nur aus _refresh_debug",
        ]
        let guards: [String: String] = ["_process": "if sculpting and not sim.stepInFlight():"]
        for (name, body) in functions where exempt[name] == nil {
            guard let first = worldCalls.compactMap({ body.range(of: $0)?.lowerBound }).min() else {
                continue
            }
            let guardText = guards[name] ?? "_settle_sim()"
            let settled = body.range(of: guardText).map { $0.lowerBound < first } ?? false
            XCTAssertTrue(settled, "\(name) fasst die Welt an, ohne vorher \(guardText) — "
                          + "ein laufender Hintergrund-Schritt käme sonst danach an")
        }
        for helper in ["_update_debug_ui", "_update_debug_difference_texture"] {
            let callers = functions.filter { $0.key != helper && $0.value.contains("\(helper)(") }
                .map(\.key)
            XCTAssertEqual(callers, ["_refresh_debug"],
                           "\(helper) darf nur aus _refresh_debug gerufen werden (holt ab)")
        }
    }

    private static func gdFunctions(_ code: String) -> [String: String] {
        var result: [String: String] = [:]
        var current: String?
        var body = ""
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            var header = line
            if header.hasPrefix("static ") { header = header.dropFirst("static ".count) }
            if header.hasPrefix("func ") {
                if let open = current { result[open] = body }
                let name = header.dropFirst("func ".count).prefix { $0 != "(" }
                current = String(name)
                body = ""
            } else if !line.isEmpty, !line.hasPrefix("\t"), !line.hasPrefix(" "), current != nil {
                result[current!] = body
                current = nil
            }
            if current != nil { body += line + "\n" }
        }
        if let open = current { result[open] = body }
        return result
    }
}
