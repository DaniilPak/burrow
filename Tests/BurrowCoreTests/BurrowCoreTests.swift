@testable import BurrowCore
import Foundation
import Virtualization
import XCTest

final class BurrowCoreTests: XCTestCase {
    private var root: URL!
    private var library: MachineLibrary!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-tests-\(UUID().uuidString)")
        library = MachineLibrary(rootURL: root)
        try library.ensureRoot()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testConfigRoundTrip() throws {
        let bundle = try library.createLinuxMachine(name: "Round Trip", installerISO: nil, diskBytes: .gibibytes(1))
        var config = try bundle.loadConfig()
        config.sharedFolders = [SharedFolder(name: "src", hostPath: "/tmp", readOnly: true)]
        config.notes = "hello"
        try bundle.saveConfig(config)
        XCTAssertEqual(try bundle.loadConfig(), config)
    }

    func testLinuxMachineLayout() throws {
        let bundle = try library.createLinuxMachine(name: "Layout", installerISO: nil, cpuCount: 2,
                                                    memoryBytes: .gibibytes(2), diskBytes: .gibibytes(4))
        let config = try bundle.loadConfig()
        XCTAssertEqual(config.guest, .linux)
        XCTAssertEqual(config.cpuCount, 2)
        for file in [bundle.configURL, bundle.efiVariableStoreURL, bundle.machineIdentifierURL, bundle.diskURL(for: config)] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.lastPathComponent)
        }
        XCTAssertEqual(try DiskImage.logicalSize(of: bundle.diskURL(for: config)), .gibibytes(4))
        // Sparse: a fresh 4 GiB disk must occupy far less than that.
        XCTAssertLessThan(DiskImage.allocatedSize(of: bundle.diskURL(for: config)), 64 << 20)
        XCTAssertEqual(try library.machines(), [bundle])
        XCTAssertEqual(try library.bundle(named: "Layout"), bundle)
    }

    func testBuildsValidVirtualizationConfiguration() throws {
        let bundle = try library.createLinuxMachine(name: "Valid", installerISO: nil, diskBytes: .gibibytes(1))
        var config = try bundle.loadConfig()
        config.sharedFolders = [SharedFolder(name: "tmp", hostPath: NSTemporaryDirectory())]
        try bundle.saveConfig(config)
        let vz = try MachineBuilder.configuration(for: bundle, options: .init(validate: false))
        XCTAssertEqual(vz.cpuCount, config.cpuCount)
        XCTAssertEqual(vz.directorySharingDevices.count, config.rosetta ? 2 : 1)
        XCTAssertEqual(vz.storageDevices.count, 1)
    }

    func testRejectsBadNamesAndDuplicates() throws {
        XCTAssertThrowsError(try library.createLinuxMachine(name: "a/b", installerISO: nil, diskBytes: .gibibytes(1)))
        XCTAssertThrowsError(try library.createLinuxMachine(name: " padded", installerISO: nil, diskBytes: .gibibytes(1)))
        try library.createLinuxMachine(name: "Twin", installerISO: nil, diskBytes: .gibibytes(1))
        XCTAssertThrowsError(try library.createLinuxMachine(name: "Twin", installerISO: nil, diskBytes: .gibibytes(1))) {
            XCTAssertEqual($0 as? BurrowError, .nameTaken("Twin"))
        }
        XCTAssertEqual(library.uniqueName(base: "Twin"), "Twin 2")
    }

    func testCloneGetsNewIdentity() throws {
        let source = try library.createLinuxMachine(name: "Original", installerISO: nil, diskBytes: .gibibytes(1))
        let clone = try library.cloneMachine(source, as: "Copy")
        let a = try source.loadConfig()
        let b = try clone.loadConfig()
        XCTAssertEqual(b.name, "Copy")
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.macAddress, b.macAddress)
        XCTAssertNotEqual(try Data(contentsOf: source.machineIdentifierURL), try Data(contentsOf: clone.machineIdentifierURL))
        XCTAssertEqual(a.cpuCount, b.cpuCount)
        XCTAssertNoThrow(try MachineBuilder.configuration(for: clone, options: .init(validate: false)))
    }

    func testSnapshotRestoresDiskContents() throws {
        let bundle = try library.createLinuxMachine(name: "Snappy", installerISO: nil, diskBytes: .gibibytes(1))
        let disk = bundle.diskURL(for: try bundle.loadConfig())
        try write("before", to: disk)
        let store = SnapshotStore(bundle: bundle)
        let snapshot = try store.take(label: "clean")
        try write("after!", to: disk)

        var config = try bundle.loadConfig()
        config.cpuCount = 7
        try bundle.saveConfig(config)

        try store.restore(snapshot.id)
        XCTAssertEqual(try read(6, from: disk), "before")
        XCTAssertEqual(try bundle.loadConfig().cpuCount, snapshot.config.cpuCount)
        XCTAssertEqual(try store.list().map(\.id), [snapshot.id])
        try store.delete(snapshot.id)
        XCTAssertTrue(try store.list().isEmpty)
    }

    func testRunLockBlocksModification() throws {
        let bundle = try library.createLinuxMachine(name: "Busy", installerISO: nil, diskBytes: .gibibytes(1))
        // Pretend another live process (launchd, PID 1) is running the machine.
        try "1".write(to: bundle.runLockURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(bundle.isRunning)
        XCTAssertThrowsError(try library.cloneMachine(bundle, as: "Nope"))
        XCTAssertThrowsError(try SnapshotStore(bundle: bundle).take(label: "x"))
        XCTAssertThrowsError(try bundle.acquireRunLock())
        // A lock left by a dead process is ignored.
        try "999999".write(to: bundle.runLockURL, atomically: true, encoding: .utf8)
        XCTAssertFalse(bundle.isRunning)
    }

    func testDiskGrowsButNeverShrinks() throws {
        let bundle = try library.createLinuxMachine(name: "Grow", installerISO: nil, diskBytes: .gibibytes(1))
        let disk = bundle.diskURL(for: try bundle.loadConfig())
        try DiskImage.grow(at: disk, to: .gibibytes(2))
        XCTAssertEqual(try DiskImage.logicalSize(of: disk), .gibibytes(2))
        XCTAssertThrowsError(try DiskImage.grow(at: disk, to: .gibibytes(1)))
    }

    func testWindowsMachineLayout() throws {
        let iso = root.appendingPathComponent("Win11_ARM64.iso")
        let drivers = root.appendingPathComponent("virtio-win.iso")
        try Self.fakeISO(at: iso)
        try Self.fakeISO(at: drivers)

        let bundle = try library.createWindowsMachine(name: "Windows", installerISO: iso, driversISO: drivers,
                                                      cpuCount: 4, memoryBytes: .gibibytes(8), diskBytes: .gibibytes(2))
        let config = try bundle.loadConfig()
        XCTAssertEqual(config.guest, .windows)
        XCTAssertEqual(config.installerImagePath, iso.path)
        XCTAssertEqual(config.driversImagePath, drivers.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.windowsSetupMediaURL.path))

        let vz = try MachineBuilder.configuration(for: bundle, options: .init(validate: false))
        // NVMe system disk, then installer, answer-file disc and driver disc on USB.
        XCTAssertEqual(vz.storageDevices.count, 4)
        XCTAssertTrue(vz.storageDevices[0] is VZNVMExpressControllerDeviceConfiguration)
        XCTAssertTrue(vz.storageDevices.dropFirst().allSatisfy { $0 is VZUSBMassStorageDeviceConfiguration })
        XCTAssertTrue(vz.bootLoader is VZEFIBootLoader)

        // After ejecting the installer only the driver disc stays.
        let ejected = try MachineBuilder.configuration(for: bundle, options: .init(attachInstaller: false, validate: false))
        XCTAssertEqual(ejected.storageDevices.count, 2)

        let clone = try library.cloneMachine(bundle, as: "Windows Copy")
        XCTAssertEqual(try clone.loadConfig().guest, .windows)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clone.windowsSetupMediaURL.path))
    }

    func testWindowsAnswerFile() throws {
        let xml = WindowsSetupMedia.answerFile()
        let document = try XMLDocument(xmlString: xml)
        XCTAssertFalse(xml.contains("<DiskConfiguration>"), "Without an account Setup must ask about the disk")
        XCTAssertEqual(document.rootElement()?.name, "unattend")
        for check in ["BypassTPMCheck", "BypassSecureBootCheck", "BypassNRO", "HideOnlineAccountScreens", "pnputil /add-driver"] {
            XCTAssertTrue(xml.contains(check), check)
        }
        XCTAssertFalse(xml.contains("<Password>"), "The answer file must not contain credentials")
        XCTAssertFalse(xml.contains("<ProductKey>"))
    }

    func testChecksumParsing() {
        let ubuntu = """
        c2afd538d66fdd77377d03f1ed2ac76a34f1c116baecc9a8170d68f833121f57 *ubuntu-26.04-desktop-arm64.iso
        c9aa567e6560b2eddae3af03fc686002e35b6fee96f97fd5df3271e846439fdd *ubuntu-26.04-live-server-arm64.iso
        """
        XCTAssertEqual(ImageCatalog.checksum(for: "ubuntu-26.04-live-server-arm64.iso", in: ubuntu)?.prefix(8), "c9aa567e")
        let debian = "6e93fa1759bd9d4b0fc11e938987de6967ee7de5297dac1be27c3a75cc17024b  debian-13.7.0-arm64-netinst.iso"
        XCTAssertEqual(ImageCatalog.checksum(for: "debian-13.7.0-arm64-netinst.iso", in: debian)?.prefix(8), "6e93fa17")
        XCTAssertNil(ImageCatalog.checksum(for: "missing.iso", in: ubuntu))
    }

    func testDiscImageDetectionAndHashing() throws {
        let iso = root.appendingPathComponent("real.iso")
        try Self.fakeISO(at: iso)
        XCTAssertTrue(ImageCatalog.looksLikeDiscImage(iso))

        // A download cut off partway keeps a valid header but is shorter than declared.
        let truncated = root.appendingPathComponent("cut.iso")
        let handle = try FileHandle(forReadingFrom: iso)
        try handle.read(upToCount: 0x9000)!.write(to: truncated)
        try handle.close()
        XCTAssertFalse(ImageCatalog.looksLikeDiscImage(truncated))

        let page = root.appendingPathComponent("error.iso")
        try Data("<html>Access denied</html>".utf8).write(to: page)
        XCTAssertFalse(ImageCatalog.looksLikeDiscImage(page))

        XCTAssertEqual(try FileDownloader.sha256(of: root.appendingPathComponent("empty").create()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testUnattendedWindowsAnswerFile() throws {
        let account = GuestAccount(fullName: "Ada <Lovelace>", username: "ada", password: "p&ss\"word")
        let options = WindowsSetupMedia.Options(account: account, language: "de-DE", computerName: "WIN11")
        let xml = WindowsSetupMedia.answerFile(options)
        let document = try XMLDocument(xmlString: xml)   // special characters must be escaped
        let passwords = try document.nodes(forXPath: "//*[local-name()='Password']/*[local-name()='Value']").map(\.stringValue)
        XCTAssertEqual(passwords, ["p&ss\"word", "p&ss\"word"])
        for expected in ["<DiskID>0</DiskID>", "<WillWipeDisk>true</WillWipeDisk>", "<UILanguage>de-DE</UILanguage>",
                         "<ComputerName>WIN11</ComputerName>", "<Group>Administrators</Group>",
                         "<HideLocalAccountScreen>true</HideLocalAccountScreen>", WindowsSetupMedia.proInstallKey] {
            XCTAssertTrue(xml.contains(expected), expected)
        }
        XCTAssertEqual(WindowsSetupMedia.computerName(for: "My Windows 11 machine!"), "MY-WINDOWS-11-M")
    }

    func testLangINIParsing() {
        let ini = "[Available UI Languages]\r\nen-us = 3\r\n\r\n[Fallback Languages]\r\nen-us = en-us\r\n"
        XCTAssertEqual(WindowsInstallerImage.parseLangINI(ini), "en-US")
        XCTAssertEqual(WindowsInstallerImage.parseLangINI("[Available UI Languages]\nzh-tw = 3\n"), "zh-TW")
        XCTAssertNil(WindowsInstallerImage.parseLangINI("[Other]\nx=1"))
    }

    func testWindowsSetupRestartBookkeeping() throws {
        let iso = root.appendingPathComponent("w.iso")
        try Self.fakeISO(at: iso)
        let bundle = try library.createWindowsMachine(
            name: "Unattended", installerISO: iso, driversISO: nil,
            account: GuestAccount(fullName: "T", username: "tester", password: "secret"), diskBytes: .gibibytes(2))
        let config = try bundle.loadConfig()
        XCTAssertEqual(config.windowsSetupRestartsRemaining, 6)
        let attributes = try FileManager.default.attributesOfItem(atPath: bundle.windowsSetupMediaURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "setup disc holds a password")
        XCTAssertThrowsError(try library.createWindowsMachine(
            name: "Bad", installerISO: iso, driversISO: nil,
            account: GuestAccount(fullName: "", username: "Bad Name", password: "x"), diskBytes: .gibibytes(2)))
    }

    func testRawDiskFallback() throws {
        let url = root.appendingPathComponent("raw.img")
        XCTAssertEqual(try DiskImage.create(at: url, bytes: .gibibytes(1), format: .raw), .raw)
        XCTAssertEqual(try DiskImage.logicalSize(of: url), .gibibytes(1))
    }

    private func write(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func read(_ count: Int, from url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return String(decoding: try handle.read(upToCount: count) ?? Data(), as: UTF8.self)
    }
}

extension BurrowCoreTests {
    /// A minimal ISO 9660 image: 1 MiB declared and present, with a primary volume descriptor.
    static func fakeISO(at url: URL) throws {
        var bytes = Data(count: 1 << 20)
        bytes[0x8000] = 1
        bytes.replaceSubrange(0x8001..<0x8006, with: Data("CD001".utf8))
        let blocks = UInt32((1 << 20) / 2048)
        bytes.replaceSubrange(0x8050..<0x8054, with: withUnsafeBytes(of: blocks.littleEndian) { Data($0) })
        bytes.replaceSubrange(0x8080..<0x8082, with: withUnsafeBytes(of: UInt16(2048).littleEndian) { Data($0) })
        try bytes.write(to: url)
    }
}

private extension URL {
    func create() throws -> URL {
        try Data().write(to: self)
        return self
    }

    // MARK: Windows under QEMU

    func testToolsDisplayKeepsEvenSaneDimensions() {
        let display = BurrowTools.Display(width: 3025, height: 1901, scalePercent: 200)
        XCTAssertEqual(display.width, 3024)
        XCTAssertEqual(display.height, 1900)
        let tiny = BurrowTools.Display(width: 10, height: 10, scalePercent: 100)
        XCTAssertEqual(tiny.width, 1024)
        XCTAssertEqual(tiny.height, 768)
    }

    func testAnswerFileInstallsBurrowToolsAtFirstSignIn() {
        let xml = WindowsSetupMedia.answerFile()
        XCTAssertTrue(xml.contains("burrow-install.cmd"))
        XCTAssertTrue(xml.contains("<Order>2</Order>"))
    }

    func testToolsDiscCarriesDisplayAndHelper() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-tools-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disc = directory.appendingPathComponent("burrow-tools.iso")
        try BurrowTools.create(at: disc, display: .init(width: 3024, height: 1900, scalePercent: 200))
        XCTAssertTrue(ImageCatalog.looksLikeDiscImage(disc))
        let contents = try Data(contentsOf: disc)
        XCTAssertNotNil(contents.range(of: Data("3024 1900 200".utf8)))
        XCTAssertNotNil(contents.range(of: Data("BurrowDisplay".utf8)))
    }

    func testQEMUReplacesAnEmptyASIFDiskWithRaw() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-qemu-test-\(UUID().uuidString).burrow")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = MachineBundle(url: directory)
        var config = MachineConfig(name: "Q", guest: .windows, diskBytes: 1 << 30, diskFileName: "disk.asif", macAddress: "02:00:00:00:00:01")
        FileManager.default.createFile(atPath: bundle.diskURL(for: config).path, contents: Data())
        try bundle.saveConfig(config)
        try QEMUMachine.prepareDisk(bundle, config: &config)
        XCTAssertEqual(config.diskFileName, "disk.img")
        XCTAssertEqual(try DiskImage.logicalSize(of: bundle.diskURL(for: config)), 1 << 30)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("disk.asif").path))
    }
}
