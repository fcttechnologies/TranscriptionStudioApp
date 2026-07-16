import Foundation

/// A minimal, dependency-free ZIP writer — stored (uncompressed) entries only, which keeps the
/// implementation to CRC-32 plus the three standard ZIP records (local file header, central
/// directory, end-of-central-directory) with no compression codec to get wrong. Deterministic:
/// every entry carries a fixed DOS timestamp, so identical input always produces byte-identical
/// output — exactly what a DOCX (a zip of XML parts) needs to be. Stored entries are valid ZIP
/// (compression method 0) and open in Word/Pages the same as a deflated one.
enum MinimalZip {
    struct Entry {
        let name: String
        let data: Data
    }

    /// The fixed DOS date every entry is stamped with — 1980-01-01, the floor of the DOS date
    /// format ZIP uses: `((year - 1980) << 9) | (month << 5) | day`.
    private static let dosTime: UInt16 = 0
    private static let dosDate: UInt16 = 0x21

    static func archive(_ entries: [Entry]) -> Data {
        var body = Data()
        var central = Data()
        var offset: UInt32 = 0

        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let nameLength = UInt16(nameBytes.count)

            var local = Data()
            local.append(le32(0x0403_4b50))
            local.append(le16(20))                 // version needed to extract
            local.append(le16(0))                  // general purpose flag
            local.append(le16(0))                  // compression method: stored
            local.append(le16(dosTime))
            local.append(le16(dosDate))
            local.append(le32(crc))
            local.append(le32(size))               // compressed size
            local.append(le32(size))               // uncompressed size
            local.append(le16(nameLength))
            local.append(le16(0))                  // extra field length
            local.append(contentsOf: nameBytes)
            body.append(local)
            body.append(entry.data)

            var centralEntry = Data()
            centralEntry.append(le32(0x0201_4b50))
            centralEntry.append(le16(20))           // version made by (0 = MS-DOS host, 2.0 spec)
            centralEntry.append(le16(20))           // version needed to extract
            centralEntry.append(le16(0))            // general purpose flag
            centralEntry.append(le16(0))            // compression method
            centralEntry.append(le16(dosTime))
            centralEntry.append(le16(dosDate))
            centralEntry.append(le32(crc))
            centralEntry.append(le32(size))
            centralEntry.append(le32(size))
            centralEntry.append(le16(nameLength))
            centralEntry.append(le16(0))            // extra field length
            centralEntry.append(le16(0))            // comment length
            centralEntry.append(le16(0))            // disk number start
            centralEntry.append(le16(0))            // internal file attributes
            centralEntry.append(le32(0))             // external file attributes
            centralEntry.append(le32(offset))        // relative offset of local header
            centralEntry.append(contentsOf: nameBytes)
            central.append(centralEntry)

            offset &+= UInt32(local.count) &+ size
        }

        var end = Data()
        end.append(le32(0x0605_4b50))
        end.append(le16(0))                                    // this disk's number
        end.append(le16(0))                                    // disk where central dir starts
        end.append(le16(UInt16(entries.count)))                 // records on this disk
        end.append(le16(UInt16(entries.count)))                 // total records
        end.append(le32(UInt32(central.count)))                 // central directory size
        end.append(le32(offset))                                // central directory offset
        end.append(le16(0))                                    // comment length

        return body + central + end
    }

    // MARK: - Byte-order helpers

    private static func le16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff)])
    }

    private static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
              UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)])
    }

    /// Standard bit-by-bit ZIP CRC-32 (polynomial 0xEDB88320). No lookup table — every entry
    /// here is a handful of small XML parts, so the per-byte bit loop costs nothing worth
    /// caching a table for.
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
