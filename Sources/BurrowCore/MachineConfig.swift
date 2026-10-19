import Foundation

/// The kind of operating system a machine runs. It decides the platform,
/// boot loader and device set the engine assembles.
public enum GuestOS: String, Codable, CaseIterable, Sendable {
    case linux
    case windows
    case macOS

    public var displayName: String {
        switch self {
        case .linux: "Linux"
        case .windows: "Windows"
        case .macOS: "macOS"
        }
    }

    /// Linux and Windows boot through Burrow's UEFI firmware; macOS uses Apple's boot loader.
    public var usesUEFI: Bool { self != .macOS }
}

/// How a Windows machine's screen trades sharpness for speed.
public enum WindowsDisplayMode: String, Codable, CaseIterable, Sendable {
    /// Every Retina pixel: sharpest, slowest.
    case sharp
    /// 1.5 Windows pixels per point and visual effects off.
    case balanced
    /// One Windows pixel per point (a quarter of Retina's) and visual effects off.
    case fast

    /// Windows pixels per macOS point, capped by the screen's own density.
    public func pixelsPerPoint(screenScale: Double) -> Double {
        switch self {
        case .sharp: screenScale
        case .balanced: min(1.5, screenScale)
        case .fast: 1
        }
    }

    /// Whether Burrow Tools turns off Windows' animations, shadows and transparency.
    public var turnsOffEffects: Bool { self != .sharp }

    public var title: String {
        switch self {
        case .sharp: "Sharp"
        case .balanced: "Balanced"
        case .fast: "Fast"
        }
    }

    public var summary: String {
        switch self {
        case .sharp: "Full Retina resolution, all effects. Sharpest, uses the most CPU."
        case .balanced: "1.5× resolution, effects off. Nearly as crisp, noticeably lighter."
        case .fast: "Half resolution, effects off. Softer text, smoothest and lightest."
        }
    }
}

public struct DisplaySpec: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var pixelsPerInch: Int

    public init(width: Int = 1920, height: Int = 1200, pixelsPerInch: Int = 144) {
        self.width = width
        self.height = height
        self.pixelsPerInch = pixelsPerInch
    }
}

public struct SharedFolder: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    /// Name the guest sees inside the share (one path component).
    public var name: String
    public var hostPath: String
    public var readOnly: Bool

    public init(name: String, hostPath: String, readOnly: Bool = false) {
        self.name = name
        self.hostPath = hostPath
        self.readOnly = readOnly
    }
}

/// Everything persisted about one machine, stored as `machine.json` in its bundle.
public struct MachineConfig: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var guest: GuestOS
    public var cpuCount: Int
    public var memoryBytes: UInt64
    public var diskBytes: UInt64
    public var diskFileName: String
    public var display: DisplaySpec
    public var macAddress: String
    /// Linux and Windows: ISO attached as a removable USB drive while installing.
    public var installerImagePath: String?
    /// Windows: virtio-win driver ISO, attached until removed. Its ARM64 drivers
    /// (networking, balloon, serial, …) are installed automatically at first sign-in.
    public var driversImagePath: String?
    /// Windows: guest reboots Burrow still treats as part of Setup and restarts through.
    /// Virtualization.framework stops a machine when its guest reboots, and Setup reboots
    /// a few times. Nil once Setup is over.
    public var windowsSetupRestartsRemaining: Int?
    /// Windows: how many pixels Windows draws, trading sharpness for speed (Windows draws
    /// every pixel with the CPU). Nil means `.sharp`.
    public var windowsDisplayMode: WindowsDisplayMode?
    public var sharedFolders: [SharedFolder]
    public var rosetta: Bool
    public var clipboardSharing: Bool
    public var audioInput: Bool
    public var createdAt: Date
    public var notes: String

    public init(
        id: UUID = UUID(),
        name: String,
        guest: GuestOS,
        cpuCount: Int = 4,
        memoryBytes: UInt64 = 4 << 30,
        diskBytes: UInt64 = 64 << 30,
        diskFileName: String = "disk.img",
        display: DisplaySpec = DisplaySpec(),
        macAddress: String,
        installerImagePath: String? = nil,
        driversImagePath: String? = nil,
        sharedFolders: [SharedFolder] = [],
        rosetta: Bool = false,
        clipboardSharing: Bool = true,
        audioInput: Bool = false,
        createdAt: Date = Date(),
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.guest = guest
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.diskFileName = diskFileName
        self.display = display
        self.macAddress = macAddress
        self.installerImagePath = installerImagePath
        self.driversImagePath = driversImagePath
        self.sharedFolders = sharedFolders
        self.rosetta = rosetta
        self.clipboardSharing = clipboardSharing
        self.audioInput = audioInput
        self.createdAt = createdAt
        self.notes = notes
    }
}

public extension UInt64 {
    static func gibibytes(_ n: Int) -> UInt64 { UInt64(n) << 30 }
    var gibibytes: Double { Double(self) / Double(1 << 30) }
}
