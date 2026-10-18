import Foundation
import Virtualization

/// Installs macOS into a new machine from a restore image (IPSW).
@MainActor
public final class MacInstaller {
    public enum Phase: Equatable, Sendable {
        case findingLatest
        case downloading(fraction: Double)
        case preparing
        case installing(fraction: Double)
        case finished
    }

    public typealias PhaseHandler = @MainActor (Phase) -> Void

    private var observation: NSKeyValueObservation?
    private var installer: VZMacOSInstaller?
    private var downloader: FileDownloader?

    public init() {}

    /// Folder where downloaded restore images are cached between installs.
    public static var restoreImageCache: URL {
        MachineLibrary.defaultRoot.deletingLastPathComponent().appendingPathComponent("Restore Images", isDirectory: true)
    }

    /// Downloads the newest macOS this Mac supports, reusing a cached copy.
    public func downloadLatestRestoreImage(onPhase: @escaping PhaseHandler) async throws -> URL {
        onPhase(.findingLatest)
        let image = try await VZMacOSRestoreImage.latestSupported
        let cache = Self.restoreImageCache
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let destination = cache.appendingPathComponent(image.url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        let downloader = FileDownloader()
        self.downloader = downloader
        defer { self.downloader = nil }
        try await downloader.download(from: image.url, to: destination) { fraction in
            Task { @MainActor in onPhase(.downloading(fraction: fraction)) }
        }
        return destination
    }

    public func cancelDownload() {
        downloader?.cancel()
    }

    /// Creates a machine sized from the image's requirements and installs macOS into it.
    @discardableResult
    public func install(
        restoreImage ipsw: URL,
        name: String,
        library: MachineLibrary,
        cpuCount: Int? = nil,
        memoryBytes: UInt64? = nil,
        diskBytes: UInt64 = .gibibytes(80),
        onPhase: @escaping PhaseHandler
    ) async throws -> MachineBundle {
        onPhase(.preparing)
        let image = try await VZMacOSRestoreImage.image(from: ipsw)
        guard let requirements = image.mostFeaturefulSupportedConfiguration else {
            throw BurrowError.unsupported("This Mac can’t run macOS \(image.operatingSystemVersion.majorVersion).")
        }
        let cpus = max(cpuCount ?? max(4, requirements.minimumSupportedCPUCount), requirements.minimumSupportedCPUCount)
        let memory = max(memoryBytes ?? max(.gibibytes(8), requirements.minimumSupportedMemorySize), requirements.minimumSupportedMemorySize)

        let bundle = try library.createMacMachine(
            name: name, hardwareModel: requirements.hardwareModel,
            cpuCount: cpus, memoryBytes: memory, diskBytes: diskBytes)
        do {
            try bundle.acquireRunLock()
            defer { bundle.releaseRunLock() }
            let configuration = try MachineBuilder.configuration(for: bundle)
            let machine = VZVirtualMachine(configuration: configuration)
            let installer = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: ipsw)
            self.installer = installer
            observation = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
                let fraction = progress.fractionCompleted
                Task { @MainActor in onPhase(.installing(fraction: fraction)) }
            }
            defer {
                observation = nil
                self.installer = nil
            }
            try await installer.install()
            if machine.canStop { try await machine.stop() }
            onPhase(.finished)
            return bundle
        } catch {
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
        }
    }
}

private extension VZMacOSRestoreImage {
    static var latestSupported: VZMacOSRestoreImage {
        get async throws {
            try await withCheckedThrowingContinuation { continuation in
                VZMacOSRestoreImage.fetchLatestSupported { continuation.resume(with: $0) }
            }
        }
    }

    static func image(from url: URL) async throws -> VZMacOSRestoreImage {
        try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.load(from: url) { continuation.resume(with: $0) }
        }
    }
}
