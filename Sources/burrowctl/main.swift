import BurrowCore
import Foundation

let usage = """
burrowctl — manage Burrow virtual machines

Usage:
  burrowctl list
  burrowctl info <name>
  burrowctl check <name>             (validates the machine’s virtual hardware)
  burrowctl run <name> [--for SECONDS]   (runs headless; Ctrl-C suspends or shuts down)
  burrowctl images                   (operating systems Burrow can download for you)
  burrowctl create-linux <name> [--distro ubuntu-desktop|ubuntu-server|debian|fedora|alpine | --iso <path>]
                         [--user NAME] [--password PASS] [--cpus N] [--memory GiB] [--disk GiB]
      Ubuntu and Debian are set up automatically (no installer) with the given account;
      without --password you are asked for one.
  burrowctl create-windows <name> [--iso <win11-arm64.iso>] [--user NAME --password PASS | --manual]
                         [--drivers <virtio-win.iso>|none] [--cpus N] [--memory GiB] [--disk GiB]
      Installs unattended with the given account (asked for if omitted) unless --manual.
      Uses the Windows ISO Burrow downloaded earlier when --iso is omitted.
      Drivers download automatically unless given. Get the Windows ISO with the
      Burrow app (it opens Microsoft’s download page for you).
  burrowctl set <name> [--cpus N] [--memory GiB] [--disk GiB] [--iso <path>|none] [--drivers <path>|none] [--rosetta on|off] [--clipboard on|off]
  burrowctl share <name> <folder-name> <host-path> [--read-only]
  burrowctl unshare <name> <folder-name>
  burrowctl clone <name> <new-name>
  burrowctl rename <name> <new-name>
  burrowctl snapshot <name> [label]
  burrowctl snapshots <name>
  burrowctl restore <name> <snapshot-id>
  burrowctl delete-snapshot <name> <snapshot-id>
  burrowctl discard-suspended <name>
  burrowctl delete <name>            (moves the machine to the Trash)

Machines live in \(MachineLibrary.defaultRoot.path) (override with BURROW_HOME).
Use the Burrow app for a display; `run` is for servers and scripts.
"""

struct CommandError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Splits `--flag value` options from positional arguments.
struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: ArraySlice<String>, flags known: Set<String> = []) throws {
        var iterator = raw.makeIterator()
        while let item = iterator.next() {
            if item.hasPrefix("--") {
                let key = String(item.dropFirst(2))
                if known.contains(key) {
                    flags.insert(key)
                } else {
                    guard let value = iterator.next() else { throw CommandError("--\(key) needs a value") }
                    options[key] = value
                }
            } else {
                positional.append(item)
            }
        }
    }

    func positional(_ index: Int, _ name: String) throws -> String {
        guard index < positional.count else { throw CommandError("Missing <\(name)>.\n\n\(usage)") }
        return positional[index]
    }

    func int(_ key: String) throws -> Int? {
        guard let text = options[key] else { return nil }
        guard let value = Int(text), value > 0 else { throw CommandError("--\(key) must be a positive whole number") }
        return value
    }

    func toggle(_ key: String) throws -> Bool? {
        guard let text = options[key] else { return nil }
        switch text.lowercased() {
        case "on", "yes", "true", "1": return true
        case "off", "no", "false", "0": return false
        default: throw CommandError("--\(key) must be on or off")
        }
    }
}

func describe(_ bundle: MachineBundle) throws -> String {
    let config = try bundle.loadConfig()
    let disk = bundle.diskURL(for: config)
    let state = bundle.isRunning ? "running" : (bundle.hasSavedState ? "suspended" : "stopped")
    var lines = [
        "Name:       \(config.name)",
        "Guest:      \(config.guest.displayName)",
        "State:      \(state)",
        "CPUs:       \(config.cpuCount)",
        "Memory:     \(Int(config.memoryBytes.gibibytes)) GiB",
        "Disk:       \(Int(config.diskBytes.gibibytes)) GiB \(disk.pathExtension.uppercased()), \(ByteCountFormatter.string(fromByteCount: Int64(DiskImage.allocatedSize(of: disk)), countStyle: .file)) used on host",
        "Display:    \(config.display.width)×\(config.display.height)",
        "MAC:        \(config.macAddress)",
        "Clipboard:  \(config.clipboardSharing ? "shared" : "off")",
    ]
    if config.guest == .linux {
        lines.append("Rosetta:    \(config.rosetta ? "on" : "off")")
    }
    if config.guest.usesUEFI {
        lines.append("Installer:  \(config.installerImagePath ?? "none")")
    }
    if config.guest == .windows {
        lines.append("Drivers:    \(config.driversImagePath ?? "none")")
    }
    for folder in config.sharedFolders {
        lines.append("Shared:     \(folder.name) → \(folder.hostPath)\(folder.readOnly ? " (read-only)" : "")")
    }
    lines.append("Bundle:     \(bundle.url.path)")
    return lines.joined(separator: "\n")
}

func absolutePath(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
}

func run() throws {
    let library = MachineLibrary()
    let argv = CommandLine.arguments
    guard argv.count > 1 else { print(usage); return }
    let command = argv[1]
    let rest = argv.dropFirst(2)

    switch command {
    case "list", "ls":
        let machines = try library.machines()
        if machines.isEmpty { print("No machines yet."); return }
        let rows = try machines.map { bundle -> (String, String, String) in
            let config = try bundle.loadConfig()
            let state = bundle.isRunning ? "running" : (bundle.hasSavedState ? "suspended" : "stopped")
            return (config.name, config.guest.displayName, state)
        }
        let width = max(4, rows.map(\.0.count).max() ?? 0)
        print("NAME".padding(toLength: width + 2, withPad: " ", startingAt: 0) + "GUEST   STATE")
        for row in rows {
            print(row.0.padding(toLength: width + 2, withPad: " ", startingAt: 0)
                + row.1.padding(toLength: 8, withPad: " ", startingAt: 0) + row.2)
        }

    case "info":
        let args = try Arguments(rest)
        print(try describe(library.bundle(named: args.positional(0, "name"))))

    case "check":
        let args = try Arguments(rest)
        let bundle = try library.bundle(named: args.positional(0, "name"))
        let configuration = try MachineBuilder.configuration(for: bundle)
        let suspend = MachineBuilder.supportsSuspend(configuration) ? "supported" : "not supported"
        print("OK: \(configuration.cpuCount) CPUs, \(configuration.memorySize >> 30) GiB, \(configuration.storageDevices.count) storage, \(configuration.directorySharingDevices.count) shares, suspend \(suspend).")

    case "run":
        let args = try Arguments(rest)
        let bundle = try library.bundle(named: args.positional(0, "name"))
        try runHeadless(bundle, seconds: try args.int("for"))

    case "images":
        let results = try awaitResult {
            try await withThrowingTaskGroup(of: (CatalogImage, ResolvedImage?).self) { group in
                for image in ImageCatalog.linux {
                    group.addTask { (image, try? await ImageCatalog.resolve(image)) }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }
        }
        for image in ImageCatalog.linux {
            let resolved = results.first { $0.0.id == image.id }?.1
            let detail = resolved.map { "\($0.fileName)\(checksumNote($0.checksum))" } ?? "unavailable right now"
            let style = image.isAutomatic ? "automatic setup" : "installer"
            print("\(image.id.padding(toLength: 16, withPad: " ", startingAt: 0)) \(image.name) (\(style)) \(image.approximateSize) — \(detail)")
        }
        let drivers = (try? awaitResult { try await ImageCatalog.resolveVirtioWin() }).map { "\($0.fileName) from \($0.url.host ?? "")" } ?? "unavailable right now"
        print("virtio-win       Windows drivers ≈ 880 MB — \(drivers)")
        print("\nWindows 11: use the Burrow app, which opens Microsoft’s download page and takes over from there.")

    case "create-linux":
        let args = try Arguments(rest)
        let name = try args.positional(0, "name")
        var iso = args.options["iso"].map { URL(fileURLWithPath: absolutePath($0)) }
        if let distro = args.options["distro"] {
            guard let image = ImageCatalog.image(id: distro) else {
                throw CommandError("Unknown distro “\(distro)”. Run `burrowctl images` for the list.")
            }
            if case .cloudImage(let desktop) = image.kind {
                var account = GuestAccount.suggested()
                if let user = args.options["user"] { account.username = user }
                account.password = try args.options["password"] ?? promptPassword(for: account.username)
                try account.validate()
                let archive = try download(image.name) { downloader, progress in
                    let resolved = try await ImageCatalog.resolve(image)
                    return try await ImageCatalog.fetch(resolved, downloader: downloader, progress: progress)
                }
                print("Setting up “\(name)”…")
                let bundle = try library.createCloudMachine(
                    name: name, archive: archive, account: account, desktop: desktop,
                    cpuCount: try args.int("cpus") ?? 4,
                    memoryBytes: .gibibytes(try args.int("memory") ?? (desktop ? 6 : 4)),
                    diskBytes: .gibibytes(try args.int("disk") ?? 64))
                print("Created “\(name)”. It finishes setting itself up on first start; sign in as \(account.username).\n")
                print(try describe(bundle))
                return
            }
            iso = try download(image.name) { downloader, progress in
                let resolved = try await ImageCatalog.resolve(image)
                return try await ImageCatalog.fetch(resolved, downloader: downloader, progress: progress)
            }
        }
        if let iso, !FileManager.default.fileExists(atPath: iso.path) { throw CommandError("No file at \(iso.path)") }
        let bundle = try library.createLinuxMachine(
            name: name, installerISO: iso,
            cpuCount: try args.int("cpus") ?? 4,
            memoryBytes: .gibibytes(try args.int("memory") ?? 4),
            diskBytes: .gibibytes(try args.int("disk") ?? 64))
        print("Created “\(name)”.\n")
        print(try describe(bundle))

    case "create-windows":
        let args = try Arguments(rest, flags: ["manual"])
        let name = try args.positional(0, "name")
        guard let iso = args.options["iso"].map({ URL(fileURLWithPath: absolutePath($0)) }) ?? ImageCatalog.cachedWindowsISO() else {
            throw CommandError("No Windows ISO yet. Pass --iso, or get one once with the Burrow app.")
        }
        var account: GuestAccount?
        if !args.flags.contains("manual") {
            var suggested = GuestAccount.suggested()
            if let user = args.options["user"] { suggested.username = user }
            suggested.password = try args.options["password"] ?? promptPassword(for: suggested.username)
            try suggested.validate()
            account = suggested
        }
        var drivers = args.options["drivers"].flatMap { $0 == "none" ? nil : URL(fileURLWithPath: absolutePath($0)) }
        for file in [iso] + (drivers.map { [$0] } ?? []) where !FileManager.default.fileExists(atPath: file.path) {
            throw CommandError("No file at \(file.path)")
        }
        if args.options["drivers"] == nil {
            drivers = try download("virtio-win drivers") { downloader, progress in
                let resolved = try await ImageCatalog.resolveVirtioWin()
                return try await ImageCatalog.fetch(resolved, downloader: downloader, progress: progress)
            }
        }
        let bundle = try library.createWindowsMachine(
            name: name, installerISO: iso, driversISO: drivers, account: account,
            cpuCount: try args.int("cpus") ?? 4,
            memoryBytes: .gibibytes(try args.int("memory") ?? 8),
            diskBytes: .gibibytes(try args.int("disk") ?? 80))
        print(account == nil
              ? "Created “\(name)”. Start it in the Burrow app; Setup will ask its questions.\n"
              : "Created “\(name)”. Start it in the Burrow app; Windows installs by itself and signs in as \(account!.username).\n")
        print(try describe(bundle))

    case "set":
        let args = try Arguments(rest)
        let bundle = try library.bundle(named: args.positional(0, "name"))
        var config = try bundle.loadConfig()
        if bundle.isRunning { throw BurrowError.machineRunning(config.name) }
        if let cpus = try args.int("cpus") { config.cpuCount = cpus }
        if let memory = try args.int("memory") { config.memoryBytes = .gibibytes(memory) }
        if let disk = try args.int("disk") {
            try DiskImage.grow(at: bundle.diskURL(for: config), to: .gibibytes(disk))
            config.diskBytes = .gibibytes(disk)
        }
        if let iso = args.options["iso"] {
            config.installerImagePath = iso == "none" ? nil : absolutePath(iso)
        }
        if let drivers = args.options["drivers"] {
            config.driversImagePath = drivers == "none" ? nil : absolutePath(drivers)
        }
        if let rosetta = try args.toggle("rosetta") { config.rosetta = rosetta }
        if let clipboard = try args.toggle("clipboard") { config.clipboardSharing = clipboard }
        try bundle.saveConfig(config)
        print(try describe(bundle))

    case "share":
        let args = try Arguments(rest, flags: ["read-only"])
        let bundle = try library.bundle(named: args.positional(0, "name"))
        let folderName = try args.positional(1, "folder-name")
        let hostPath = absolutePath(try args.positional(2, "host-path"))
        var config = try bundle.loadConfig()
        config.sharedFolders.removeAll { $0.name == folderName }
        config.sharedFolders.append(SharedFolder(name: folderName, hostPath: hostPath, readOnly: args.flags.contains("read-only")))
        try bundle.saveConfig(config)
        print("Sharing \(hostPath) as “\(folderName)”. Takes effect at next start.")

    case "unshare":
        let args = try Arguments(rest)
        let bundle = try library.bundle(named: args.positional(0, "name"))
        let folderName = try args.positional(1, "folder-name")
        var config = try bundle.loadConfig()
        config.sharedFolders.removeAll { $0.name == folderName }
        try bundle.saveConfig(config)

    case "clone":
        let args = try Arguments(rest)
        let source = try library.bundle(named: args.positional(0, "name"))
        let clone = try library.cloneMachine(source, as: args.positional(1, "new-name"))
        print("Cloned to “\(clone.name)”.")

    case "rename":
        let args = try Arguments(rest)
        _ = try library.rename(library.bundle(named: args.positional(0, "name")), to: args.positional(1, "new-name"))

    case "snapshot":
        let args = try Arguments(rest)
        let bundle = try library.bundle(named: args.positional(0, "name"))
        let label = args.positional.dropFirst().joined(separator: " ")
        let snapshot = try SnapshotStore(bundle: bundle).take(label: label.isEmpty ? "Snapshot" : label)
        print("Took snapshot \(snapshot.id.uuidString) “\(snapshot.label)”.")

    case "snapshots":
        let args = try Arguments(rest)
        let snapshots = try SnapshotStore(bundle: library.bundle(named: args.positional(0, "name"))).list()
        if snapshots.isEmpty { print("No snapshots."); return }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        for snapshot in snapshots {
            print("\(snapshot.id.uuidString)  \(formatter.string(from: snapshot.createdAt))  \(snapshot.label)")
        }

    case "restore":
        let args = try Arguments(rest)
        let bundle = try library.bundle(named: args.positional(0, "name"))
        guard let id = UUID(uuidString: try args.positional(1, "snapshot-id")) else { throw CommandError("Not a snapshot ID") }
        try SnapshotStore(bundle: bundle).restore(id)
        print("Restored.")

    case "delete-snapshot":
        let args = try Arguments(rest)
        let bundle = try library.bundle(named: args.positional(0, "name"))
        guard let id = UUID(uuidString: try args.positional(1, "snapshot-id")) else { throw CommandError("Not a snapshot ID") }
        try SnapshotStore(bundle: bundle).delete(id)

    case "discard-suspended":
        let args = try Arguments(rest)
        let bundle = try library.bundle(named: args.positional(0, "name"))
        if bundle.isRunning { throw BurrowError.machineRunning(try bundle.loadConfig().name) }
        bundle.discardSavedState()

    case "delete", "rm":
        let args = try Arguments(rest)
        try library.trash(library.bundle(named: args.positional(0, "name")))
        print("Moved to the Trash.")

    case "help", "--help", "-h":
        print(usage)

    default:
        throw CommandError("Unknown command “\(command)”.\n\n\(usage)")
    }
}

func checksumNote(_ checksum: Checksum?) -> String {
    switch checksum {
    case .sha256: ", SHA-256 verified"
    case .sha512: ", SHA-512 verified"
    case nil: ""
    }
}

func promptPassword(for user: String) throws -> String {
    guard isatty(STDIN_FILENO) != 0 else { throw CommandError("--password is required when not running in a terminal") }
    guard let first = getpass("Password for \(user) in the guest: "), let second = getpass("Again: ") else {
        throw CommandError("No password entered")
    }
    let a = String(cString: first), b = String(cString: second)
    guard a == b else { throw CommandError("The passwords don’t match") }
    return a
}

/// Runs async work from this synchronous tool, pumping the main run loop meanwhile.
func awaitResult<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    var result: Result<T, Error>?
    Task {
        do { result = .success(try await work()) } catch { result = .failure(error) }
        CFRunLoopStop(CFRunLoopGetMain())
    }
    while result == nil { CFRunLoopRun() }
    return try result!.get()
}

/// Downloads with a one-line progress display.
func download(_ title: String, _ work: @escaping @Sendable (FileDownloader, @escaping @Sendable (Double) -> Void) async throws -> URL) throws -> URL {
    print("Getting \(title)…")
    let downloader = FileDownloader()
    let url = try awaitResult {
        try await work(downloader) { fraction in
            let percent = Int(fraction * 100)
            let bar = String(repeating: "█", count: percent / 4).padding(toLength: 25, withPad: "░", startingAt: 0)
            FileHandle.standardOutput.write(Data("\r  \(bar) \(percent)%".utf8))
        }
    }
    print("\r  Ready: \(url.lastPathComponent)".padding(toLength: 60, withPad: " ", startingAt: 0))
    return url
}

/// Runs a machine without a display until it stops, the time limit passes, or Ctrl-C.
func runHeadless(_ bundle: MachineBundle, seconds: Int?) throws {
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    var failure: String?
    MainActor.assumeIsolated {
        let session = MachineSession(bundle: bundle)
        var lastStatus = ""
        let observer = session.$status.sink { status in
            let text: String
            if case .failed(let message) = status { text = "Error: \(message)" } else { text = status.label }
            guard text != lastStatus else { return }
            lastStatus = text
            print("[\(Date().formatted(date: .omitted, time: .standard))] \(text)")
        }
        session.onStop = {
            if case .failed(let message) = session.status { failure = message }
            CFRunLoopStop(CFRunLoopGetMain())
        }
        let stopGracefully: () -> Void = {
            Task { @MainActor in
                if session.canSuspend { await session.suspend() } else { await session.forceStop() }
            }
        }
        interrupt.setEventHandler { stopGracefully() }
        interrupt.resume()
        if let seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { stopGracefully() }
        }
        Task { await session.start() }
        withExtendedLifetime(observer) { CFRunLoopRun() }
    }
    if let failure { throw CommandError(failure) }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("burrowctl: \(error.localizedDescription)\n".utf8))
    exit(1)
}
