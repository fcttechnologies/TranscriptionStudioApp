import Foundation
import Synchronization

/// One snapshot of system pressure while pipelines run — the concurrent-ASR+diarization
/// degradation question is answered by charting these next to per-stage latencies.
public struct SystemLoadSample: Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public let thermalState: ProcessInfo.ThermalState
    /// Whole-process CPU usage in percent (can exceed 100 on multi-core).
    public let cpuPercent: Double
    /// Physical memory footprint in bytes.
    public let memoryFootprint: UInt64

    public init(thermalState: ProcessInfo.ThermalState, cpuPercent: Double, memoryFootprint: UInt64) {
        self.id = UUID()
        self.date = Date()
        self.thermalState = thermalState
        self.cpuPercent = cpuPercent
        self.memoryFootprint = memoryFootprint
    }
}

/// Samples thermal state + process CPU + memory on a fixed interval and feeds the
/// `InspectorStore`. Start while a session runs; stop when it ends.
public final class SystemLoadSampler: Sendable {
    private let store: InspectorStore
    private let interval: TimeInterval
    private let task = Mutex<Task<Void, Never>?>(nil)

    public init(store: InspectorStore, interval: TimeInterval = 1.0) {
        self.store = store
        self.interval = interval
    }

    public func start() {
        stop()
        let store = self.store
        let interval = self.interval
        let sampler = Task.detached(priority: .utility) {
            var previous = Self.cpuTicks()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                let current = Self.cpuTicks()
                let cpu = Self.cpuPercent(previous: previous, current: current, interval: interval)
                previous = current
                let sample = SystemLoadSample(
                    thermalState: ProcessInfo.processInfo.thermalState,
                    cpuPercent: cpu,
                    memoryFootprint: Self.memoryFootprint()
                )
                await MainActor.run { store.append(sample) }
            }
        }
        task.withLock { $0 = sampler }
    }

    public func stop() {
        task.withLock { current in
            current?.cancel()
            current = nil
        }
    }

    // MARK: Mach plumbing

    /// Total user+system CPU time consumed by this process, in seconds.
    private static func cpuTicks() -> Double {
        var info = task_thread_times_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
        let system = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
        return user + system
    }

    private static func cpuPercent(previous: Double, current: Double, interval: TimeInterval) -> Double {
        guard interval > 0, current >= previous else { return 0 }
        return (current - previous) / interval * 100
    }

    private static func memoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }
}
