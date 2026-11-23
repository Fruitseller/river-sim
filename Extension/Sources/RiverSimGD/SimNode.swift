import Foundation
import SwiftGodot
import SimCore
import SimRender

@Godot
final class SimNode: Node {
    private let session = WorldSession<VariantDictionary>(
        config: SimConfig.production,
        seed: RenderContract.defaultSeed,
        settleYears: SimConfig.productionSettleYears)
    private var lastWorldBytes = 0

    @Callable func generate(seed: Int) {
        session.generate(seed: UInt32(truncatingIfNeeded: seed),
                         settleYears: SimConfig.productionSettleYears)
    }

    @Callable func step(years: Double) { session.step(years: years) }

    @Callable func beginStep(years: Double, trigger: Int, now: Double) {
        guard let frameTrigger = Self.frameTrigger(trigger, "beginStep") else { return }
        guard session.beginStep(years: years, trigger: frameTrigger, now: now,
                                pack: Self.packFrame) else {
            GD.pushError("beginStep: der vorige Schritt ist noch unterwegs — erst "
                         + "finishStep(), sonst ginge sein Frame verloren")
            return
        }
    }

    @Callable func stepInFlight() -> Bool { session.stepInFlight }

    @Callable func stepReady() -> Bool { session.stepReady }

    @Callable func finishStep() -> VariantDictionary { session.finishStep() ?? VariantDictionary() }

    @Callable func stepWaitMilliseconds() -> Double { session.stepWaitedSeconds * 1000 }

    @Callable func saveWorld(path: String) -> String {
        do {
            lastWorldBytes = try session.save(to: path)
            return ""
        } catch let error as SnapshotError {
            return error.description
        } catch {
            return "Speichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    @Callable func loadWorld(path: String) -> String {
        do {
            try session.load(from: path)
            lastWorldBytes = 0
            return ""
        } catch let error as SnapshotError {
            return error.description
        } catch {
            return "Laden fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    @Callable func worldFileGridSize(path: String) -> Int {
        (try? WorldSnapshot.peekConfig(at: path).n) ?? -1
    }

    @Callable func worldFileWorldSize(path: String) -> Double {
        (try? WorldSnapshot.peekConfig(at: path).world) ?? -1
    }

    @Callable func lastWorldFileBytes() -> Int { lastWorldBytes }

    @Callable func worldFileExtension() -> String { WorldSnapshot.fileExtension }

    @Callable func gridSize() -> Int { session.config.n }
    @Callable func worldSize() -> Double { session.config.world }
    @Callable func seaLevel() -> Double { session.config.sea }
    @Callable func currentYear() -> Double { session.year }

    @Callable func buildStamp() -> String { BuildStamp.value }

    @Callable func heights() -> PackedFloat32Array { Self.pack(session.heights) }

    @Callable func heightsBytes() -> PackedByteArray { Self.packBytes(session.heights) }

    @Callable func flowArea() -> PackedFloat32Array { Self.pack(session.flowArea) }

    @Callable func receivers() -> PackedInt32Array { PackedInt32Array(session.receivers) }

    private static func packBands(_ b: HeightBands) -> PackedFloat32Array {
        PackedFloat32Array([
            Float(b.vegFull), Float(b.vegNone), Float(b.rockStart), Float(b.rockFull),
            Float(b.snowStart), Float(b.snowFull), Float(b.coniferLow), Float(b.coniferHigh),
        ])
    }

    @Callable func captureDebugReference() { session.captureDebugReference() }

    @Callable func debugTerrainStats() -> PackedFloat32Array {
        PackedFloat32Array(session.debugTerrainStats())
    }

    @Callable func heightDifferenceBytes(scale: Double) -> PackedByteArray {
        PackedByteArray(session.heightDifferenceBytes(scale: scale))
    }

    @Callable func renderFrame(trigger: Int, now: Double) -> VariantDictionary {
        guard let frameTrigger = Self.frameTrigger(trigger, "renderFrame") else {
            return VariantDictionary()
        }
        return Self.packFrame(session.renderFrame(frameTrigger, now: now))
    }

    private static func frameTrigger(_ raw: Int, _ caller: String) -> FrameTrigger? {
        guard let trigger = FrameTrigger(rawValue: raw) else {
            GD.pushError("\(caller): unbekannter Auslöser \(raw) — FRAME_* (Main.gd) "
                         + "und FrameTrigger sind auseinandergelaufen")
            return nil
        }
        return trigger
    }

    private static func packFrame(_ world: WorldFrame) -> VariantDictionary {
        let out = VariantDictionary()
        out[Variant("trigger")] = Variant(world.trigger.rawValue)
        out[Variant("year")] = Variant(world.year)
        out[Variant("heights")] = packBytes(world.heights).toVariant()
        if let o = world.frame.overlays {
            out[Variant("water")] = PackedByteArray(o.water).toVariant()
            out[Variant("water_blend")] = Variant(o.waterBlend)
            out[Variant("color")] = PackedByteArray(o.colors).toVariant()
            out[Variant("surface")] = PackedByteArray(o.surfaces).toVariant()
            out[Variant("cover")] = PackedByteArray(o.covers).toVariant()
            out[Variant("flow")] = PackedByteArray(o.flowDetail).toVariant()
            out[Variant("protect")] = PackedByteArray(o.protectMask).toVariant()
            out[Variant("forest")] = PackedByteArray(o.forestMask).toVariant()
            out[Variant("plume")] = packFloatBytes(o.plume).toVariant()
            out[Variant("filled")] = packBytes(world.waterLevel).toVariant()
            out[Variant("bands")] = packBands(world.bands).toVariant()
        }
        if world.frame.ribbonsRebuilt {
            out[Variant("ribbons")] = Variant(true)
            out[Variant("ribbon_verts")] = ribbonVerts(world.ribbons).toVariant()
            out[Variant("ribbon_colors")] = ribbonColors(world.ribbons).toVariant()
            out[Variant("ribbon_uvs")] = ribbonUVs(world.ribbons).toVariant()
            out[Variant("ribbon_uv2s")] = ribbonUV2s(world.ribbons).toVariant()
            out[Variant("ribbon_flows")] = ribbonFlows(world.ribbons).toVariant()
            out[Variant("ribbon_indices")] = PackedInt32Array(world.ribbons.indices).toVariant()
            out[Variant("ribbon_strip_starts")] = PackedInt32Array(world.ribbons.stripStarts).toVariant()
            out[Variant("ribbon_profile")] = flatten4(world.ribbons.profile).toVariant()
            let c = world.ribbons.corridor
            out[Variant("corridor_verts")] = PackedVector3Array(c.vertices.map { Vector3(x: $0.x, y: $0.y, z: $0.z) }).toVariant()
            out[Variant("corridor_normals")] = PackedVector3Array(c.normals.map { Vector3(x: $0.x, y: $0.y, z: $0.z) }).toVariant()
            out[Variant("corridor_colors")] = PackedColorArray(c.colors.map { Color(r: $0.x, g: $0.y, b: $0.z, a: $0.w) }).toVariant()
            out[Variant("corridor_uvs")] = PackedVector2Array(c.uvs.map { Vector2(x: $0.x, y: $0.y) }).toVariant()
            out[Variant("corridor_uv2s")] = PackedVector2Array(c.uv2s.map { Vector2(x: $0.x, y: $0.y) }).toVariant()
            out[Variant("corridor_custom")] = flatten4(c.custom).toVariant()
            out[Variant("corridor_indices")] = PackedInt32Array(c.indices).toVariant()
        }
        return out
    }

    private static func ribbonVerts(_ mesh: RibbonMesh) -> PackedVector3Array {
        PackedVector3Array(mesh.vertices.map { Vector3(x: $0.x, y: $0.y, z: $0.z) })
    }
    private static func ribbonColors(_ mesh: RibbonMesh) -> PackedColorArray {
        PackedColorArray(mesh.colors.map { Color(r: $0.x, g: $0.y, b: $0.z, a: $0.w) })
    }
    private static func ribbonUVs(_ mesh: RibbonMesh) -> PackedVector2Array {
        PackedVector2Array(mesh.uvs.map { Vector2(x: $0.x, y: $0.y) })
    }
    private static func ribbonUV2s(_ mesh: RibbonMesh) -> PackedVector2Array {
        PackedVector2Array(mesh.uv2s.map { Vector2(x: $0.x, y: $0.y) })
    }
    private static func ribbonFlows(_ mesh: RibbonMesh) -> PackedFloat32Array {
        flatten4(mesh.flows)
    }
    private static func flatten4(_ values: [SIMD4<Float>]) -> PackedFloat32Array {
        var flat: [Float] = []
        flat.reserveCapacity(values.count * 4)
        for f in values { flat.append(f.x); flat.append(f.y); flat.append(f.z); flat.append(f.w) }
        return PackedFloat32Array(flat)
    }

    @Callable func setDeferWaterTail(enabled: Bool) { session.deferWaterTail = enabled }

    @Callable func calibration(group: String) -> VariantDictionary {
        let out = VariantDictionary()
        guard let group = CalibrationRegistry.Group(rawValue: group) else { return out }
        for entry in CalibrationRegistry.entries(group) {
            switch entry.value {
            case .scalar(let v):
                out[Variant(entry.name)] = Variant(group.isUniform ? Double(Float(v)) : v)
            case .color(let r, let g, let b):
                out[Variant(entry.name)] = Variant(Vector3(x: Float(r), y: Float(g), z: Float(b)))
            }
        }
        return out
    }

    @Callable func waterTailBlurPassCount() -> Int {
        WaterTailPlan.blurPassCount
    }

    @Callable func waterTailBlurMasks() -> PackedFloat32Array {
        PackedFloat32Array(WaterTailPlan.blurMasks().map { Float($0) })
    }

    @Callable func waterTailPrimeBlend() -> Float {
        Float(WaterTailPlan.primeBlend)
    }

    @Callable func brush(mode: Int, gx: Double, gz: Double, radiusWorld: Double,
                         strength: Double, target: Double) {
        guard let tool = BrushTool(rawValue: mode) else {
            GD.pushError("brush: unbekannter Modus \(mode) — Werkzeug-Tabelle (Main.gd) "
                         + "und BrushTool sind auseinandergelaufen")
            return
        }
        session.brush(tool, gx: gx, gz: gz, radiusWorld: radiusWorld,
                      strength: strength, target: target)
    }

    @Callable func recomputeFlow() {
        session.recomputeFlow()
    }

    @Callable func pickaxeMaxRadiusWorld() -> Double {
        session.pickaxeMaxRadiusWorld
    }

    @Callable func setRenderGrid(grid: Int) {
        session.renderGrid = grid
    }

    private static func pack(_ a: [Double]) -> PackedFloat32Array {
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

    private static func packFloatBytes(_ a: [Float]) -> PackedByteArray {
        PackedByteArray(a.withUnsafeBytes { Array($0) })
    }

    private static func packBytes(_ a: [Double]) -> PackedByteArray {
        var bytes = [UInt8](repeating: 0, count: a.count * 4)
        a.withUnsafeBufferPointer { ab in
        bytes.withUnsafeMutableBufferPointer { bb in
            let pa = ab.baseAddress!
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
