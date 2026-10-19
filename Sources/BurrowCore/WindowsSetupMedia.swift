import Foundation

/// Builds the small "BURROWSETUP" disc that rides along with a Windows installer.
///
/// Windows Setup reads `autounattend.xml` from the root of any removable drive.
/// With an account, Burrow's answer file installs Windows 11 with no questions at all:
/// language, disk layout, edition, computer name, a local administrator account and a
/// first automatic sign-in. Without one, it only removes what blocks a virtual machine
/// and Setup asks the rest. Either way it:
/// - skips Setup's TPM, Secure Boot, CPU, RAM and storage checks, since
///   Virtualization.framework has no virtual TPM;
/// - allows a local account without a network, because Windows has no driver for
///   the virtio network card until virtio-win is installed;
/// - installs the ARM64 virtio-win drivers from the driver disc at first sign-in.
public enum WindowsSetupMedia {
    public static let volumeName = "BURROWSETUP"

    /// Microsoft's published generic key for *installing* Windows 11 Pro. It selects the
    /// edition so Setup doesn't ask; it does not activate Windows.
    static let proInstallKey = "VK7JG-NPHTM-C97JM-9MPGT-3V66T"

    /// virtio-win driver folders installed at first sign-in, when present for ARM64.
    static let driverFolders = ["NetKVM", "Balloon", "vioserial", "viorng", "vioinput", "viofs", "viosock", "pvpanic", "viogpudo"]

    public struct Options: Sendable, Equatable {
        /// With an account the install is fully unattended.
        public var account: GuestAccount?
        /// Language tag of the installer, e.g. "en-US"; also used for region and keyboard.
        public var language: String
        public var computerName: String

        public init(account: GuestAccount? = nil, language: String = "en-US", computerName: String = "BURROW-PC") {
            self.account = account
            self.language = language
            self.computerName = computerName
        }
    }

    public static func create(at destination: URL, options: Options = Options()) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("burrow-setup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try answerFile(options).write(to: staging.appendingPathComponent("autounattend.xml"), atomically: true, encoding: .utf8)
        try readme.write(to: staging.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        try? fm.removeItem(at: destination)
        // makehybrid appends ".iso" to the output name, so build beside the destination and move.
        let base = destination.deletingPathExtension()
        try DiskImage.run("/usr/bin/hdiutil", [
            "makehybrid", "-quiet", "-iso", "-joliet",
            "-default-volume-name", volumeName,
            "-o", base.path, staging.path,
        ])
        let produced = base.appendingPathExtension("iso")
        if produced != destination {
            try fm.moveItem(at: produced, to: destination)
        }
        // With an account, the disc holds its password until Burrow removes it after Setup.
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    public static func answerFile(_ options: Options = Options()) -> String {
        let arch = #"processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS""#
        let labConfig = ["BypassTPMCheck", "BypassSecureBootCheck", "BypassCPUCheck", "BypassRAMCheck", "BypassStorageCheck"]
        let bypasses = labConfig.enumerated().map { index, value in
            """
                            <RunSynchronousCommand wcm:action="add">
                                <Order>\(index + 1)</Order>
                                <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v \(value) /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
            """
        }.joined(separator: "\n")
        let language = xml(options.language)
        let international = """
                    <InputLocale>\(language)</InputLocale>
                    <SystemLocale>\(language)</SystemLocale>
                    <UILanguage>\(language)</UILanguage>
                    <UserLocale>\(language)</UserLocale>
        """

        var windowsPE = ""
        var setupExtras = ""
        var specializeShell = ""
        var oobeExtras = ""
        var oobeInternational = ""
        if let account = options.account {
            let name = xml(account.username)
            let display = xml(account.fullName.isEmpty ? account.username : account.fullName)
            let password = xml(account.password)
            windowsPE = """
                    <component name="Microsoft-Windows-International-Core-WinPE" \(arch)>
                        <SetupUILanguage>
                            <UILanguage>\(language)</UILanguage>
                        </SetupUILanguage>
            \(international)
                    </component>
            """
            setupExtras = """
                        <DiskConfiguration>
                            <Disk wcm:action="add">
                                <DiskID>0</DiskID>
                                <WillWipeDisk>true</WillWipeDisk>
                                <CreatePartitions>
                                    <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
                                    <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
                                    <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
                                </CreatePartitions>
                                <ModifyPartitions>
                                    <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
                                    <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
                                </ModifyPartitions>
                            </Disk>
                        </DiskConfiguration>
                        <ImageInstall>
                            <OSImage>
                                <InstallTo>
                                    <DiskID>0</DiskID>
                                    <PartitionID>3</PartitionID>
                                </InstallTo>
                            </OSImage>
                        </ImageInstall>
            """
            specializeShell = """
                    <component name="Microsoft-Windows-Shell-Setup" \(arch)>
                        <ComputerName>\(xml(options.computerName))</ComputerName>
                    </component>
            """
            oobeInternational = """
                    <component name="Microsoft-Windows-International-Core" \(arch)>
            \(international)
                    </component>
            """
            oobeExtras = """
                        <UserAccounts>
                            <LocalAccounts>
                                <LocalAccount wcm:action="add">
                                    <Name>\(name)</Name>
                                    <DisplayName>\(display)</DisplayName>
                                    <Group>Administrators</Group>
                                    <Password>
                                        <Value>\(password)</Value>
                                        <PlainText>true</PlainText>
                                    </Password>
                                </LocalAccount>
                            </LocalAccounts>
                        </UserAccounts>
                        <AutoLogon>
                            <Enabled>true</Enabled>
                            <LogonCount>\(account.password.isEmpty ? 9999 : 1)</LogonCount>
                            <Username>\(name)</Username>
                            <Password>
                                <Value>\(password)</Value>
                                <PlainText>true</PlainText>
                            </Password>
                        </AutoLogon>
            """
        }
        let unattended = options.account != nil
        let productKey = unattended ? """
                            <ProductKey>
                                <Key>\(proInstallKey)</Key>
                                <WillShowUI>OnError</WillShowUI>
                            </ProductKey>
        """ : ""
        let fullName = options.account.map { "<FullName>\(xml($0.fullName.isEmpty ? $0.username : $0.fullName))</FullName>" } ?? ""

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!-- Generated by Burrow. -->
        <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <settings pass="windowsPE">
        \(windowsPE)
                <component name="Microsoft-Windows-Setup" \(arch)>
        \(setupExtras)
                    <RunSynchronous>
        \(bypasses)
                    </RunSynchronous>
                    <UserData>
                        <AcceptEula>true</AcceptEula>
                        \(fullName)
        \(productKey)
                    </UserData>
                </component>
            </settings>
            <settings pass="specialize">
        \(specializeShell)
                <component name="Microsoft-Windows-Deployment" \(arch)>
                    <RunSynchronous>
                        <RunSynchronousCommand wcm:action="add">
                            <Order>1</Order>
                            <Path>reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                        </RunSynchronousCommand>
                    </RunSynchronous>
                </component>
            </settings>
            <settings pass="oobeSystem">
        \(oobeInternational)
                <component name="Microsoft-Windows-Shell-Setup" \(arch)>
                    <OOBE>
                        <HideEULAPage>true</HideEULAPage>
                        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                        <HideLocalAccountScreen>\(unattended)</HideLocalAccountScreen>
                        <ProtectYourPC>3</ProtectYourPC>
                    </OOBE>
        \(oobeExtras)
                    <FirstLogonCommands>
                        <SynchronousCommand wcm:action="add">
                            <Order>1</Order>
                            <Description>Install virtio-win ARM64 drivers from the driver disc</Description>
                            <CommandLine>\(driverInstallCommand)</CommandLine>
                        </SynchronousCommand>
                        <SynchronousCommand wcm:action="add">
                            <Order>2</Order>
                            <Description>Install Burrow Tools (native resolution and scaling)</Description>
                            <CommandLine>\(BurrowTools.firstLogonCommand)</CommandLine>
                        </SynchronousCommand>
                    </FirstLogonCommands>
                </component>
            </settings>
        </unattend>

        """
    }

    /// Searches every drive letter for virtio-win's layout and installs the ARM64 drivers it finds.
    static var driverInstallCommand: String {
        let folders = driverFolders.joined(separator: " ")
        return "cmd /c for %d in (D E F G H I J K L M N O P) do @if exist %d:\\NetKVM ("
            + "for %p in (\(folders)) do @if exist %d:\\%p\\w11\\ARM64 "
            + "pnputil /add-driver %d:\\%p\\w11\\ARM64\\*.inf /install)"
    }

    /// Windows computer names: up to 15 letters, digits and hyphens.
    public static func computerName(for machineName: String) -> String {
        let cleaned = machineName.uppercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        let name = String(cleaned).split(separator: "-").joined(separator: "-")
        return name.isEmpty ? "BURROW-PC" : String(name.prefix(15))
    }

    static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static let readme = """
    Burrow setup disc

    autounattend.xml installs Windows 11 on ARM in a Burrow virtual machine. It skips
    the TPM/Secure Boot checks (Apple's Virtualization framework has no virtual TPM),
    sets up a local account without needing a network, and installs the virtio-win
    ARM64 drivers at first sign-in. Burrow removes this disc when Setup is done.
    """
}

/// Facts read from a Windows installer ISO.
public enum WindowsInstallerImage {
    /// The installer's language (e.g. "en-US"), read from `sources/lang.ini` on the disc.
    public static func language(of iso: URL) -> String? {
        let mountPoint = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-iso-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            try DiskImage.run("/usr/bin/hdiutil", ["attach", "-quiet", "-readonly", "-nobrowse", "-mountpoint", mountPoint.path, iso.path])
        } catch {
            try? FileManager.default.removeItem(at: mountPoint)
            return nil
        }
        defer {
            _ = try? DiskImage.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mountPoint.path])
            try? FileManager.default.removeItem(at: mountPoint)
        }
        guard let data = try? Data(contentsOf: mountPoint.appendingPathComponent("sources/lang.ini")) else { return nil }
        // Usually UTF-16 with a byte order mark; older media use plain text.
        let text = String(data: data, encoding: .utf16) ?? String(decoding: data, as: UTF8.self)
        return parseLangINI(text.contains("[") ? text : String(decoding: data, as: UTF8.self))
    }

    /// First entry under "[Available UI Languages]", as a BCP-47 tag like "en-US".
    static func parseLangINI(_ text: String) -> String? {
        var inSection = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inSection = line.lowercased() == "[available ui languages]"
                continue
            }
            guard inSection, let key = line.split(separator: "=").first?.trimmingCharacters(in: .whitespaces), !key.isEmpty else { continue }
            let parts = key.split(separator: "-")
            guard parts.count >= 2 else { return key }
            return parts[0].lowercased() + "-" + parts[1...].map { $0.count == 2 ? $0.uppercased() : String($0) }.joined(separator: "-")
        }
        return nil
    }
}
