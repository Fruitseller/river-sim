import Foundation

public enum FrameTrigger: Int, CaseIterable {
    case settled = 0
    case jumpChunk = 1
    case timelapse = 2
    case stroke = 3
}

public struct RenderFrame {
    public struct Overlays {
        public let water: [UInt8]
        public let waterBlend: Double
        public let colors: [UInt8]
        public let surfaces: [UInt8]
        public let covers: [UInt8]
        public let flowDetail: [UInt8]
        public let protectMask: [UInt8]
        public let forestMask: [UInt8]
        public let plume: [Float]
    }

    public var overlays: Overlays?
    public var ribbonsRebuilt = false
}
