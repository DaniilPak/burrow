import Foundation

/// The user account Burrow creates inside a guest it sets up automatically.
public struct GuestAccount: Sendable, Equatable {
    public var fullName: String
    public var username: String
    public var password: String

    public init(fullName: String, username: String, password: String) {
        self.fullName = fullName
        self.username = username
        self.password = password
    }

    /// Defaults to the Mac user's own names, which is what most people want.
    public static func suggested() -> GuestAccount {
        let short = NSUserName().lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return GuestAccount(fullName: NSFullUserName(), username: short.isEmpty ? "user" : short, password: "")
    }

    /// Windows accounts may have no password (sign-in is then automatic);
    /// Linux accounts need one for sudo and SSH.
    public func validate(requirePassword: Bool = true) throws {
        let allowed = CharacterSet.lowercaseLetters.union(.decimalDigits).union(CharacterSet(charactersIn: "-_"))
        guard let first = username.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first) || first == "_",
              username.unicodeScalars.allSatisfy({ allowed.contains($0) }), username.count <= 32,
              !["root", "admin", "administrator", "guest", "defaultaccount", "system"].contains(username)
        else {
            throw BurrowError.unsupported("Use a username of lowercase letters, digits, “-” or “_”, starting with a letter.")
        }
        guard !requirePassword || password.count >= 4 else {
            throw BurrowError.unsupported("Choose a password of at least 4 characters for the guest account.")
        }
    }
}

/// Builds the NoCloud seed disc ("cidata") that cloud-init reads on a cloud image's first boot.
public enum CloudInitSeed {
    public static let volumeName = "cidata"

    public static func create(at destination: URL, account: GuestAccount, hostname: String, desktop: Bool) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("burrow-cidata-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try metaData(hostname: hostname).write(to: staging.appendingPathComponent("meta-data"), atomically: true, encoding: .utf8)
        try userData(account: account, hostname: hostname, desktop: desktop)
            .write(to: staging.appendingPathComponent("user-data"), atomically: true, encoding: .utf8)

        try? fm.removeItem(at: destination)
        let base = destination.deletingPathExtension()
        try DiskImage.run("/usr/bin/hdiutil", [
            "makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", volumeName, "-o", base.path, staging.path,
        ])
        let produced = base.appendingPathExtension("iso")
        if produced != destination { try fm.moveItem(at: produced, to: destination) }
        // The seed holds the account password.
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    static func metaData(hostname: String) -> String {
        "instance-id: burrow-\(UUID().uuidString.lowercased())\nlocal-hostname: \(hostname)\n"
    }

    static func userData(account: GuestAccount, hostname: String, desktop: Bool) -> String {
        var packages = ["spice-vdagent"]
        if desktop { packages.append("ubuntu-desktop-minimal") }
        var lines = [
            "#cloud-config",
            "hostname: \(quoted(hostname))",
            "users:",
            "  - name: \(quoted(account.username))",
            "    gecos: \(quoted(account.fullName))",
            "    groups: [sudo]",
            "    shell: /bin/bash",
            "    sudo: \"ALL=(ALL) ALL\"",
            "    lock_passwd: false",
            "    plain_text_passwd: \(quoted(account.password))",
            "ssh_pwauth: true",
            "package_update: true",
            "packages: [\(packages.map(quoted).joined(separator: ", "))]",
            "runcmd:",
            // Burrow's shared folders and Rosetta mount automatically when the machine offers them.
            "  - [sh, -c, \"mkdir -p /mnt/burrow /mnt/rosetta\"]",
            "  - [sh, -c, \"grep -q ' /mnt/burrow ' /etc/fstab || echo 'burrow /mnt/burrow virtiofs defaults,nofail 0 0' >> /etc/fstab\"]",
            "  - [sh, -c, \"grep -q ' /mnt/rosetta ' /etc/fstab || echo 'rosetta /mnt/rosetta virtiofs ro,nofail 0 0' >> /etc/fstab\"]",
            "  - [sh, -c, \"mount -a || true\"]",
        ]
        if desktop {
            lines += [
                "  - [systemctl, set-default, graphical.target]",
                "power_state:",
                "  mode: reboot",
                "  message: Desktop installed, restarting",
                "  condition: true",
            ]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// JSON string literals are valid YAML double-quoted scalars, which keeps user text safe.
    static func quoted(_ text: String) -> String {
        let data = try? JSONEncoder().encode(text)
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    /// Lowercase letters, digits and hyphens, as hostnames require.
    public static func hostname(for machineName: String) -> String {
        let mapped = machineName.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "burrow" : String(collapsed.prefix(63))
    }
}
