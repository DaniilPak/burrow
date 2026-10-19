import Combine
import Foundation
import Virtualization

/// One running (or runnable) machine. All calls happen on the main actor,
/// which is also the queue Virtualization.framework uses for the VM.
@MainActor
public final class MachineSession: NSObject, ObservableObject {
    public enum Status: Equatable {
        case stopped
        case starting
        case running
        case paused
        case suspending
        case stopping
        case failed(String)

        public var isActive: Bool {
            switch self {
            case .starting, .running, .paused, .suspending, .stopping: true
            case .stopped, .failed: false
            }
        }

        public var label: String {
            switch self {
            case .stopped: "Stopped"
            case .starting: "Starting"
            case .running: "Running"
            case .paused: "Paused"
            case .suspending: "Suspending"
            case .stopping: "Shutting Down"
            case .failed: "Error"
            }
        }
    }

    public let bundle: MachineBundle
    @Published public private(set) var status: Status = .stopped
    @Published public private(set) var virtualMachine: VZVirtualMachine?
    @Published public private(set) var canSuspend = false
    /// Set instead of `virtualMachine` for guests that run under QEMU (Windows).
    @Published public private(set) var qemuMachine: QEMUMachine?

    public enum WindowsSetupPhase: Equatable, Sendable {
        case none
        /// Setup is copying and configuring Windows on the basic framebuffer.
        case installing
        /// Setup is done; the next start brings the GPU and the Mac's native resolution.
        case restartForFullResolution
    }
    @Published public private(set) var windowsSetupPhase: WindowsSetupPhase = .none
    private var restartAfterStop = false

    /// Called when the guest stops by itself or with an error.
    public var onStop: (() -> Void)?

    /// When the current fresh boot began; nil after resuming from suspend.
    private var bootedAt: Date?
    /// Set when the user asks to shut down, so the stop isn't mistaken for a Setup reboot.
    private var userRequestedStop = false

    /// Until when the display should press keys for the guest: Windows installers ask to
    /// "press any key to boot from CD" and otherwise skip the installer.
    @Published public private(set) var pressBootKeysUntil: Date?

    public init(bundle: MachineBundle) {
        self.bundle = bundle
        super.init()
    }

    // MARK: Lifecycle

    /// Boots the machine, or resumes it from a suspended state when one exists.
    public func start(attachInstaller: Bool = true) async {
        guard !status.isActive else { return }
        status = .starting
        do {
            try bundle.acquireRunLock()
            if (try bundle.loadConfig()).guest == .windows {
                try await startQEMU(attachInstaller: attachInstaller)
                return
            }
            let configuration = try MachineBuilder.configuration(
                for: bundle, options: .init(attachInstaller: attachInstaller))
            let machine = VZVirtualMachine(configuration: configuration)
            machine.delegate = self
            virtualMachine = machine
            canSuspend = MachineBuilder.supportsSuspend(configuration)

            if bundle.hasSavedState, canSuspend {
                do {
                    try await machine.restoreMachineStateFrom(url: bundle.savedStateURL)
                    bundle.discardSavedState()
                    try await machine.resume()
                    status = .running
                    return
                } catch {
                    // A state saved by another OS build or configuration can't be
                    // restored; fall back to a fresh boot rather than refusing to start.
                    bundle.discardSavedState()
                }
            }
            userRequestedStop = false
            try await machine.start()
            bootedAt = Date()
            status = .running
            if let config = try? bundle.loadConfig(), config.guest == .windows, attachInstaller,
               config.installerImagePath != nil, DiskImage.allocatedSize(of: bundle.diskURL(for: config)) < 64 << 20 {
                pressBootKeysUntil = Date().addingTimeInterval(30)
            }
        } catch {
            fail(error)
        }
    }

    public func pause() async {
        if let qemu = qemuMachine {
            do { try qemu.pause(); status = .paused } catch { fail(error) }
            return
        }
        guard let machine = virtualMachine, machine.canPause else { return }
        do {
            try await machine.pause()
            status = .paused
        } catch {
            fail(error)
        }
    }

    public func resume() async {
        if let qemu = qemuMachine {
            do { try qemu.resume(); status = .running } catch { fail(error) }
            return
        }
        guard let machine = virtualMachine, machine.canResume else { return }
        do {
            try await machine.resume()
            status = .running
        } catch {
            fail(error)
        }
    }

    /// Writes memory and device state to disk and stops; the next start continues where it left off.
    public func suspend() async {
        guard let machine = virtualMachine, canSuspend else { return }
        status = .suspending
        do {
            if machine.state == .running { try await machine.pause() }
            try await machine.saveMachineStateTo(url: bundle.savedStateURL)
            try await machine.stop()
            finish()
        } catch {
            bundle.discardSavedState()
            fail(error)
        }
    }

    /// Asks the guest OS to shut down (like pressing the power button).
    public func requestShutdown() {
        if let qemu = qemuMachine {
            userRequestedStop = true
            do {
                try qemu.requestShutdown()
                status = .stopping
            } catch {
                qemu.forceStop()
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard let self, self.qemuMachine === qemu, self.status == .stopping else { return }
                qemu.forceStop()
            }
            return
        }
        guard let machine = virtualMachine, machine.canRequestStop else { return }
        userRequestedStop = true
        do {
            try machine.requestStop()
            status = .stopping
        } catch {
            fail(error)
            return
        }
        // A guest that is hung, or still in firmware or a boot loader, never answers the
        // power button; cut power rather than leave the machine stuck "Shutting Down".
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, self.virtualMachine === machine, self.status == .stopping else { return }
            await self.forceStop()
        }
    }

    /// Cuts power immediately. Unsaved guest data is lost.
    public func forceStop() async {
        if let qemu = qemuMachine {
            status = .stopping
            // QEMU exits and its exit event finishes the session.
            qemu.forceStop()
            return
        }
        guard let machine = virtualMachine, machine.canStop else {
            finish()
            return
        }
        do {
            try await machine.stop()
            finish()
        } catch {
            fail(error)
        }
    }

    // MARK: State

    /// The guest turned itself off. Firmware does that within moments when it
    /// finds nothing bootable, which deserves an explanation rather than "Stopped".
    private func guestStopped() {
        if continueWindowsSetup() { return }
        if let bootedAt, Date().timeIntervalSince(bootedAt) < 5 {
            let hint = switch (try? bundle.loadConfig())?.guest {
            case .macOS: "The macOS installation may be incomplete. Try installing it again."
            case .windows: "Attach a Windows 11 ARM64 installer ISO in Settings, or check that Windows finished installing."
            default: "Attach an installer ISO in Settings, or check that the disk has an operating system."
            }
            fail(BurrowError.unsupported("The machine turned off right after starting, so it probably found nothing to boot. \(hint)"))
            return
        }
        finish()
    }

    /// Restarts the machine when Windows Setup reboots it. The first reboot means Setup has
    /// copied itself to the disk, so the installer and its answer-file disc come out then.
    private func continueWindowsSetup() -> Bool {
        guard !userRequestedStop, var config = try? bundle.loadConfig(), config.guest == .windows,
              let remaining = config.windowsSetupRestartsRemaining, remaining > 0
        else { return false }
        let uptime = bootedAt.map { Date().timeIntervalSince($0) } ?? 0
        // A machine that ran a long while after the installer came out is past Setup: a stop
        // now is the user shutting Windows down.
        if config.installerImagePath == nil, uptime > 15 * 60 {
            config.windowsSetupRestartsRemaining = nil
            try? bundle.saveConfig(config)
            return false
        }
        // A reboot within seconds of a fresh installer boot means nothing booted; report it.
        if config.installerImagePath != nil, uptime < 5 { return false }
        config.windowsSetupRestartsRemaining = remaining > 1 ? remaining - 1 : nil
        if config.installerImagePath != nil {
            config.installerImagePath = nil
            try? FileManager.default.removeItem(at: bundle.windowsSetupMediaURL)
        }
        try? bundle.saveConfig(config)
        bootedAt = nil
        pressBootKeysUntil = nil
        virtualMachine = nil
        status = .stopped
        bundle.releaseRunLock()
        Task { await start() }
        return true
    }

    // MARK: QEMU

    /// Windows runs under QEMU with Hypervisor.framework: its boot manager hangs under
    /// Virtualization.framework. Setup's reboots happen inside QEMU, so there is nothing
    /// to restart by hand; the installer only needs a key press to boot.
    private func startQEMU(attachInstaller: Bool) async throws {
        var config = try bundle.loadConfig()
        let installing = DiskImage.allocatedSize(of: bundle.diskURL(for: config)) < 64 << 20
        if !installing, config.windowsSetupRestartsRemaining != nil {
            config.windowsSetupRestartsRemaining = nil
            try bundle.saveConfig(config)
        }
        let machine = QEMUMachine(bundle: bundle)
        machine.onEvent = { [weak self] event in
            Task { @MainActor in self?.qemuEvent(event, from: machine) }
        }
        userRequestedStop = false
        canSuspend = false
        // Starting usually opens the machine's window in the same breath; let it appear so the
        // display can be sized for the screen it lands on.
        try? await Task.sleep(for: .milliseconds(400))
        let display = Self.preferredWindowsDisplay?(config.name) ?? .fallback
        try await Task.detached { try machine.start(installing: attachInstaller && installing, display: display) }.value
        qemuMachine = machine
        bootedAt = Date()
        status = .running
        windowsSetupPhase = installing && attachInstaller ? .installing : .none
        if installing {
            // Setup is done once Windows is on the disk and has been running a while; it then
            // only needs one restart to switch from the basic framebuffer to the GPU.
            Task { [weak self] in
                while true {
                    try? await Task.sleep(for: .seconds(30))
                    guard let self, self.qemuMachine === machine, self.windowsSetupPhase == .installing else { return }
                    let written = DiskImage.allocatedSize(of: self.bundle.diskURL(for: (try? self.bundle.loadConfig()) ?? config))
                    if written > 6 << 30, let bootedAt = self.bootedAt, Date().timeIntervalSince(bootedAt) > 8 * 60 {
                        self.windowsSetupPhase = .restartForFullResolution
                    }
                }
            }
            // Answer "Press any key to boot from CD or DVD" so Setup starts by itself.
            Task { [weak self] in
                let deadline = Date().addingTimeInterval(30)
                while Date() < deadline {
                    guard let self, self.qemuMachine === machine, self.status == .running else { return }
                    machine.press("spc")
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }

    /// Shuts Windows down and starts it again, e.g. to apply the native resolution.
    public func restart() {
        guard qemuMachine != nil else { return }
        restartAfterStop = true
        requestShutdown()
    }

    /// The app supplies the screen the named machine's window is on; headless runs use the fallback.
    nonisolated(unsafe) public static var preferredWindowsDisplay: ((String) -> BurrowTools.Display)?

    private func qemuEvent(_ event: QEMUMachine.Event, from machine: QEMUMachine) {
        guard qemuMachine === machine || qemuMachine == nil else { return }
        switch event {
        case .exited(_, let error?):
            qemuMachine = nil
            fail(BurrowError.unsupported("Windows stopped: \(error)"))
        case .exited:
            qemuMachine = nil
            windowsSetupPhase = .none
            finish()
            if restartAfterStop {
                restartAfterStop = false
                Task { await start() }
            }
        }
    }

    private func finish() {
        bootedAt = nil
        pressBootKeysUntil = nil
        virtualMachine = nil
        status = .stopped
        bundle.releaseRunLock()
        onStop?()
    }

    private func fail(_ error: Error) {
        bootedAt = nil
        if let qemu = qemuMachine, qemu.isRunning { qemu.forceStop() }
        qemuMachine = nil
        restartAfterStop = false
        windowsSetupPhase = .none
        virtualMachine = nil
        status = .failed(error.localizedDescription)
        bundle.releaseRunLock()
        onStop?()
    }
}

extension MachineSession: VZVirtualMachineDelegate {
    nonisolated public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { guestStopped() }
    }

    nonisolated public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        MainActor.assumeIsolated { fail(error) }
    }
}
