import Foundation
import Virtualization

/// The folder of machines and every operation that adds, copies or removes one.
public struct MachineLibrary: Sendable {
    public let rootURL: URL

    /// `BURROW_HOME` overrides the location, which keeps tests and scripts
    /// away from the user's real machines.
    public static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["BURROW_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Burrow/Machines", isDirectory: true)
    }

    public init(rootURL: URL = MachineLibrary.defaultRoot) {
        self.rootURL = rootURL
    }

    public func ensureRoot() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    public func machines() throws -> [MachineBundle] {
        try ensureRoot()
        return try FileManager.default
            .contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == MachineBundle.pathExtension }
            .map(MachineBundle.init(url:))
            .filter { FileManager.default.fileExists(atPath: $0.configURL.path) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func bundle(named name: String) throws -> MachineBundle {
        let bundle = MachineBundle(url: bundleURL(for: name))
        guard FileManager.default.fileExists(atPath: bundle.configURL.path) else {
            throw BurrowError.machineNotFound(name)
        }
        return bundle
    }

    public func bundleURL(for name: String) -> URL {
        rootURL.appendingPathComponent(name).appendingPathExtension(MachineBundle.pathExtension)
    }

    // MARK: Creating

    /// Lays out a Linux machine that boots through UEFI, optionally from an installer ISO.
    @discardableResult
    public func createLinuxMachine(
        name: String,
        installerISO: URL?,
        cpuCount: Int = 4,
        memoryBytes: UInt64 = .gibibytes(4),
        diskBytes: UInt64 = .gibibytes(64)
    ) throws -> MachineBundle {
        let bundle = try makeEmptyBundle(named: name)
        do {
            let format = DiskImage.preferredFormat()
            let usedFormat = try DiskImage.create(at: bundle.url.appendingPathComponent(format.fileName), bytes: diskBytes, format: format)
            _ = try VZEFIVariableStore(creatingVariableStoreAt: bundle.efiVariableStoreURL, options: [])
            try VZGenericMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifierURL)
            let config = MachineConfig(
                name: name,
                guest: .linux,
                cpuCount: cpuCount,
                memoryBytes: memoryBytes,
                diskBytes: diskBytes,
                diskFileName: usedFormat.fileName,
                macAddress: VZMACAddress.randomLocallyAdministered().string,
                installerImagePath: installerISO?.path,
                rosetta: LinuxRosetta.isInstalled
            )
            try bundle.saveConfig(config)
            return bundle
        } catch {
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
        }
    }

    /// Creates a ready-to-use Linux machine from a cloud image archive (a tarball holding a
    /// raw disk). cloud-init personalizes it on first boot; no installer runs.
    @discardableResult
    public func createCloudMachine(
        name: String,
        archive: URL,
        account: GuestAccount,
        desktop: Bool,
        cpuCount: Int = 4,
        memoryBytes: UInt64 = .gibibytes(4),
        diskBytes: UInt64 = .gibibytes(64)
    ) throws -> MachineBundle {
        try account.validate()
        let bundle = try makeEmptyBundle(named: name)
        let fm = FileManager.default
        do {
            let disk = bundle.url.appendingPathComponent(DiskImage.Format.raw.fileName)
            if QCOW2.isQCOW2(archive) {
                try QCOW2.convertToRaw(archive, destination: disk)
            } else {
                let staging = bundle.url.appendingPathComponent(".unpacking", isDirectory: true)
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: staging) }
                try DiskImage.run("/usr/bin/tar", ["-xf", archive.path, "-C", staging.path])
                // The disk is the archive's one large file (named *.img, *.raw or disk.raw).
                let files = fm.enumerator(at: staging, includingPropertiesForKeys: [.fileSizeKey])?
                    .compactMap { $0 as? URL } ?? []
                func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
                guard let image = files.max(by: { size($0) < size($1) }), size(image) > 256 << 20 else {
                    throw BurrowError.downloadFailed("The cloud image archive has no disk inside.")
                }
                try fm.moveItem(at: image, to: disk)
            }
            guard Self.hasPartitionTable(disk) else {
                throw BurrowError.downloadFailed("The cloud image isn’t a bootable disk (no partition table).")
            }
            // cloud-init grows the root partition into the extra space on first boot.
            if try DiskImage.logicalSize(of: disk) < diskBytes {
                try DiskImage.grow(at: disk, to: diskBytes)
            }

            _ = try VZEFIVariableStore(creatingVariableStoreAt: bundle.efiVariableStoreURL, options: [])
            try VZGenericMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifierURL)
            try CloudInitSeed.create(at: bundle.cloudInitSeedURL, account: account,
                                     hostname: CloudInitSeed.hostname(for: name), desktop: desktop)
            let config = MachineConfig(
                name: name,
                guest: .linux,
                cpuCount: cpuCount,
                memoryBytes: memoryBytes,
                diskBytes: max(diskBytes, try DiskImage.logicalSize(of: disk)),
                diskFileName: disk.lastPathComponent,
                macAddress: VZMACAddress.randomLocallyAdministered().string,
                rosetta: LinuxRosetta.isInstalled
            )
            try bundle.saveConfig(config)
            return bundle
        } catch {
            try? fm.removeItem(at: bundle.url)
            throw error
        }
    }

    /// A bootable disk starts with a protective MBR (0x55AA) and, for UEFI, a GPT header.
    static func hasPartitionTable(_ disk: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: disk) else { return false }
        defer { try? handle.close() }
        guard let first = try? handle.read(upToCount: 1024), first.count == 1024 else { return false }
        return first[510] == 0x55 && first[511] == 0xAA
    }

    /// Lays out a Windows 11 on ARM machine: UEFI firmware, an NVMe disk, the
    /// installer ISO plus Burrow's answer-file disc, and an optional virtio-win driver disc.
    @discardableResult
    public func createWindowsMachine(
        name: String,
        installerISO: URL,
        driversISO: URL?,
        account: GuestAccount? = nil,
        cpuCount: Int = 4,
        memoryBytes: UInt64 = .gibibytes(8),
        diskBytes: UInt64 = .gibibytes(80)
    ) throws -> MachineBundle {
        guard ImageCatalog.looksLikeDiscImage(installerISO) else {
            throw BurrowError.downloadFailed("The Windows installer “\(installerISO.lastPathComponent)” is incomplete or damaged. Delete it and download again.")
        }
        let bundle = try makeEmptyBundle(named: name)
        do {
            // Windows runs under QEMU, which reads raw disks but not ASIF.
            let usedFormat = try DiskImage.create(at: bundle.url.appendingPathComponent(DiskImage.Format.raw.fileName), bytes: diskBytes, format: .raw)
            _ = try VZEFIVariableStore(creatingVariableStoreAt: bundle.efiVariableStoreURL, options: [])
            try VZGenericMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifierURL)
            try account?.validate(requirePassword: false)
            let options = WindowsSetupMedia.Options(
                account: account,
                language: WindowsInstallerImage.language(of: installerISO) ?? "en-US",
                computerName: WindowsSetupMedia.computerName(for: name))
            try WindowsSetupMedia.create(at: bundle.windowsSetupMediaURL, options: options)
            var config = MachineConfig(
                name: name,
                guest: .windows,
                cpuCount: cpuCount,
                memoryBytes: memoryBytes,
                diskBytes: diskBytes,
                diskFileName: usedFormat.fileName,
                display: DisplaySpec(width: 1920, height: 1080, pixelsPerInch: 96),
                macAddress: VZMACAddress.randomLocallyAdministered().string,
                installerImagePath: installerISO.path,
                driversImagePath: driversISO?.path,
                clipboardSharing: false
            )
            config.windowsSetupRestartsRemaining = 6
            if let account, account.password.isEmpty {
                config.notes = "Windows account “\(account.username)” has no password. Add one in Windows Settings ▸ Accounts if you like."
            }
            try bundle.saveConfig(config)
            return bundle
        } catch {
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
        }
    }

    /// Lays out a macOS machine for `hardwareModel`; `MacInstaller` then restores an IPSW onto it.
    @discardableResult
    public func createMacMachine(
        name: String,
        hardwareModel: VZMacHardwareModel,
        cpuCount: Int,
        memoryBytes: UInt64,
        diskBytes: UInt64 = .gibibytes(80)
    ) throws -> MachineBundle {
        guard hardwareModel.isSupported else {
            throw BurrowError.unsupported("This Mac can’t run the macOS version in that restore image.")
        }
        let bundle = try makeEmptyBundle(named: name)
        do {
            let format = DiskImage.preferredFormat()
            let usedFormat = try DiskImage.create(at: bundle.url.appendingPathComponent(format.fileName), bytes: diskBytes, format: format)
            try hardwareModel.dataRepresentation.write(to: bundle.hardwareModelURL)
            _ = try VZMacAuxiliaryStorage(creatingStorageAt: bundle.auxiliaryStorageURL, hardwareModel: hardwareModel, options: [])
            try VZMacMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifierURL)
            let config = MachineConfig(
                name: name,
                guest: .macOS,
                cpuCount: cpuCount,
                memoryBytes: memoryBytes,
                diskBytes: diskBytes,
                diskFileName: usedFormat.fileName,
                display: DisplaySpec(width: 1920, height: 1200, pixelsPerInch: 144),
                macAddress: VZMACAddress.randomLocallyAdministered().string
            )
            try bundle.saveConfig(config)
            return bundle
        } catch {
            try? FileManager.default.removeItem(at: bundle.url)
            throw error
        }
    }

    // MARK: Copying and removing

    /// Copies a stopped machine as a new, independent machine. On APFS the
    /// disk is cloned, so the copy is instant and initially shares all blocks.
    @discardableResult
    public func cloneMachine(_ source: MachineBundle, as newName: String) throws -> MachineBundle {
        var config = try source.loadConfig()
        if source.isRunning { throw BurrowError.machineRunning(config.name) }
        try validate(name: newName)
        let destination = MachineBundle(url: bundleURL(for: newName))
        guard !FileManager.default.fileExists(atPath: destination.url.path) else {
            throw BurrowError.nameTaken(newName)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.url, withIntermediateDirectories: false)
        do {
            let skipped: Set<String> = [
                source.snapshotsURL.lastPathComponent,
                source.savedStateURL.lastPathComponent,
                source.runLockURL.lastPathComponent,
                source.consoleLogURL.lastPathComponent,
            ]
            for item in try fm.contentsOfDirectory(at: source.url, includingPropertiesForKeys: nil)
            where !skipped.contains(item.lastPathComponent) {
                try fm.copyItem(at: item, to: destination.url.appendingPathComponent(item.lastPathComponent))
            }
            // A clone is a different computer: new identity and network address.
            switch config.guest {
            case .linux, .windows: try VZGenericMachineIdentifier().dataRepresentation.write(to: destination.machineIdentifierURL)
            case .macOS: try VZMacMachineIdentifier().dataRepresentation.write(to: destination.machineIdentifierURL)
            }
            config.id = UUID()
            config.name = newName
            config.macAddress = VZMACAddress.randomLocallyAdministered().string
            config.createdAt = Date()
            try destination.saveConfig(config)
            return destination
        } catch {
            try? fm.removeItem(at: destination.url)
            throw error
        }
    }

    public func rename(_ bundle: MachineBundle, to newName: String) throws -> MachineBundle {
        var config = try bundle.loadConfig()
        if bundle.isRunning { throw BurrowError.machineRunning(config.name) }
        try validate(name: newName)
        let destination = MachineBundle(url: bundleURL(for: newName))
        guard !FileManager.default.fileExists(atPath: destination.url.path) else { throw BurrowError.nameTaken(newName) }
        try FileManager.default.moveItem(at: bundle.url, to: destination.url)
        config.name = newName
        try destination.saveConfig(config)
        return destination
    }

    /// Moves the machine to the Trash so a mistaken delete can be undone in Finder.
    public func trash(_ bundle: MachineBundle) throws {
        if bundle.isRunning { throw BurrowError.machineRunning(bundle.name) }
        try FileManager.default.trashItem(at: bundle.url, resultingItemURL: nil)
    }

    // MARK: Helpers

    public func validate(name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == name, !name.contains("/"), !name.contains(":"),
              !name.hasPrefix("."), name.count <= 100
        else { throw BurrowError.invalidName(name) }
    }

    /// First free name of the form "Base", "Base 2", "Base 3", …
    public func uniqueName(base: String) -> String {
        var candidate = base
        var counter = 2
        while FileManager.default.fileExists(atPath: bundleURL(for: candidate).path) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }

    private func makeEmptyBundle(named name: String) throws -> MachineBundle {
        try validate(name: name)
        try ensureRoot()
        let bundle = MachineBundle(url: bundleURL(for: name))
        guard !FileManager.default.fileExists(atPath: bundle.url.path) else { throw BurrowError.nameTaken(name) }
        try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: false)
        return bundle
    }
}

public enum LinuxRosetta {
    public static var isInstalled: Bool {
        VZLinuxRosettaDirectoryShare.availability == .installed
    }

    public static var isSupported: Bool {
        VZLinuxRosettaDirectoryShare.availability != .notSupported
    }

    /// Prompts macOS to install Rosetta for Linux guests.
    public static func install() async throws {
        try await VZLinuxRosettaDirectoryShare.installRosetta()
    }
}
