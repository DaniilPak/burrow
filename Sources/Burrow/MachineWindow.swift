import BurrowCore
import SwiftUI
import Virtualization

struct MachineWindow: View {
    @EnvironmentObject private var model: AppModel
    let url: URL

    var body: some View {
        if let entry = model.entry(for: url) {
            MachineScreen(entry: entry, session: model.session(for: entry.bundle))
        } else {
            ContentUnavailableView("Machine not found", systemImage: "questionmark.square.dashed",
                                   description: Text("It may have been renamed or moved to the Trash."))
        }
    }
}

private struct MachineScreen: View {
    @EnvironmentObject private var model: AppModel
    let entry: MachineEntry
    @ObservedObject var session: MachineSession
    @State private var capturesSystemKeys = false

    var body: some View {
        Group {
            if let machine = session.virtualMachine {
                VirtualMachineDisplay(machine: machine, capturesSystemKeys: capturesSystemKeys,
                                      pressKeysUntil: session.pressBootKeysUntil)
                    .overlay {
                        if session.status == .paused || session.status == .suspending {
                            ZStack {
                                Color.black.opacity(0.45)
                                Label(session.status == .paused ? "Paused" : "Suspending…",
                                      systemImage: session.status == .paused ? "pause.circle" : "moon.zzz")
                                    .font(.largeTitle)
                                    .foregroundStyle(.white)
                            }
                        }
                    }
            } else if let qemu = session.qemuMachine {
                QEMUDisplay(machine: qemu)
                    .overlay {
                        if session.status == .paused {
                            ZStack {
                                Color.black.opacity(0.45)
                                Label("Paused", systemImage: "pause.circle")
                                    .font(.largeTitle)
                                    .foregroundStyle(.white)
                            }
                        }
                    }
            } else {
                idle
            }
        }
        .navigationTitle(entry.config.name)
        .navigationSubtitle(subtitle)
        .toolbar { controls }
    }

    private var subtitle: String {
        if case .stopped = session.status, entry.bundle.hasSavedState { return "Suspended" }
        return session.status.label
    }

    private var idle: some View {
        VStack(spacing: 18) {
            GuestIcon(guest: entry.config.guest).frame(width: 96, height: 96)
            Text(entry.config.name).font(.title.bold())
            switch session.status {
            case .starting:
                ProgressView("Starting…")
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 520)
                startButton
            default:
                startButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.secondary)
    }

    private var startButton: some View {
        Button {
            Task { await session.start() }
        } label: {
            Label(entry.bundle.hasSavedState ? "Resume" : "Start", systemImage: "play.fill")
                .padding(.horizontal, 12)
        }
        .controlSize(.extraLarge)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
    }

    @ToolbarContentBuilder
    private var controls: some ToolbarContent {
        ToolbarItemGroup {
            switch session.status {
            case .running:
                Button { Task { await session.pause() } } label: { Label("Pause", systemImage: "pause.fill") }
                    .help("Pause")
                if session.canSuspend {
                    Button { Task { await session.suspend() } } label: { Label("Suspend", systemImage: "moon.fill") }
                        .help("Suspend to disk — resumes exactly where you left off")
                }
                Button { session.requestShutdown() } label: { Label("Shut Down", systemImage: "power") }
                    .help("Ask the guest to shut down")
            case .paused:
                Button { Task { await session.resume() } } label: { Label("Resume", systemImage: "play.fill") }
                    .help("Resume")
                if session.canSuspend {
                    Button { Task { await session.suspend() } } label: { Label("Suspend", systemImage: "moon.fill") }
                }
            case .stopped, .failed:
                Button { Task { await session.start() } } label: { Label("Start", systemImage: "play.fill") }
                    .help(entry.bundle.hasSavedState ? "Resume" : "Start")
            case .stopping:
                ProgressView().controlSize(.small)
                Button { Task { await session.forceStop() } } label: { Label("Force Stop", systemImage: "stop.fill") }
                    .help("Cut power now — the guest isn't responding to Shut Down")
            case .starting, .suspending:
                ProgressView().controlSize(.small)
            }

            if session.qemuMachine != nil {
                switch session.windowsSetupPhase {
                case .installing:
                    Label("Installing Windows — it restarts a few times", systemImage: "gearshape.2")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                case .restartForFullResolution:
                    Button { session.restart() } label: {
                        Label("Restart for Full Resolution", systemImage: "arrow.clockwise")
                            .labelStyle(.titleAndIcon)
                    }
                    .help("Windows is installed. One restart switches it to this Mac’s native resolution.")
                case .none:
                    EmptyView()
                }
            } else if entry.config.windowsSetupRestartsRemaining != nil, session.status.isActive {
                Label("Installing Windows — it restarts a few times", systemImage: "gearshape.2")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
            }
            Menu {
                Toggle("Capture System Keys", isOn: $capturesSystemKeys)
                    .help("Send shortcuts like ⌘Tab to the guest instead of this Mac")
                Divider()
                if entry.config.guest.usesUEFI, entry.config.installerImagePath != nil {
                    Button("Eject Installer at Next Start") {
                        model.update(entry) { $0.installerImagePath = nil }
                    }
                }
                if session.qemuMachine != nil {
                    Button("Restart") { session.restart() }
                        .disabled(session.status != .running)
                }
                Button("Force Stop", role: .destructive) { Task { await session.forceStop() } }
                    .disabled(!session.status.isActive)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}

/// Hosts Apple's VM display view, which handles keyboard, mouse and resizing.
struct VirtualMachineDisplay: NSViewRepresentable {
    let machine: VZVirtualMachine
    let capturesSystemKeys: Bool
    /// Presses Space until this time, answering "press any key to boot from CD".
    var pressKeysUntil: Date?

    final class Coordinator {
        var timer: Timer?
        var deadline: Date?
        deinit { timer?.invalidate() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        view.capturesSystemKeys = capturesSystemKeys
        view.automaticallyReconfiguresDisplay = true
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== machine { view.virtualMachine = machine }
        view.capturesSystemKeys = capturesSystemKeys
        let coordinator = context.coordinator
        guard coordinator.deadline != pressKeysUntil else { return }
        coordinator.deadline = pressKeysUntil
        coordinator.timer?.invalidate()
        guard let deadline = pressKeysUntil, deadline > Date() else { return }
        coordinator.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak view] timer in
            guard let view, Date() < deadline else {
                timer.invalidate()
                return
            }
            Self.pressSpace(in: view)
        }
    }

    private static func pressSpace(in view: VZVirtualMachineView) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: view.window?.windowNumber ?? 0, context: nil,
                characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)
            else { continue }
            type == .keyDown ? view.keyDown(with: event) : view.keyUp(with: event)
        }
    }
}
