import Foundation

public struct Snapshot: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var createdAt: Date
    /// Configuration at the time of the snapshot, restored with it.
    public var config: MachineConfig
}

/// Point-in-time copies of a stopped machine's disk and firmware state.
///
/// Snapshots are APFS clones, so taking one is instant and costs no space
/// until the guest writes new blocks.
public struct SnapshotStore {
    public let bundle: MachineBundle

    public init(bundle: MachineBundle) {
        self.bundle = bundle
    }

    public func list() throws -> [Snapshot] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundle.snapshotsURL.path) else { return [] }
        return try fm.contentsOfDirectory(at: bundle.snapshotsURL, includingPropertiesForKeys: nil)
            .compactMap { directory -> Snapshot? in
                let metadata = directory.appendingPathComponent("snapshot.json")
                guard let data = try? Data(contentsOf: metadata) else { return nil }
                return try MachineBundle.decoder.decode(Snapshot.self, from: data)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    public func take(label: String) throws -> Snapshot {
        let config = try bundle.loadConfig()
        try requireStopped(config)
        let snapshot = Snapshot(id: UUID(), label: label, createdAt: Date(), config: config)
        let directory = directory(for: snapshot.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            for file in stateFiles(for: config) {
                try FileManager.default.copyItem(at: file, to: directory.appendingPathComponent(file.lastPathComponent))
            }
            try MachineBundle.encoder.encode(snapshot).write(to: directory.appendingPathComponent("snapshot.json"))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return snapshot
    }

    /// Replaces the machine's disk, firmware state and configuration with the snapshot's.
    public func restore(_ id: UUID) throws {
        let current = try bundle.loadConfig()
        try requireStopped(current)
        guard let snapshot = try list().first(where: { $0.id == id }) else {
            throw BurrowError.snapshotNotFound(id.uuidString)
        }
        let directory = directory(for: id)
        let fm = FileManager.default
        for file in stateFiles(for: snapshot.config) {
            let source = directory.appendingPathComponent(file.lastPathComponent)
            guard fm.fileExists(atPath: source.path) else { throw BurrowError.missingFile(source.path) }
            let staged = file.appendingPathExtension("restoring")
            try? fm.removeItem(at: staged)
            try fm.copyItem(at: source, to: staged)
            if fm.fileExists(atPath: file.path) {
                _ = try fm.replaceItemAt(file, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: file)
            }
        }
        // The current disk may use another file name if the snapshot predates a format change.
        if current.diskFileName != snapshot.config.diskFileName {
            try? fm.removeItem(at: bundle.diskURL(for: current))
        }
        var restored = snapshot.config
        restored.name = current.name
        try bundle.saveConfig(restored)
        // A suspended session refers to the old disk contents.
        bundle.discardSavedState()
    }

    public func delete(_ id: UUID) throws {
        let directory = directory(for: id)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw BurrowError.snapshotNotFound(id.uuidString)
        }
        try FileManager.default.removeItem(at: directory)
    }

    private func directory(for id: UUID) -> URL {
        bundle.snapshotsURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func requireStopped(_ config: MachineConfig) throws {
        if bundle.isRunning { throw BurrowError.machineRunning(config.name) }
        if bundle.hasSavedState {
            throw BurrowError.unsupported("“\(config.name)” is suspended. Resume and shut it down, or discard the suspended state, before using snapshots.")
        }
    }

    private func stateFiles(for config: MachineConfig) -> [URL] {
        var files = [bundle.diskURL(for: config)]
        switch config.guest {
        case .linux, .windows: files.append(bundle.efiVariableStoreURL)
        case .macOS: files.append(bundle.auxiliaryStorageURL)
        }
        return files.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
