import Foundation

/// Keeps an eye on RAM: if the Mac fills up (virtual machines, heavy
/// programs) the local model (~8 GB) is removed from memory before the
/// system starts slowing down. A light check every 20 seconds, plus macOS's
/// immediate notice when memory comes under pressure.
final class MemoryGuard {
    /// Percentage of free memory according to macOS (the same as `memory_pressure`).
    static var freePercent: Int {
        var level: Int32 = 100
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 else { return 100 }
        return Int(level)
    }

    /// Share of RAM taken by the local model (~8.5 GB with the context).
    static var modelPercent: Int {
        Int((8.5 * 1_073_741_824 / Double(ProcessInfo.processInfo.physicalMemory) * 100).rounded(.up))
    }

    private var timer: Timer?
    private let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)

    /// `onLow` is called (on the main thread) when free memory drops
    /// below `threshold` % or macOS reports pressure.
    func start(threshold: @escaping () -> Int, onLow: @escaping (_ reason: String) -> Void) {
        source.setEventHandler { onLow("macOS segnala memoria sotto pressione") }
        source.activate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            let free = Self.freePercent
            if free < threshold() { onLow("memoria libera al \(free)%") }
        }
    }
}
