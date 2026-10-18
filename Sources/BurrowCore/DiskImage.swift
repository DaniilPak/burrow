import Foundation

/// Creates and resizes the block devices behind a machine.
///
/// ASIF (Apple Sparse Image Format) is preferred: it stays sparse when copied
/// between volumes and performs better under Virtualization.framework. Hosts
/// without it get a raw sparse file, which APFS also stores sparsely.
public enum DiskImage {
    public enum Format: String, Sendable {
        case asif
        case raw

        public var fileName: String { self == .asif ? "disk.asif" : "disk.img" }
    }

    public static func preferredFormat() -> Format {
        FileManager.default.isExecutableFile(atPath: "/usr/sbin/diskutil") && asifSupported ? .asif : .raw
    }

    /// `diskutil image` (and with it ASIF) arrived in macOS 26.
    static var asifSupported: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }

    @discardableResult
    public static func create(at url: URL, bytes: UInt64, format: Format) throws -> Format {
        switch format {
        case .asif:
            do {
                try run("/usr/sbin/diskutil", [
                    "image", "create", "blank", "--fs", "none", "--format", "ASIF",
                    "--size", "\(bytes)B", url.path,
                ])
                return .asif
            } catch {
                // Some volumes refuse ASIF; a raw sparse file always works.
                let raw = url.deletingLastPathComponent().appendingPathComponent(Format.raw.fileName)
                try createRaw(at: raw, bytes: bytes)
                return .raw
            }
        case .raw:
            try createRaw(at: url, bytes: bytes)
            return .raw
        }
    }

    static func createRaw(at url: URL, bytes: UInt64) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw BurrowError.diskCreationFailed("can’t write \(url.path)")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: bytes)
    }

    /// Grows a disk in place. Shrinking would destroy guest data, so it is refused.
    public static func grow(at url: URL, to bytes: UInt64) throws {
        let current = try logicalSize(of: url)
        guard bytes > current else {
            if bytes == current { return }
            throw BurrowError.unsupported("Disks can only grow (current size \(current) bytes).")
        }
        if url.pathExtension == "asif" {
            try run("/usr/sbin/diskutil", ["image", "resize", "--size", "\(bytes)B", url.path])
        } else {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: bytes)
        }
    }

    /// Size the guest sees. For ASIF this comes from `diskutil image info`.
    public static func logicalSize(of url: URL) throws -> UInt64 {
        if url.pathExtension == "asif" {
            let output = try run("/usr/sbin/diskutil", ["image", "info", "--plist", url.path])
            if let plist = try PropertyListSerialization.propertyList(from: Data(output.utf8), format: nil) as? [String: Any],
               let sizeInfo = plist["Size Info"] as? [String: Any],
               let total = sizeInfo["Total Bytes"] as? NSNumber {
                return total.uint64Value
            }
            throw BurrowError.unsupported("Couldn’t read the size of \(url.lastPathComponent).")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Bytes actually allocated on the host volume.
    public static func allocatedSize(of url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return UInt64(values?.totalFileAllocatedSize ?? 0)
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw BurrowError.diskCreationFailed(message.isEmpty ? "\(tool) exited \(process.terminationStatus)" : message)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
