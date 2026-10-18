import Foundation

/// Operating systems Burrow can fetch by itself, always from the publisher's own servers.
public struct CatalogImage: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A preinstalled cloud disk image, personalized at first boot by cloud-init.
        /// `desktop` installs a graphical desktop on first boot.
        case cloudImage(desktop: Bool)
        /// An installer ISO the user steps through.
        case installer
    }

    public let id: String
    public let name: String
    public let guest: GuestOS
    public let summary: String
    public let approximateSize: String
    /// Default machine name.
    public let machineName: String
    public let kind: Kind

    /// Whether the machine is ready without the user stepping through an installer.
    public var isAutomatic: Bool {
        if case .cloudImage = kind { return true }
        return false
    }
}

public enum Checksum: Sendable, Equatable {
    case sha256(String)
    case sha512(String)

    public var value: String {
        switch self {
        case .sha256(let value), .sha512(let value): value.lowercased()
        }
    }
}

/// A concrete file to download, resolved from the publisher's release metadata.
public struct ResolvedImage: Sendable, Equatable {
    public let url: URL
    public let fileName: String
    /// Published checksum; nil when the publisher only offers a weaker one.
    public let checksum: Checksum?
    public let version: String
}

public enum ImageCatalog {
    public static let ubuntuDesktop = CatalogImage(
        id: "ubuntu-desktop", name: "Ubuntu Desktop", guest: .linux,
        summary: "Latest LTS with GNOME, set up for you", approximateSize: "≈ 900 MB + desktop on first boot",
        machineName: "Ubuntu", kind: .cloudImage(desktop: true))
    public static let ubuntuServer = CatalogImage(
        id: "ubuntu-server", name: "Ubuntu Server", guest: .linux,
        summary: "Latest LTS, ready in about a minute", approximateSize: "≈ 900 MB",
        machineName: "Ubuntu Server", kind: .cloudImage(desktop: false))
    public static let debian = CatalogImage(
        id: "debian", name: "Debian", guest: .linux,
        summary: "Stable, ready in about a minute", approximateSize: "≈ 400 MB",
        machineName: "Debian", kind: .cloudImage(desktop: false))
    public static let fedora = CatalogImage(
        id: "fedora", name: "Fedora Workstation", guest: .linux,
        summary: "Latest release, guided installer", approximateSize: "≈ 2.7 GB",
        machineName: "Fedora", kind: .installer)
    public static let alpine = CatalogImage(
        id: "alpine", name: "Alpine Linux", guest: .linux,
        summary: "Tiny, guided installer", approximateSize: "≈ 90 MB",
        machineName: "Alpine", kind: .installer)

    public static let linux: [CatalogImage] = [ubuntuDesktop, ubuntuServer, debian, fedora, alpine]

    public static func image(id: String) -> CatalogImage? {
        linux.first { $0.id == id }
    }

    /// Folder where downloaded installers are kept for reuse.
    public static var cacheDirectory: URL {
        MachineLibrary.defaultRoot.deletingLastPathComponent().appendingPathComponent("Images", isDirectory: true)
    }

    public static func resolve(_ image: CatalogImage) async throws -> ResolvedImage {
        switch image.id {
        case ubuntuDesktop.id, ubuntuServer.id: try await resolveUbuntuCloud()
        case debian.id: try await resolveDebianCloud()
        case fedora.id: try await resolveFedora()
        case alpine.id: try await resolveAlpine()
        default: throw BurrowError.unsupported("Unknown image \(image.id).")
        }
    }

    /// A Windows 11 ARM64 ISO downloaded earlier, so later Windows machines need no download.
    public static func cachedWindowsISO() -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { url in
                let name = url.lastPathComponent.lowercased()
                return url.pathExtension.lowercased() == "iso" && name.contains("win") && name.contains("arm")
                    && !name.contains("virtio") && looksLikeDiscImage(url)
            }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
    }

    /// Downloads (or reuses a verified cached copy of) a resolved image.
    public static func fetch(_ resolved: ResolvedImage, downloader: FileDownloader,
                             progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let destination = cacheDirectory.appendingPathComponent(resolved.fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            if let checksum = resolved.checksum {
                if verifiedMarkerMatches(destination, checksum.value) { return destination }
            } else if isExpectedFormat(destination) {
                return destination
            }
        }
        try await downloader.download(from: resolved.url, to: destination, checksum: resolved.checksum, progress: progress)
        guard isExpectedFormat(destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw BurrowError.downloadFailed("\(resolved.fileName) isn’t what was expected. The server may have sent an error page.")
        }
        if let checksum = resolved.checksum { writeVerifiedMarker(destination, checksum.value) }
        return destination
    }

    /// Disc images for installers, compressed archives for cloud images.
    static func isExpectedFormat(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "iso": looksLikeDiscImage(url)
        case "gz": hasPrefix(url, [0x1F, 0x8B])
        case "xz": hasPrefix(url, [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])
        case "img", "qcow2": QCOW2.isQCOW2(url)
        default: true
        }
    }

    private static func hasPrefix(_ url: URL, _ bytes: [UInt8]) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: bytes.count)).map { [UInt8]($0) } == bytes
    }

    /// A complete ISO 9660 image: "CD001" at byte 0x8001, and the file is at least as large
    /// as the volume size its primary volume descriptor declares, so a cut-off download fails.
    public static func looksLikeDiscImage(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: 0x8000)) != nil,
              let descriptor = try? handle.read(upToCount: 2048), descriptor.count == 2048,
              descriptor[1..<6] == Data("CD001".utf8)
        else { return false }
        let bytes = [UInt8](descriptor)
        let blocks = UInt64(bytes[80]) | UInt64(bytes[81]) << 8 | UInt64(bytes[82]) << 16 | UInt64(bytes[83]) << 24
        let blockSize = UInt64(bytes[128]) | UInt64(bytes[129]) << 8
        guard let fileSize = try? handle.seekToEnd() else { return false }
        return blocks > 0 && blockSize > 0 && fileSize >= blocks * blockSize
    }

    // Hashing a multi-gigabyte cached file on every use is slow, so remember a verified hash.
    private static func markerURL(_ file: URL) -> URL {
        file.appendingPathExtension("verified")
    }

    private static func verifiedMarkerMatches(_ file: URL, _ hash: String) -> Bool {
        (try? String(contentsOf: markerURL(file), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == hash
    }

    private static func writeVerifiedMarker(_ file: URL, _ hash: String) {
        try? hash.write(to: markerURL(file), atomically: true, encoding: .utf8)
    }

    // MARK: Resolvers

    /// Newest supported Ubuntu LTS, e.g. "26.04.1".
    static func latestUbuntuLTS() async throws -> String {
        let meta = try await text("https://changelogs.ubuntu.com/meta-release-lts")
        var version: String?
        var current: String?
        for line in meta.split(separator: "\n") {
            if line.hasPrefix("Version:") {
                current = line.dropFirst("Version:".count).trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first
            } else if line.hasPrefix("Supported: 1"), let current {
                version = current
            }
        }
        guard let version else { throw BurrowError.downloadFailed("Couldn’t find the current Ubuntu release.") }
        return version
    }

    /// The preinstalled server cloud image: a bootable qcow2 disk. (The tarball next to it
    /// holds only the root filesystem, without a partition table or bootloader.)
    static func resolveUbuntuCloud() async throws -> ResolvedImage {
        let release = try await latestUbuntuLTS().split(separator: ".").prefix(2).joined(separator: ".")
        let directory = "https://cloud-images.ubuntu.com/releases/\(release)/release/"
        let file = "ubuntu-\(release)-server-cloudimg-arm64.img"
        guard let hash = checksum(for: file, in: try await text(directory + "SHA256SUMS")) else {
            throw BurrowError.downloadFailed("Ubuntu \(release) has no ARM64 cloud image yet.")
        }
        return ResolvedImage(url: URL(string: directory + file)!, fileName: file, checksum: .sha256(hash), version: release)
    }

    /// Debian's generic (all drivers) cloud image for the current stable release.
    static func resolveDebianCloud() async throws -> ResolvedImage {
        let release = try await text("https://deb.debian.org/debian/dists/stable/Release")
        func field(_ name: String) -> String? {
            release.split(separator: "\n").first { $0.hasPrefix("\(name):") }
                .map { $0.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces) }
        }
        guard let codename = field("Codename"), let version = field("Version") else {
            throw BurrowError.downloadFailed("Couldn’t find the current Debian release.")
        }
        let major = version.split(separator: ".").first.map(String.init) ?? version
        let directory = "https://cloud.debian.org/images/cloud/\(codename)/latest/"
        let file = "debian-\(major)-generic-arm64.tar.xz"
        guard let hash = checksum(for: file, in: try await text(directory + "SHA512SUMS")) else {
            throw BurrowError.downloadFailed("Debian \(major) has no ARM64 cloud image.")
        }
        return ResolvedImage(url: URL(string: directory + file)!, fileName: "debian-\(version)-generic-arm64.tar.xz",
                             checksum: .sha512(hash), version: version)
    }

    static func resolveFedora() async throws -> ResolvedImage {
        struct Release: Decodable {
            let version: String
            let arch: String
            let link: String
            let variant: String
            let sha256: String?
        }
        let releases = try JSONDecoder().decode([Release].self, from: await data("https://fedoraproject.org/releases.json"))
        let candidates = releases
            .filter { $0.arch == "aarch64" && $0.variant == "Workstation" && $0.link.hasSuffix(".iso") && Int($0.version) != nil }
            .sorted { Int($0.version)! > Int($1.version)! }
        guard let release = candidates.first, let url = URL(string: release.link) else {
            throw BurrowError.downloadFailed("Couldn’t find the current Fedora release.")
        }
        return ResolvedImage(url: url, fileName: url.lastPathComponent, checksum: release.sha256.map(Checksum.sha256), version: release.version)
    }

    static func resolveAlpine() async throws -> ResolvedImage {
        let directory = "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/"
        let manifest = try await text(directory + "latest-releases.yaml")
        // Entries are YAML maps separated by "-"; read the virt flavor's fields.
        for entry in manifest.components(separatedBy: "\n-") where entry.contains("flavor: alpine-virt") {
            func field(_ key: String) -> String? {
                entry.split(separator: "\n")
                    .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key):") }
                    .map { $0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces) }
            }
            if let file = field("file"), file.hasSuffix(".iso"), let hash = field("sha256") {
                return ResolvedImage(url: URL(string: directory + file)!, fileName: file, checksum: .sha256(hash), version: field("version") ?? "")
            }
        }
        throw BurrowError.downloadFailed("Couldn’t find the current Alpine release.")
    }

    /// The virtio-win driver disc (Windows networking, storage and more), from the Fedora project.
    public static func resolveVirtioWin() async throws -> ResolvedImage {
        // The stable link redirects (over plain HTTP) through a versioned folder to the
        // versioned file. Walk the chain ourselves so every hop uses HTTPS.
        var url = URL(string: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso")!
        let session = URLSession(configuration: .ephemeral, delegate: RedirectBlocker(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        for _ in 0..<6 {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { break }
            guard (300..<400).contains(http.statusCode),
                  let location = http.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: location, relativeTo: url)?.absoluteURL,
                  var components = URLComponents(url: next, resolvingAgainstBaseURL: false)
            else { break }
            components.scheme = "https"
            guard let secure = components.url else { break }
            url = secure
        }
        let version = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "virtio-win-", with: "")
        // The project publishes only MD5 sums for the RPMs, not the ISO; it's fetched over HTTPS
        // and checked to be a real disc image.
        return ResolvedImage(url: url, fileName: url.lastPathComponent, checksum: nil, version: version)
    }

    // MARK: Helpers

    static func checksum(for file: String, in sums: String) -> String? {
        for line in sums.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if name == file { return String(parts[0]) }
        }
        return nil
    }

    static func data(_ address: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: URL(string: address)!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BurrowError.downloadFailed("\(address) answered \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        return data
    }

    static func text(_ address: String) async throws -> String {
        String(decoding: try await data(address), as: UTF8.self)
    }
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
