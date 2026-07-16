import Foundation

/// Downsamples the recorder's rolling level trace into the compact, quantized form a Live
/// Activity's content state can carry (the state has a hard size budget, so the full-resolution
/// `[Float]` never crosses the process boundary). Pure; unit-tested.
public nonisolated enum ActivityLevels {
    /// Reduce `levels` (normalized 0…1, newest last) to exactly `count` buckets of 0…100.
    /// Each bucket keeps its window's peak — a waveform reads by its peaks, and a mean would
    /// flatten short bursts into silence. Fewer samples than buckets left-pads with zeros so
    /// the trace stays right-aligned (newest at the trailing edge, the app's waveform idiom).
    public static func downsample(_ levels: [Float], to count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        guard !levels.isEmpty else { return Array(repeating: 0, count: count) }

        var buckets: [UInt8] = []
        buckets.reserveCapacity(count)
        if levels.count <= count {
            buckets.append(contentsOf: Array(repeating: 0 as UInt8, count: count - levels.count))
            buckets.append(contentsOf: levels.map(quantize))
        } else {
            // Partition into `count` near-equal windows and keep each window's peak.
            for bucket in 0..<count {
                let start = levels.count * bucket / count
                let end = levels.count * (bucket + 1) / count
                let peak = levels[start..<max(end, start + 1)].max() ?? 0
                buckets.append(quantize(peak))
            }
        }
        return buckets
    }

    private static func quantize(_ level: Float) -> UInt8 {
        UInt8((min(max(level, 0), 1) * 100).rounded())
    }
}
