import Foundation

public final class BackgroundJob<Output>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var running: DispatchGroup?
    private var finished = false
    private var output: Output?

    public private(set) var waits = 0
    public private(set) var waitedSeconds = 0.0

    var willBlock: (() -> Void)?

    public init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public var isPending: Bool { locked { running != nil } }

    public var isReady: Bool { locked { running != nil && finished } }

    @discardableResult
    public func start(_ work: @escaping () -> Output) -> Bool {
        let group = DispatchGroup()
        let claimed: Bool = locked {
            guard running == nil else { return false }
            running = group
            finished = false
            output = nil
            return true
        }
        guard claimed else { return false }
        group.enter()
        nonisolated(unsafe) let unsafeWork = work
        queue.async {
            let result = unsafeWork()
            self.locked {
                self.output = result
                self.finished = true
            }
            group.leave()
        }
        return true
    }

    public func wait() {
        let (group, done) = locked { (running, finished) }
        guard let group, !done else { return }
        let start = DispatchTime.now().uptimeNanoseconds
        willBlock?()
        group.wait()
        waits += 1
        waitedSeconds += Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    public func take() -> Output? {
        wait()
        return locked {
            guard running != nil else { return nil }
            let result = output
            running = nil
            finished = false
            output = nil
            return result
        }
    }
}
