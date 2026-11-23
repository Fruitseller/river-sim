# Schutzmaske für Kronendach und Render-Verschiebung

Kronendach und Render-Verschiebung dürfen Wasser nicht überdecken: das Dach pflanzte Bäume in Flüsse und Seen, die Verschiebung wölbte Ufer über Flussbänder oder deformierte Talböden (Issue #154, Vorbau für #117). `WaterProtectMask` vereint:
1. sichtbares Rasterwasser,
2. die tatsächliche Abdeckung der Flussbänder (`RiverRibbonRenderer.bandCoverage`), weil der Raster-Deckel das Rasterwasser unter Bändern entfernt,
3. die nasse Wiese (Issue #174 C): kleine Tümpel, die das Raster nicht als Wasser malt; sie tragen hohes Vegetationsgewicht, auf dem sonst Wald stünde,
4. einen Saum von `WaterRender.protectSeamCells` Zellen (3×3-Pässe, Chebyshev-Abstand) um alles davon,
5. frische Gleithang-Bänke (#174 C2) ab `WaterRender.barProtectSand` Sandgewicht, OHNE Saum: die Bank ist eben und kahl und liegt ohnehin am Lauf, ein Saum risse den Auwald dahinter weg.

Zustandslos; den Cache hält `RenderState`.

Fürs Kronendach liefert `canopyGuard` Sperre und Abstandskarte mit nur `CanopyRender.waterSeamCells` Saum statt `protectSeamCells` (Look-Iteration 12, Auwald). Seit Look-Iteration 14 zählt der Abstand (Galeriewald) nur Bänder und Seen, nicht Raster-Zubringer und nasse Wiese; um diese sperrt wieder der volle Saum der Schutzmaske. Mit nur `waterSeamCells` wuchs jeder Bach im Talboden zu (Bewerter Nr. 13: Lichtungen und Grasflächen der Talmitte fehlten).

Betrifft: `WaterProtectMask`, `WaterProtectMask.bytes`, `WaterProtectMask.canopyGuard`
