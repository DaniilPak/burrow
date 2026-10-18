import Foundation
import Virtualization

/// Turns a stored machine into a validated `VZVirtualMachineConfiguration`.
public enum MachineBuilder {
    /// Tag Linux guests mount for shared folders: `mount -t virtiofs burrow /mnt/burrow`.
    public static let linuxShareTag = "burrow"
    /// Tag Linux guests mount for Rosetta: `mount -t virtiofs rosetta /mnt/rosetta`.
    public static let rosettaTag = "rosetta"

    public struct Options: Sendable {
        /// Attach the Linux installer ISO, when the config names one.
        public var attachInstaller: Bool
        /// Ask Virtualization.framework to validate the result. Validation needs the
        /// `com.apple.security.virtualization` entitlement, so unsigned tools skip it.
        public var validate: Bool
        public init(attachInstaller: Bool = true, validate: Bool = true) {
            self.attachInstaller = attachInstaller
            self.validate = validate
        }
    }

    public static func configuration(for bundle: MachineBundle, options: Options = Options()) throws -> VZVirtualMachineConfiguration {
        let config = try bundle.loadConfig()
        let vz = VZVirtualMachineConfiguration()
        vz.cpuCount = clampCPU(config.cpuCount)
        vz.memorySize = clampMemory(config.memoryBytes)

        switch config.guest {
        case .linux: try configureLinux(vz, bundle: bundle, config: config, options: options)
        case .windows: try configureWindows(vz, bundle: bundle, config: config, options: options)
        case .macOS: try configureMac(vz, bundle: bundle, config: config)
        }

        let disk = bundle.diskURL(for: config)
        guard FileManager.default.fileExists(atPath: disk.path) else { throw BurrowError.missingFile(disk.path) }
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: disk, readOnly: false, cachingMode: .automatic, synchronizationMode: .fsync)
        // Windows ships an NVMe driver but none for virtio-blk, so it can install without extra drivers.
        let systemDisk: VZStorageDeviceConfiguration = config.guest == .windows
            ? VZNVMExpressControllerDeviceConfiguration(attachment: diskAttachment)
            : VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
        vz.storageDevices.insert(systemDisk, at: 0)

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        if let address = VZMACAddress(string: config.macAddress) { network.macAddress = address }
        vz.networkDevices = [network]

        vz.audioDevices = [audioDevice(input: config.audioInput)]
        vz.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vz.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        if config.clipboardSharing { vz.consoleDevices.append(clipboardDevice()) }

        do {
            if options.validate { try vz.validate() }
        } catch {
            throw BurrowError.invalidConfiguration(error.localizedDescription)
        }
        return vz
    }

    /// Whether this configuration can be suspended to disk and resumed.
    public static func supportsSuspend(_ configuration: VZVirtualMachineConfiguration) -> Bool {
        (try? configuration.validateSaveRestoreSupport()) != nil
    }

    // MARK: Guests

    /// Platform, firmware, display and input shared by Linux and Windows guests.
    private static func configureUEFIMachine(_ vz: VZVirtualMachineConfiguration, bundle: MachineBundle, config: MachineConfig) throws {
        let platform = VZGenericPlatformConfiguration()
        guard let identifierData = try? Data(contentsOf: bundle.machineIdentifierURL),
              let identifier = VZGenericMachineIdentifier(dataRepresentation: identifierData)
        else { throw BurrowError.missingFile(bundle.machineIdentifierURL.path) }
        platform.machineIdentifier = identifier
        vz.platform = platform

        guard FileManager.default.fileExists(atPath: bundle.efiVariableStoreURL.path) else {
            throw BurrowError.missingFile(bundle.efiVariableStoreURL.path)
        }
        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = VZEFIVariableStore(url: bundle.efiVariableStoreURL)
        vz.bootLoader = bootLoader

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: config.display.width, heightInPixels: config.display.height)]
        vz.graphicsDevices = [graphics]
        vz.keyboards = [VZUSBKeyboardConfiguration()]
        vz.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    }

    private static func attachRemovable(_ path: String, to vz: VZVirtualMachineConfiguration) throws {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw BurrowError.missingFile(url.path) }
        let attachment = try VZDiskImageStorageDeviceAttachment(url: url, readOnly: true)
        vz.storageDevices.append(VZUSBMassStorageDeviceConfiguration(attachment: attachment))
    }

    private static func configureWindows(_ vz: VZVirtualMachineConfiguration, bundle: MachineBundle, config: MachineConfig, options: Options) throws {
        try configureUEFIMachine(vz, bundle: bundle, config: config)
        if options.attachInstaller, let installer = config.installerImagePath {
            try attachRemovable(installer, to: vz)
            // Burrow's answer file rides along with the installer; Setup finds it on any removable drive.
            if FileManager.default.fileExists(atPath: bundle.windowsSetupMediaURL.path) {
                try attachRemovable(bundle.windowsSetupMediaURL.path, to: vz)
            }
        }
        if let drivers = config.driversImagePath {
            try attachRemovable(drivers, to: vz)
        }
        // virtio-fs reaches Windows through virtio-win's viofs driver plus WinFsp.
        if let share = try directoryShare(for: config.sharedFolders) {
            let device = VZVirtioFileSystemDeviceConfiguration(tag: linuxShareTag)
            device.share = share
            vz.directorySharingDevices.append(device)
        }
    }

    private static func configureLinux(_ vz: VZVirtualMachineConfiguration, bundle: MachineBundle, config: MachineConfig, options: Options) throws {
        try configureUEFIMachine(vz, bundle: bundle, config: config)

        if options.attachInstaller, let path = config.installerImagePath {
            try attachRemovable(path, to: vz)
        }
        // cloud-init only acts on a seed once per instance, so it can stay attached.
        if FileManager.default.fileExists(atPath: bundle.cloudInitSeedURL.path) {
            try attachRemovable(bundle.cloudInitSeedURL.path, to: vz)
        }

        if let share = try directoryShare(for: config.sharedFolders) {
            let device = VZVirtioFileSystemDeviceConfiguration(tag: linuxShareTag)
            device.share = share
            vz.directorySharingDevices.append(device)
        }
        if config.rosetta, LinuxRosetta.isInstalled {
            let device = VZVirtioFileSystemDeviceConfiguration(tag: rosettaTag)
            device.share = try VZLinuxRosettaDirectoryShare()
            vz.directorySharingDevices.append(device)
        }

        // Serial console goes to a log file, which helps diagnose boot problems.
        FileManager.default.createFile(atPath: bundle.consoleLogURL.path, contents: nil)
        if let log = try? FileHandle(forWritingTo: bundle.consoleLogURL) {
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: log)
            vz.serialPorts = [serial]
        }
    }

    private static func configureMac(_ vz: VZVirtualMachineConfiguration, bundle: MachineBundle, config: MachineConfig) throws {
        let platform = VZMacPlatformConfiguration()
        guard let modelData = try? Data(contentsOf: bundle.hardwareModelURL),
              let model = VZMacHardwareModel(dataRepresentation: modelData)
        else { throw BurrowError.missingFile(bundle.hardwareModelURL.path) }
        guard model.isSupported else {
            throw BurrowError.unsupported("This Mac doesn’t support the hardware model “\(config.name)” was installed for.")
        }
        guard let identifierData = try? Data(contentsOf: bundle.machineIdentifierURL),
              let identifier = VZMacMachineIdentifier(dataRepresentation: identifierData)
        else { throw BurrowError.missingFile(bundle.machineIdentifierURL.path) }
        platform.hardwareModel = model
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxiliaryStorageURL)
        vz.platform = platform
        vz.bootLoader = VZMacOSBootLoader()

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(
            widthInPixels: config.display.width,
            heightInPixels: config.display.height,
            pixelsPerInch: config.display.pixelsPerInch)]
        vz.graphicsDevices = [graphics]
        vz.keyboards = [VZMacKeyboardConfiguration()]
        vz.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]

        if let share = try directoryShare(for: config.sharedFolders) {
            // macOS guests mount this tag automatically under /Volumes/My Shared Files.
            let device = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
            device.share = share
            vz.directorySharingDevices.append(device)
        }
    }

    // MARK: Devices

    private static func directoryShare(for folders: [SharedFolder]) throws -> VZDirectoryShare? {
        guard !folders.isEmpty else { return nil }
        var directories: [String: VZSharedDirectory] = [:]
        for folder in folders {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.hostPath, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw BurrowError.missingFile(folder.hostPath)
            }
            directories[folder.name] = VZSharedDirectory(url: URL(fileURLWithPath: folder.hostPath), readOnly: folder.readOnly)
        }
        return VZMultipleDirectoryShare(directories: directories)
    }

    private static func audioDevice(input: Bool) -> VZVirtioSoundDeviceConfiguration {
        let sound = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        sound.streams = [output]
        if input {
            let microphone = VZVirtioSoundDeviceInputStreamConfiguration()
            microphone.source = VZHostAudioInputStreamSource()
            sound.streams.append(microphone)
        }
        return sound
    }

    /// SPICE agent port; guests running spice-vdagent (Linux) share the clipboard through it.
    private static func clipboardDevice() -> VZVirtioConsoleDeviceConfiguration {
        let console = VZVirtioConsoleDeviceConfiguration()
        let port = VZVirtioConsolePortConfiguration()
        port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
        let agent = VZSpiceAgentPortAttachment()
        agent.sharesClipboard = true
        port.attachment = agent
        console.ports[0] = port
        return console
    }

    // MARK: Limits

    public static var cpuRange: ClosedRange<Int> {
        VZVirtualMachineConfiguration.minimumAllowedCPUCount...VZVirtualMachineConfiguration.maximumAllowedCPUCount
    }

    public static var memoryRange: ClosedRange<UInt64> {
        VZVirtualMachineConfiguration.minimumAllowedMemorySize...VZVirtualMachineConfiguration.maximumAllowedMemorySize
    }

    static func clampCPU(_ count: Int) -> Int {
        min(max(count, cpuRange.lowerBound), cpuRange.upperBound)
    }

    static func clampMemory(_ bytes: UInt64) -> UInt64 {
        // Memory must be a multiple of 1 MiB.
        let rounded = bytes / (1 << 20) * (1 << 20)
        return min(max(rounded, memoryRange.lowerBound), memoryRange.upperBound)
    }
}
