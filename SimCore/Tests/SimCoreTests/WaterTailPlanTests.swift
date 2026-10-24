import XCTest
import SimRender

/// Wächter für den Pass-Plan des GPU-Wasser-Schwanzes (Issue #95): die
/// Struktur der Kette — Kanal-Masken, Pass-Zahlen, Priming — steht als DATEN
/// in `SimRender.WaterTailPlan` (dieselbe Quelle, aus der der CPU-Pfad seine
/// Pass-Zahlen nimmt) und reist über die Brücke nach GDScript. Die beiden
/// Rechen-Shader und die Kette (`WaterGpuTail.gd`) halten keine eigene
/// Kalibrierzahl; die AUSFÜHRBARE Deckung (CPU gegen GPU, Priming,
/// Framerate-Unabhängigkeit) leistet der Godot-Vertragstest
/// `game/tests/water_gpu_tail.gd`.
final class WaterTailPlanTests: XCTestCase {

    // MARK: Werte (Vertrag)

    /// Die Werte sind bewusst gepinnt wie die übrigen Render-Kalibrierungen:
    /// wer sie ändert, ändert CPU-Pfad und GPU-Kette bewusst ZUSAMMEN, und
    /// `WaterRender.protectSeamCells` (Saum der Schutzmaske) hängt an
    /// `lakeBlurPasses`.
    func testPlanValues() {
        // Ein Pass für den Fluss-Kanal: mehr verbreiterte auch den Kern
        // (Begründung am Plan).
        XCTAssertEqual(WaterTailPlan.streamBlurPasses, 1)
        // Zwei Pässe für den See-Kanal: der Ufersaum unter der rawWet-Schwelle
        // muss überdeckt werden; der Saum der Schutzmaske deckt genau diese
        // zwei Pässe (WaterRenderTests.testProtectMaskReadsVisibilityFromTheShaderWindows).
        XCTAssertEqual(WaterTailPlan.lakeBlurPasses, 2)
        XCTAssertEqual(WaterTailPlan.blurPassCount, 2)
        // Masken je Pass (R, G): erster Pass beide Kanäle, danach nur der
        // See-Kanal — flach für die Brücke.
        XCTAssertEqual(WaterTailPlan.blurMasks(), [1.0, 1.0, 0.0, 1.0])
        // 1.0 = erstes Feld sofort übernehmen; die CPU erreicht dieselbe Regel
        // über den Aufrufer (blend 1.0 bei nicht-timelapse Auslösern).
        XCTAssertEqual(WaterTailPlan.primeBlend, 1.0)
    }

    // MARK: CPU-Pfad liest den Plan

    func testCpuPathReadsItsPassesFromThePlan() throws {
        let renderer = try RepoSource.probe("SimCore/Sources/SimRender/WaterFieldRenderer.swift")
        assertContains(renderer, "blurMax(&sd, passes: WaterTailPlan.streamBlurPasses)",
                       hint: "Der CPU-Pfad nimmt seine Fluss-Blur-Pässe aus dem Plan (#95)")
        assertContains(renderer, "blurMax(&lk, passes: WaterTailPlan.lakeBlurPasses)",
                       hint: "Der CPU-Pfad nimmt seine See-Blur-Pässe aus dem Plan (#95)")
    }

    // MARK: Brücke (dünnes Marshalling)

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

    // MARK: Rechen-Shader bleiben kalibrierfrei

    func testComputeShadersStayDefaultFree() throws {
        // Ein Literal-Default wäre die Kopie der Struktur — dasselbe Verfahren
        // wie bei den water_*-Uniforms seit #92. Der Wert reist über die
        // Brücke bzw. je Tick aus dem Frame-Protokoll.
        let blur = try RepoSource.probe("game/shaders/water_field_blur.gdshader")
        assertContains(blur, "uniform vec2 blur_channels;",
                       hint: "Kanal-Maske default-frei deklariert (#95)")
        let ewma = try RepoSource.probe("game/shaders/water_field_ewma.gdshader")
        assertContains(ewma, "uniform float blend : hint_range(0.0, 1.0);",
                       hint: "Blende default-frei deklariert (#95); hint_range ist die "
                             + "Wertemenge einer Blende, keine Kalibrier-Zahl")
    }

    // MARK: Die Kette liest den Plan über die Brücke

    func testChainReadsThePlanOverTheBridge() throws {
        let tail = try RepoSource.probe("game/scripts/WaterGpuTail.gd")
        for needle in ["waterTailBlurPassCount()", "waterTailBlurMasks()",
                       "waterTailPrimeBlend()"] {
            assertContains(tail, needle,
                           hint: "Die GPU-Kette baut sich aus den Brücken-Daten (#95)")
        }
        XCTAssertFalse(tail.contains("Vector2(1.0, 1.0)"),
                       "Die Kanal-Maske stünde wieder als Literal in der Kette (#95)")
        // Main verdrahtet die beiden Ping-Pong-Ziele weiterhin selbst (welche
        // Materialien das Feld lesen, weiß die Kette nicht).
        let main = try RepoSource.probe("game/scripts/Main.gd")
        assertContains(main, "water_gpu_tail.previous_texture()",
                       hint: "Main verdrahtet den Vorgängerstand über die Kette")
        assertContains(main, "water_gpu_tail.current_texture()",
                       hint: "Main verdrahtet den Zustand über die Kette")
    }
}
