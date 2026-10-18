import Foundation

/// A machine on disk: a `<name>.burrow` directory holding its configuration,
/// disk, firmware state, saved run state and snapshots.
public struct MachineBundle: Sendable, Identifiable, Hashable {
    public static let pathExtension = "burrow"

    public let url: URL
    public var id: URL { url }

    /// The URL is normalized (symlinks resolved, no trailing slash) so bundles
    /// found by listing a directory compare equal to ones built from a name.
    public init(url: URL) {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        self.url = URL(filePath: path, directoryHint: .notDirectory)
    }

    /// Machine name, taken from the bundle's folder name.
    public var name: String { url.deletingPathExtension().lastPathComponent }

    // MARK: Layout

    public var configURL: URL { url.appendingPathComponent("machine.json") }
    public var machineIdentifierURL: URL { url.appendingPathComponent("machine-identifier.bin") }
    /// Linux: UEFI variable store.
    public var efiVariableStoreURL: URL { url.appendingPathComponent("efi-variables.fd") }
    /// Linux cloud images: cloud-init seed with the account and first-boot setup.
    public var cloudInitSeedURL: URL { url.appendingPathComponent("cloud-init.iso") }
    /// Windows: Burrow's generated answer-file disc, attached alongside the installer.
    public var windowsSetupMediaURL: URL { url.appendingPathComponent("windows-setup.iso") }
    /// macOS: hardware model the guest was installed for.
    public var hardwareModelURL: URL { url.appendingPathComponent("hardware-model.bin") }
    /// macOS: auxiliary storage (boot policy, NVRAM).
    public var auxiliaryStorageURL: URL { url.appendingPathComponent("auxiliary-storage.img") }
    /// Memory and device state written by Suspend, consumed by the next start.
    public var savedStateURL: URL { url.appendingPathComponent("suspended.vzvmsave") }
    public var snapshotsURL: URL { url.appendingPathComponent("snapshots", isDirectory: true) }
    public var consoleLogURL: URL { url.appendingPathComponent("console.log") }
    var runLockURL: URL { url.appendingPathComponent(".running") }

    public func diskURL(for config: MachineConfig) -> URL {
        url.appendingPathComponent(config.diskFileName)
    }

    // MARK: Configuration

    public func loadConfig() throws -> MachineConfig {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw BurrowError.missingFile(configURL.path)
        }
        return try Self.decoder.decode(MachineConfig.self, from: Data(contentsOf: configURL))
    }

    public func saveConfig(_ config: MachineConfig) throws {
        try Self.encoder.encode(config).write(to: configURL, options: .atomic)
    }

    public var hasSavedState: Bool {
        FileManager.default.fileExists(atPath: savedStateURL.path)
    }

    public func discardSavedState() {
        try? FileManager.default.removeItem(at: savedStateURL)
    }

    // MARK: Running lock

    /// Records the process that is running this machine so other processes
    /// (the CLI, a second app instance) refuse to modify it underneath.
    public func acquireRunLock() throws {
        if let owner = runningProcessID, owner != getpid() {
            throw BurrowError.machineRunning(name)
        }
        try String(getpid()).write(to: runLockURL, atomically: true, encoding: .utf8)
    }

    public func releaseRunLock() {
        if runningProcessID == getpid() || runningProcessID == nil {
            try? FileManager.default.removeItem(at: runLockURL)
        }
    }

    /// PID of a live process holding the lock; stale locks are ignored.
    public var runningProcessID: pid_t? {
        guard let text = try? String(contentsOf: runLockURL, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              kill(pid, 0) == 0 || errno == EPERM
        else { return nil }
        return pid
    }

    public var isRunning: Bool { runningProcessID != nil }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
