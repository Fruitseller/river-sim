public enum BrushTool: Int, CaseIterable {
    case raise = 0
    case lower = 1
    case smooth = 2
    case flatten = 3
    case roughen = 4
    case pickaxe = 5

    public func apply(to terrain: Terrain, gx: Double, gz: Double, radiusWorld: Double,
                      strength: Double, target: Double) {
        guard gx.isFinite && gz.isFinite && radiusWorld.isFinite && strength.isFinite && target.isFinite,
              abs(gx) < 1e9, abs(gz) < 1e9, abs(strength) < 1e9, abs(target) < 1e9,
              radiusWorld <= Double(terrain.cfg.n) * terrain.cfg.cellSize else { return }
        switch self {
        case .raise:
            terrain.sculpt(gx: gx, gz: gz, radiusWorld: radiusWorld, dir: 1, strength: strength)
        case .lower:
            terrain.sculpt(gx: gx, gz: gz, radiusWorld: radiusWorld, dir: -1, strength: strength)
        case .smooth:
            terrain.smooth(gx: gx, gz: gz, radiusWorld: radiusWorld, strength: strength)
        case .flatten:
            terrain.flatten(gx: gx, gz: gz, radiusWorld: radiusWorld,
                            targetHeight: target, strength: strength)
        case .roughen:
            terrain.roughen(gx: gx, gz: gz, radiusWorld: radiusWorld, strength: strength)
        case .pickaxe:
            terrain.pickaxe(gx: gx, gz: gz, radiusWorld: radiusWorld, strength: strength)
        }
    }
}
