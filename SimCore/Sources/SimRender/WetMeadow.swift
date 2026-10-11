import SimCore

/// Nasse Wiese statt Tümpel-Teppich (Issue #174, Paket C): die Zellen kleiner
/// See-Komponenten, die `WaterFieldRenderer` nicht mehr als Wasserspiegel malt
/// (`wetMeadow`), bekommen im Material dunkles Grün.
///
/// Eigener Schritt NACH `TerrainColorRenderer` statt darin, weil die Maske aus
/// dem Wasserfeld kommt und nicht aus dem Terrain: `RenderState` kennt beide
/// und wendet sie hier an. Kalibrierung: `WaterRender.wetMeadow*`. Wald und
/// Render-Verschiebung hält die Schutzmaske von der nassen Wiese fern
/// (`WaterProtectMask`), sonst stünde auf dem hohen Vegetationsgewicht Wald.
public enum WetMeadow {

    /// Die Materialpuffer mit nasser Wiese auf `mask` (n×n). Passt die Maske
    /// nicht oder ist sie leer, bleiben die Puffer unverändert.
    public static func apply(_ buffers: TerrainColorRenderer.Buffers,
                             mask: [Bool]) -> TerrainColorRenderer.Buffers {
        let cnt = buffers.surfaces.count / 4
        guard mask.count == cnt, buffers.colors.count == cnt * 4,
              mask.contains(true) else { return buffers }
        var colors = buffers.colors, surfaces = buffers.surfaces
        let veg = WaterRender.wetMeadowVegetation
        let tint = WaterRender.wetMeadowColor, mix = WaterRender.wetMeadowColorMix
        for k in 0..<cnt where mask[k] {
            let o = k * 4
            // Hierarchie wie im TerrainColorRenderer: Kälte bleibt, Vegetation
            // wächst unter ihr, Fels schaut nur durch, was übrig bleibt.
            // Nur geänderte Gewichte neu quantisieren: Byte → Double → Byte
            // rundet sonst unveränderte Werte um eine Stufe ab.
            let cold = Double(surfaces[o + 2]) / 255
            let target = veg * (1 - cold)
            if target > Double(surfaces[o]) / 255 { surfaces[o] = byte01(target) }
            let free = 1 - cold - Double(surfaces[o]) / 255
            if Double(surfaces[o + 1]) / 255 > free { surfaces[o + 1] = byte01(max(0, free)) }
            colors[o] = byte01(Double(colors[o]) / 255 * (1 - mix) + tint.r * mix)
            colors[o + 1] = byte01(Double(colors[o + 1]) / 255 * (1 - mix) + tint.g * mix)
            colors[o + 2] = byte01(Double(colors[o + 2]) / 255 * (1 - mix) + tint.b * mix)
        }
        return TerrainColorRenderer.Buffers(colors: colors, surfaces: surfaces, covers: buffers.covers)
    }
}
