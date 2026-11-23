public enum WaterTailPlan {

    public static let streamBlurPasses = 1

    public static let lakeBlurPasses = 2

    public static var blurPassCount: Int { max(streamBlurPasses, lakeBlurPasses) }

    public static func blurMask(pass: Int) -> (Double, Double) {
        (pass < streamBlurPasses ? 1.0 : 0.0,
         pass < lakeBlurPasses ? 1.0 : 0.0)
    }

    public static func blurMasks() -> [Double] {
        (0..<blurPassCount).flatMap { pass in
            [blurMask(pass: pass).0, blurMask(pass: pass).1]
        }
    }

    public static let primeBlend = 1.0
}
