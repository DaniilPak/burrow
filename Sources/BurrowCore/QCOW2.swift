import Compression
import Foundation

/// Converts QEMU qcow2 images (the format of most Linux cloud images) to raw disks
/// that Virtualization.framework can boot. Supports version 2 and 3 images without a
/// backing file or encryption, with plain or zlib-compressed clusters. Unallocated and
/// zero clusters are skipped, so the output stays sparse.
public enum QCOW2 {
    public static func isQCOW2(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x51, 0x46, 0x49, 0xFB])
    }

    public static func convertToRaw(_ source: URL, destination: URL, progress: ((Double) -> Void)? = nil) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let header = try read(input, at: 0, count: 104)
        func u32(_ offset: Int) -> UInt32 { header[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        func u64(_ offset: Int) -> UInt64 { header[offset..<offset + 8].reduce(0) { $0 << 8 | UInt64($1) } }

        guard u32(0) == 0x5146_49FB else { throw failure("not a qcow2 image") }
        let version = u32(4)
        guard version == 2 || version == 3 else { throw failure("unsupported qcow2 version \(version)") }
        guard u64(8) == 0 else { throw failure("images with a backing file aren’t supported") }
        let clusterBits = u32(20)
        guard (9...21).contains(clusterBits) else { throw failure("bad cluster size") }
        let virtualSize = u64(24)
        guard u32(32) == 0 else { throw failure("encrypted images aren’t supported") }
        let l1Size = Int(u32(36))
        let l1Offset = u64(40)
        if version == 3 {
            let incompatible = u64(72)
            // Any incompatible feature (dirty, corrupt, external data, zstd, …) is beyond this reader.
            guard incompatible == 0 else {
                throw failure("image uses qcow2 features Burrow can’t read (\(incompatible))")
            }
        }

        let clusterSize = 1 << Int(clusterBits)
        let l2Entries = clusterSize / 8
        let offsetMask: UInt64 = 0x00FF_FFFF_FFFF_FE00
        let compressedFlag: UInt64 = 1 << 62
        // For compressed clusters, the host offset uses the low (62 - (clusterBits - 8)) bits.
        let compressedOffsetBits = 62 - (UInt64(clusterBits) - 8)
        let compressedOffsetMask = (UInt64(1) << compressedOffsetBits) - 1
        let sectorCountMask = (UInt64(1) << (UInt64(clusterBits) - 8)) - 1

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.truncate(atOffset: virtualSize)

        let l1 = try read(input, at: l1Offset, count: l1Size * 8)
        let totalClusters = max(1, Int((virtualSize + UInt64(clusterSize) - 1) / UInt64(clusterSize)))
        var clusterIndex = 0
        var buffer = [UInt8](repeating: 0, count: clusterSize)

        for l1Index in 0..<l1Size {
            let l2Offset = l1[l1Index * 8..<l1Index * 8 + 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) } & offsetMask
            if l2Offset == 0 {
                clusterIndex += l2Entries
                continue
            }
            let l2 = try read(input, at: l2Offset, count: clusterSize)
            for l2Index in 0..<l2Entries {
                let guestOffset = UInt64(clusterIndex) * UInt64(clusterSize)
                clusterIndex += 1
                guard guestOffset < virtualSize else { break }
                let entry = l2[l2Index * 8..<l2Index * 8 + 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                if entry & compressedFlag != 0 {
                    let hostOffset = entry & compressedOffsetMask
                    let sectors = ((entry >> compressedOffsetBits) & sectorCountMask) + 1
                    let length = Int(sectors * 512 - (hostOffset & 511))
                    let compressed = try read(input, at: hostOffset, count: length)
                    let produced = compressed.withUnsafeBytes { raw in
                        compression_decode_buffer(&buffer, clusterSize, raw.bindMemory(to: UInt8.self).baseAddress!,
                                                  compressed.count, nil, COMPRESSION_ZLIB)
                    }
                    guard produced > 0 else { throw failure("a compressed cluster is damaged") }
                    try write(output, Data(buffer[0..<min(produced, clusterSize)]), at: guestOffset)
                } else {
                    let hostOffset = entry & offsetMask
                    // Offset 0 is unallocated; bit 0 marks an all-zero cluster. Both stay holes.
                    guard hostOffset != 0, entry & 1 == 0 else { continue }
                    let data = try read(input, at: hostOffset, count: clusterSize)
                    if data.contains(where: { $0 != 0 }) { try write(output, data, at: guestOffset) }
                }
                if clusterIndex % 256 == 0 { progress?(Double(clusterIndex) / Double(totalClusters)) }
            }
        }
        progress?(1)
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw failure("the image is truncated") }
        return data
    }

    private static func write(_ handle: FileHandle, _ data: Data, at offset: UInt64) throws {
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: data)
    }

    private static func failure(_ reason: String) -> BurrowError {
        .diskCreationFailed("Couldn’t convert the cloud image: \(reason).")
    }
}
