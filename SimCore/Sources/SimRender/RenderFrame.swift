import Foundation

/// Wer einen Render-Frame auslöst (Issue #94). Der Auslöser bestimmt Taktung,
/// Wasser-Blend und welche Puffer entstehen; `Main.gd` meldet nur noch, WAS
/// passiert ist, und lädt hoch, was `RenderState.frame` zurückgibt.
///
/// Die Rohwerte sind ein Vertrag mit den `FRAME_*`-Konstanten in `Main.gd`
/// (Wächter: `RenderFrameTests.testMainUsesTheFrameTriggerValues`).
public enum FrameTrigger: Int, CaseIterable {
    /// Endstand nach einer diskreten Aktion (Start, Neu, Laden, Sprung-Ende,
    /// Strich-Ende): alles, Bänder ungedrosselt, Wasser ohne Überblenden.
    case settled = 0
    /// Ein Chunk eines Zeitsprungs: wie `settled`, aber die Bänder unter dem
    /// Zeitdeckel — sonst baute jeder 2000-Jahre-Chunk ein Mesh.
    case jumpChunk = 1
    /// Ein Zeitraffer-Takt: Overlays gedrosselt, Wasser weich geblendet.
    case timelapse = 2
    /// Nachzug während eines Pinselstrichs: Overlays und Bänder sofort
    /// (Sculpting droppt gestörte Kanäle).
    case stroke = 3
}

/// Die Puffer EINES Frames. `nil` heißt „in diesem Frame nicht neu", der
/// Aufrufer lässt die alte Textur stehen.
public struct RenderFrame {
    public struct Overlays {
        /// Wasserfeld (RGBA8). Bei `RenderState.deferWaterTail` die ROHEN
        /// Bytes ohne Schwanzstufen; dann blendet die GPU mit `waterBlend`.
        public let water: [UInt8]
        public let waterBlend: Double
        public let colors: [UInt8]
        public let surfaces: [UInt8]
        public let flowDetail: [UInt8]
        /// Entsteht NACH Bändern und Wasser, sieht also beide dieses Frames.
        public let protectMask: [UInt8]
        /// Waldmaske des Kronendachs (Issue #152): endet an der Schutzmaske
        /// DIESES Frames.
        public let forestMask: [UInt8]
    }

    public var overlays: Overlays?
    /// Neues Band-Mesh liegt in `RenderState.riverRibbonMesh`.
    public var ribbonsRebuilt = false
}
