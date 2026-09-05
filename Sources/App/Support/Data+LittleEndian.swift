import Foundation

extension Data {
    /// Append `value`'s bytes, least significant first: the byte order a WAV header and its PCM
    /// samples are written in. Shifts rather than a pointer over the value, so a wire byte is
    /// produced without an unsafe construct.
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var bits = T.Magnitude(truncatingIfNeeded: value)   // the two's-complement bit pattern
        for _ in 0..<(T.bitWidth / 8) {
            append(UInt8(truncatingIfNeeded: bits))
            bits >>= 8
        }
    }
}
