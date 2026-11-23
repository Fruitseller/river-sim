import Foundation

public enum SimProfile {
    public nonisolated(unsafe) static var enabled = false

    public nonisolated(unsafe) private(set) static var totals: [String: Double] = [:]
    public nonisolated(unsafe) private(set) static var counts: [String: Int] = [:]

    private nonisolated(unsafe) static var openName: String?
    private nonisolated(unsafe) static var openStart: UInt64 = 0

    public nonisolated(unsafe) static var onPassEnd: ((String?) -> Void)?

    @inline(never)
    public static func mark(_ name: String?) {
        if let hook = onPassEnd { hook(openName) }
        let now = DispatchTime.now().uptimeNanoseconds
        if let open = openName {
            totals[open, default: 0] += Double(now &- openStart) * 1e-9
            counts[open, default: 0] += 1
        }
        openName = name
        openStart = DispatchTime.now().uptimeNanoseconds
    }

    public static func reset() {
        totals.removeAll()
        counts.removeAll()
        openName = nil
    }

    public static func report() -> [(name: String, seconds: Double, calls: Int)] {
        totals.map { (name: $0.key, seconds: $0.value, calls: counts[$0.key] ?? 0) }
            .sorted { $0.seconds > $1.seconds }
    }
}
