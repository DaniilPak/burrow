import AppKit
import BurrowCore
import SwiftUI

@main
struct BurrowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Burrow", id: "library") {
            LibraryView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 520)
                .onAppear { appDelegate.model = model }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                NewMachineCommand()
            }
            CommandGroup(after: .windowArrangement) {
                DisplayMenu()
            }
        }

        WindowGroup("Machine", id: "machine", for: URL.self) { $url in
            if let url {
                MachineWindow(url: url)
                    .environmentObject(model)
            }
        }
        .defaultSize(width: 1280, height: 840)
        .windowToolbarStyle(.unifiedCompact)
    }
}

private struct NewMachineCommand: View {
    @FocusedValue(\.newMachineAction) private var newMachine

    var body: some View {
        Button("New Machine…") { newMachine?() }
            .keyboardShortcut("n")
            .disabled(newMachine == nil)
    }
}

struct NewMachineActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var newMachineAction: (() -> Void)? {
        get { self[NewMachineActionKey.self] }
        set { self[NewMachineActionKey.self] = newValue }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (e.g. `swift run`).
        NSApp.setActivationPolicy(.regular)
        DisplayPreference.shared.start()
        // Windows starts at the native resolution and scaling of the screen it opens on.
        MachineSession.preferredWindowsDisplay = { name, mode in
            // The machine's own window decides; otherwise the window in front, then the main screen.
            let window = NSApp.windows.first { $0.isVisible && $0.title == name } ?? NSApp.keyWindow
            guard let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return .fallback }
            let scale = mode.pixelsPerPoint(screenScale: screen.backingScaleFactor)
            // Full screen on a MacBook with a notch only uses the area below it, so match that.
            let height = screen.frame.height - screen.safeAreaInsets.top
            return BurrowTools.Display(width: Int(screen.frame.width * scale), height: Int(height * scale),
                                       scalePercent: Int((scale * 100).rounded()), performance: mode.turnsOffEffects)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        QEMUMachine.terminateAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.hasActiveMachines == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Machines are still running"
        alert.informativeText = "Quitting turns them off immediately, like pulling the power cord. Suspend or shut them down first to keep their work."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")
        alert.alertStyle = .warning
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
