import XCTest

/// Wächter für das Zeitraffer-Überblenden (Issue #172): jede Textur mit
/// Vorgängerstand blendet über die Blende IHRES Uploads.
///
/// Zwei Takte: die Höhe kommt jeden Sim-Takt (`_upload_heights`), alles
/// Gedrosselte mit den Overlays (`_upload_overlays`, RenderState.frame).
/// Eine Textur an der Blende des anderen Takts springt an jedem Upload des
/// fremden Takts auf ihren alten Stand zurück; genau so pumpte der Wald an
/// `bake_blend` (#170). Nicht ausführbar (Shader, GDScript), deshalb als
/// Quelltext-Probe; das Verhalten bei Pinsel, Sprung und Laden prüfen die
/// Godot-Vertragstests.
final class TimelapseFadeTests: XCTestCase {

    /// Feld → (Lese-Helfer im Terrain-Shader, Blende, Upload-Funktion in Main.gd).
    private static let fields: [(tex: String, helper: String, blend: String, fade: String)] = [
        ("height_tex", "height_at", "height_blend", "height_fade"),
        ("hf_tex", "hf_at", "overlay_blend", "overlay_fade"),
        ("color_tex", "color_at", "overlay_blend", "overlay_fade"),
        ("surface_tex", "surface_at", "overlay_blend", "overlay_fade"),
        ("cover_tex", "cover_at", "overlay_blend", "overlay_fade"),
        ("flow_tex", "flow_at", "overlay_blend", "overlay_fade"),
        // Raster-Wasser (#174): die EWMA glättet nur von Upload zu Upload.
        ("water_tex", "water_at", "overlay_blend", "overlay_fade"),
    ]

    func testTerrainShaderReadsEveryFieldThroughItsBlend() throws {
        let shader = try RepoSource.probe("game/shaders/terrain.gdshader")
        for f in Self.fields {
            let prev = f.tex.replacingOccurrences(of: "_tex", with: "_prev_tex")
            assertContains(shader, "uniform sampler2D \(prev)",
                           hint: "\(f.tex) braucht seinen Vorgängerstand")
            assertContains(shader, "mix(texture(\(prev), uv)",
                           hint: "\(f.helper) mischt den Vorgängerstand")
            XCTAssertEqual(shader.count(of: "texture(\(f.tex),"), 1,
                           "\(f.tex) nur im Helfer \(f.helper) lesen, sonst zeigen Form, "
                           + "Normalen und Farbe verschiedene Zwischenstände")
            XCTAssertTrue(try shader.captures(pattern: "\(f.helper)\\(vec2 uv\\) \\{([^}]*)\\}")
                .contains { $0.contains(f.blend) && !$0.contains(f.blend == "height_blend"
                                                                   ? "overlay_blend" : "height_blend") },
                          "\(f.helper) muss über \(f.blend) blenden")
        }
        assertContains(shader,
                       "v_forest = mix(textureLod(forest_prev_tex, uv, 0.0).r, v_forest, overlay_blend);",
                       hint: "Die Waldmaske kommt mit den Overlays und blendet mit ihnen")
        XCTAssertFalse(shader.contains("forest_prev_tex, uv, 0.0).r, v_forest, bake_blend"),
                       "Wald an der Blende der Verschiebung pumpt (#170)")
    }

    func testOceanCoastFollowsTheBlendedHeight() throws {
        let ocean = try RepoSource.probe("game/shaders/ocean.gdshader")
        assertContains(ocean, "h = mix(texture(height_prev_tex, terrain_uv).r, h, height_blend);",
                       hint: "Die Küstenlinie folgt derselben Zwischenhöhe wie das Terrain")
    }

    func testMainStartsEachFadeWithItsOwnUpload() throws {
        let main = try RepoSource.probe("game/scripts/Main.gd")
        for f in Self.fields {
            assertContains(main, "FieldTexture.new(\"\(f.tex)\", ",
                           hint: "\(f.tex) ist ein FieldTexture")
            XCTAssertTrue(try main.captures(pattern: "FieldTexture\\.new\\(\"\(f.tex)\", [A-Za-z_.0-9]+, (true)\\)")
                .count == 1, "\(f.tex) muss seinen Vorgängerstand halten (keeps_previous)")
        }
        assertContains(main, "func _upload_heights() -> void:\n\theight_fade.start(",
                       hint: "Die Höhen-Blende startet mit dem Höhen-Upload")
        assertContains(main, "func _upload_overlays(frame: Dictionary) -> void:\n\toverlay_fade.start(",
                       hint: "Die Overlay-Blende startet mit dem Overlay-Upload")
        assertContains(main, "height_fade.bind(ocean_mat)", hint: "Auch das Meer blendet die Höhe")
        assertContains(main, "terrain_mat.set_shader_parameter(\"water_prev_tex\", wf_state_vp[previous].get_texture())",
                       hint: "RS_WATER_GPU: Vorgängerstand ist das andere Ping-Pong-Ziel")
    }
}
