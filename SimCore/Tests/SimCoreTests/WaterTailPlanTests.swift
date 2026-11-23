import XCTest
import SimRender

final class WaterTailPlanTests: XCTestCase {

    func testPlanValues() {
        XCTAssertEqual(WaterTailPlan.streamBlurPasses, 1)
        XCTAssertEqual(WaterTailPlan.lakeBlurPasses, 2)
        XCTAssertEqual(WaterTailPlan.blurPassCount, 2)
        XCTAssertEqual(WaterTailPlan.blurMasks(), [1.0, 1.0, 0.0, 1.0])
        XCTAssertEqual(WaterTailPlan.primeBlend, 1.0)
    }

    func testCpuPathReadsItsPassesFromThePlan() throws {
        let renderer = try RepoSource.probe("SimCore/Sources/SimRender/WaterFieldRenderer.swift")
        assertContains(renderer, "blurMax(&sd, passes: WaterTailPlan.streamBlurPasses)",
                       hint: "Der CPU-Pfad nimmt seine Fluss-Blur-Pässe aus dem Plan (#95)")
        assertContains(renderer, "blurMax(&lk, passes: WaterTailPlan.lakeBlurPasses)",
                       hint: "Der CPU-Pfad nimmt seine See-Blur-Pässe aus dem Plan (#95)")
    }

    func testBridgeMarshalsThePlan() throws {
        let bridge = try RepoSource.extensionSources()
        for needle in ["func waterTailBlurPassCount", "func waterTailBlurMasks",
                       "func waterTailPrimeBlend"] {
            assertContains(bridge, needle,
                           hint: "Die Brücke reicht den Pass-Plan als Callable-Daten")
        }
        assertContains(bridge, "WaterTailPlan.blurPassCount",
                       hint: "Pass-Zahl kommt aus dem Plan, nicht als Brücken-Literal")
        assertContains(bridge, "WaterTailPlan.blurMasks()",
                       hint: "Masken kommen aus dem Plan, nicht als Brücken-Literal")
        assertContains(bridge, "WaterTailPlan.primeBlend",
                       hint: "Priming kommt aus dem Plan, nicht als Brücken-Literal")
    }

    func testComputeShadersStayDefaultFree() throws {
        let blur = try RepoSource.probe("game/shaders/water_field_blur.gdshader")
        assertContains(blur, "uniform vec2 blur_channels;",
                       hint: "Kanal-Maske default-frei deklariert (#95)")
        let ewma = try RepoSource.probe("game/shaders/water_field_ewma.gdshader")
        assertContains(ewma, "uniform float blend : hint_range(0.0, 1.0);",
                       hint: "Blende default-frei deklariert (#95); hint_range ist die "
                             + "Wertemenge einer Blende, keine Kalibrier-Zahl")
    }

    func testChainReadsThePlanOverTheBridge() throws {
        let tail = try RepoSource.probe("game/scripts/WaterGpuTail.gd")
        for needle in ["waterTailBlurPassCount()", "waterTailBlurMasks()",
                       "waterTailPrimeBlend()"] {
            assertContains(tail, needle,
                           hint: "Die GPU-Kette baut sich aus den Brücken-Daten (#95)")
        }
        XCTAssertFalse(tail.contains("Vector2(1.0, 1.0)"),
                       "Die Kanal-Maske stünde wieder als Literal in der Kette (#95)")
        let main = try RepoSource.probe("game/scripts/Main.gd")
        assertContains(main, "water_gpu_tail.previous_texture()",
                       hint: "Main verdrahtet den Vorgängerstand über die Kette")
        assertContains(main, "water_gpu_tail.current_texture()",
                       hint: "Main verdrahtet den Zustand über die Kette")
    }
}
