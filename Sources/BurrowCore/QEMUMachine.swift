import Foundation

/// Runs a machine under QEMU with Apple's Hypervisor.framework (`-accel hvf`).
///
/// Windows 11 on ARM hangs in its boot manager under Virtualization.framework, so
/// Windows guests run here instead: the same hardware acceleration, with QEMU's own
/// virtual platform and EDK2 firmware. Burrow drives QEMU over two Unix sockets: QMP
/// for control (power, pause, key presses) and VNC for the screen, keyboard and mouse.
public final class QEMUMachine: @unchecked Sendable {
    public enum Event: Sendable {
        /// QEMU exited; `guestShutdown` is true when the guest powered itself off.
        case exited(guestShutdown: Bool, error: String?)
    }

    /// Burrow's own QEMU (scripts/build-qemu.sh: 60 Hz display refresh) comes first; Homebrew's
    /// stock build is the fallback.
    static var prefixes: [String] {
        [burrowQEMUURL.path, "/opt/homebrew", "/usr/local"]
    }

    /// Where scripts/build-qemu.sh installs Burrow's QEMU: beside Machines and Images.
    public static var burrowQEMUURL: URL {
        MachineLibrary.defaultRoot.deletingLastPathComponent().appendingPathComponent("QEMU", isDirectory: true)
    }

    public static var executableURL: URL? {
        prefixes.map { URL(fileURLWithPath: "\($0)/bin/qemu-system-aarch64") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var firmwareDirectory: URL? {
        prefixes.map { URL(fileURLWithPath: "\($0)/share/qemu") }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("edk2-aarch64-code.fd").path) }
    }

    public static var isInstalled: Bool { executableURL != nil && firmwareDirectory != nil }

    /// QEMU outlives its parent unless told to stop, so the app stops every machine as it quits.
    private static let registry = NSLock()
    nonisolated(unsafe) private static var live: [ObjectIdentifier: QEMUMachine] = [:]

    public static func terminateAll() {
        let machines = registry.withLock { Array(live.values) }
        for machine in machines where machine.process.isRunning {
            machine.process.terminate()
            machine.process.waitUntilExit()
        }
    }

    public static let missingMessage = "Windows runs on QEMU, which isn’t installed. Install it with “brew install qemu” in Terminal, then start the machine again."

    public let bundle: MachineBundle
    /// Unix socket QEMU serves the screen on (VNC/RFB, no authentication).
    public let vncSocketPath: String
    let qmpSocketPath: String
    private let runDirectory: URL
    private let process = Process()
    private var qmp: QMPClient?
    private let lock = NSLock()
    private var guestShutdown = false
    private var stderrText = ""

    /// Called on an arbitrary thread.
    public var onEvent: (@Sendable (Event) -> Void)?

    public init(bundle: MachineBundle) {
        self.bundle = bundle
        // sun_path holds 104 bytes, so the sockets live in a short directory of their own.
        runDirectory = URL(fileURLWithPath: "/tmp/burrow-\(UUID().uuidString.prefix(8))", isDirectory: true)
        vncSocketPath = runDirectory.appendingPathComponent("vnc.sock").path
        qmpSocketPath = runDirectory.appendingPathComponent("qmp.sock").path
    }

    // MARK: Disk and firmware

    /// QEMU-specific firmware variables, kept apart from Virtualization.framework's store.
    static func variableStoreURL(_ bundle: MachineBundle) -> URL {
        bundle.url.appendingPathComponent("qemu-efi-variables.fd")
    }

    /// QEMU can't read ASIF. A Windows disk that was never installed to is swapped for a
    /// raw sparse file of the same size; an ASIF disk with data on it is refused.
    static func prepareDisk(_ bundle: MachineBundle, config: inout MachineConfig) throws {
        let disk = bundle.diskURL(for: config)
        guard disk.pathExtension == "asif" else { return }
        guard DiskImage.allocatedSize(of: disk) < 64 << 20 else {
            throw BurrowError.unsupported("This machine’s disk is in Apple’s ASIF format, which QEMU can’t read.")
        }
        let raw = bundle.url.appendingPathComponent(DiskImage.Format.raw.fileName)
        try DiskImage.createRaw(at: raw, bytes: config.diskBytes)
        try? FileManager.default.removeItem(at: disk)
        config.diskFileName = raw.lastPathComponent
        try bundle.saveConfig(config)
    }

    // MARK: Lifecycle

    /// Burrow Tools disc, rebuilt at every start with the display Windows should use.
    static func toolsDiscURL(_ bundle: MachineBundle) -> URL {
        bundle.url.appendingPathComponent("burrow-tools.iso")
    }

    /// The screen Windows was started with; nil while Setup runs on the basic framebuffer.
    public private(set) var display: BurrowTools.Display?

    /// Launches QEMU and connects to its control socket. While `installing`, the installer
    /// discs are attached and Windows draws on ramfb, the framebuffer Setup can use without
    /// drivers. Afterwards the machine gets a virtio GPU whose preferred mode is `display`,
    /// which Burrow Tools switches Windows to at sign-in.
    public func start(installing: Bool, display requested: BurrowTools.Display) throws {
        guard let qemu = Self.executableURL, let firmware = Self.firmwareDirectory else {
            throw BurrowError.unsupported(Self.missingMessage)
        }
        var config = try bundle.loadConfig()
        try Self.prepareDisk(bundle, config: &config)
        let disk = bundle.diskURL(for: config)
        guard FileManager.default.fileExists(atPath: disk.path) else { throw BurrowError.missingFile(disk.path) }

        let vars = Self.variableStoreURL(bundle)
        if !FileManager.default.fileExists(atPath: vars.path) {
            try FileManager.default.copyItem(at: firmware.appendingPathComponent("edk2-arm-vars.fd"), to: vars)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: vars.path)
        }

        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let tools = Self.toolsDiscURL(bundle)
        try BurrowTools.create(at: tools, display: requested)
        display = installing ? nil : requested
        let graphics = installing
            ? "ramfb"
            : "virtio-gpu-pci,xres=\(requested.width),yres=\(requested.height)"

        var arguments = [
            "-name", config.name,
            "-M", "virt", "-accel", "hvf", "-cpu", "host",
            "-smp", "\(max(1, config.cpuCount))",
            "-m", "\(max(1024, config.memoryBytes >> 20))",
            "-drive", "if=pflash,format=raw,readonly=on,file=\(escape(firmware.appendingPathComponent("edk2-aarch64-code.fd").path))",
            "-drive", "if=pflash,format=raw,file=\(escape(vars.path))",
            "-device", graphics,
            "-device", "qemu-xhci,id=xhci",
            "-device", "usb-kbd", "-device", "usb-tablet",
            // Windows has a class driver for USB audio, so sound works without extra drivers.
            "-audiodev", "coreaudio,id=snd0",
            "-device", "usb-audio,audiodev=snd0",
            // Windows ships an NVMe driver, so it installs without extra drivers.
            "-drive", "if=none,id=disk0,format=raw,discard=unmap,detect-zeroes=unmap,file=\(escape(disk.path))",
            "-device", "nvme,drive=disk0,serial=burrow0,bootindex=1",
            "-nic", "user,model=virtio-net-pci,mac=\(config.macAddress)",
            "-device", "virtio-rng-pci",
            "-device", "virtio-balloon-pci",
            "-qmp", "unix:\(escape(qmpSocketPath)),server=on,wait=off",
            "-vnc", "unix:\(escape(vncSocketPath))",
            "-display", "none",
            "-monitor", "none", "-serial", "none", "-parallel", "none",
        ]
        var discs: [String] = []
        if installing, let installer = config.installerImagePath {
            discs.append(installer)
            if FileManager.default.fileExists(atPath: bundle.windowsSetupMediaURL.path) {
                discs.append(bundle.windowsSetupMediaURL.path)
            }
        }
        if let drivers = config.driversImagePath { discs.append(drivers) }
        discs.append(tools.path)
        for (index, path) in discs.enumerated() {
            guard FileManager.default.fileExists(atPath: path) else { throw BurrowError.missingFile(path) }
            arguments += [
                "-drive", "if=none,id=cd\(index),media=cdrom,readonly=on,file=\(escape(path))",
                // The installer boots first while the disk is empty; later the disk's own entry wins.
                "-device", "usb-storage,drive=cd\(index)\(index == 0 ? ",bootindex=0" : "")",
            ]
        }

        process.executableURL = qemu
        process.arguments = arguments
        // Windows' virtual CPUs are the work you're waiting on; at the default QoS macOS may
        // park them on efficiency cores.
        process.qualityOfService = .userInteractive
        process.currentDirectoryURL = bundle.url
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.withLock { self.stderrText = String((self.stderrText + String(decoding: data, as: UTF8.self)).suffix(2000)) }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            errors.fileHandleForReading.readabilityHandler = nil
            let (shutdown, text) = self.lock.withLock { (self.guestShutdown, self.stderrText) }
            let failed = process.terminationReason == .uncaughtSignal || (process.terminationStatus != 0 && !shutdown)
            self.qmp?.close()
            Self.registry.withLock { _ = Self.live.removeValue(forKey: ObjectIdentifier(self)) }
            try? FileManager.default.removeItem(at: self.runDirectory)
            let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.onEvent?(.exited(guestShutdown: shutdown, error: failed ? (message.isEmpty ? "QEMU stopped unexpectedly." : message) : nil))
        }
        try process.run()
        Self.registry.withLock { Self.live[ObjectIdentifier(self)] = self }

        qmp = try QMPClient(path: qmpSocketPath, timeout: 10) { [weak self] event in
            if event == "SHUTDOWN" { self?.lock.withLock { self?.guestShutdown = true } }
        }
    }

    public var isRunning: Bool { process.isRunning }

    /// Presses the power button; the guest decides whether to shut down.
    public func requestShutdown() throws { try qmp?.execute("system_powerdown") }
    /// Cuts power.
    public func forceStop() {
        _ = try? qmp?.execute("quit")
        if process.isRunning { process.terminate() }
    }
    public func pause() throws { try qmp?.execute("stop") }
    public func resume() throws { try qmp?.execute("cont") }
    public func restart() throws { try qmp?.execute("system_reset") }

    /// Taps a key, e.g. "spc" to answer "Press any key to boot from CD or DVD".
    public func press(_ qcode: String) {
        _ = try? qmp?.execute("send-key", ["keys": [["type": "qcode", "data": qcode]]])
    }

    /// QEMU parses commas in option values as separators; doubling them escapes them.
    private func escape(_ path: String) -> String { path.replacingOccurrences(of: ",", with: ",,") }
}

/// A minimal QMP (QEMU Machine Protocol) client: JSON lines over a Unix socket.
final class QMPClient: @unchecked Sendable {
    private let socket: Int32
    private let lock = NSLock()
    private let replies = DispatchSemaphore(value: 0)
    private var lastReply: [String: Any]?
    private var closed = false

    init(path: String, timeout: TimeInterval, onEvent: @escaping @Sendable (String) -> Void) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var fd: Int32 = -1
        while true {
            fd = try UnixSocket.connect(path: path)
            if fd >= 0 { break }
            if Date() > deadline { throw BurrowError.unsupported("QEMU didn’t start. Check that it’s installed correctly (brew reinstall qemu).") }
            Thread.sleep(forTimeInterval: 0.1)
        }
        socket = fd
        let reader = LineReader(fd: fd)
        _ = reader.nextLine() // greeting
        let thread = Thread { [weak self] in
            while let line = reader.nextLine() {
                guard let self,
                      let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
                else { continue }
                if let event = object["event"] as? String {
                    onEvent(event)
                } else {
                    self.lock.withLock { self.lastReply = object }
                    self.replies.signal()
                }
            }
            self?.lock.withLock { self?.closed = true }
            self?.replies.signal()
        }
        thread.name = "Burrow QMP"
        thread.start()
        try execute("qmp_capabilities")
    }

    /// Sends one command and waits for its reply. Calls are serialized.
    @discardableResult
    func execute(_ command: String, _ arguments: [String: Any]? = nil) throws -> [String: Any] {
        try lock.withLock {
            guard !closed else { throw BurrowError.unsupported("The machine isn’t running.") }
            var message: [String: Any] = ["execute": command]
            if let arguments { message["arguments"] = arguments }
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try UnixSocket.write(socket, data)
        }
        guard replies.wait(timeout: .now() + 10) == .success else {
            throw BurrowError.unsupported("QEMU didn’t answer “\(command)”.")
        }
        let reply = lock.withLock { lastReply } ?? [:]
        if let error = reply["error"] as? [String: Any] {
            throw BurrowError.unsupported(error["desc"] as? String ?? "QEMU refused “\(command)”.")
        }
        return reply
    }

    func close() {
        lock.withLock { closed = true }
        shutdown(socket, SHUT_RDWR)
        Darwin.close(socket)
    }
}

/// Blocking Unix-domain socket helpers shared by the QMP and VNC clients.
public enum UnixSocket {
    /// Returns a connected descriptor, or -1 when nothing is listening yet.
    public static func connect(path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BurrowError.unsupported("Couldn’t create a socket.") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw BurrowError.unsupported("Socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            Darwin.close(fd)
            return -1
        }
        return fd
    }

    public static func write(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
                if sent <= 0 {
                    if errno == EINTR { continue }
                    throw BurrowError.unsupported("The connection to the machine closed.")
                }
                offset += sent
            }
        }
    }

    /// Reads exactly `count` bytes into `buffer`; false when the connection closed.
    public static func read(_ fd: Int32, into buffer: UnsafeMutableRawPointer, count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let received = Darwin.recv(fd, buffer + offset, count - offset, 0)
            if received <= 0 {
                if received < 0 && errno == EINTR { continue }
                return false
            }
            offset += received
        }
        return true
    }
}

private final class LineReader {
    private let fd: Int32
    private var buffer = Data()

    init(fd: Int32) { self.fd = fd }

    func nextLine() -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return String(decoding: line, as: UTF8.self)
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let received = recv(fd, &chunk, chunk.count, 0)
            if received <= 0 {
                if received < 0 && errno == EINTR { continue }
                return nil
            }
            buffer.append(contentsOf: chunk[0..<received])
        }
    }
}
