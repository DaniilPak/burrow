import AppKit
import SwiftUI

/// Keeps every Burrow window on one chosen display (handy when a game or a
/// presentation owns the other one). Stored as the display's name.
@MainActor
final class DisplayPreference {
    static let shared = DisplayPreference()
    static let key = "BurrowPreferredDisplay"

    private var observer: NSObjectProtocol?
    private var placed = Set<ObjectIdentifier>()

    var preferredName: String? {
        get { UserDefaults.standard.string(forKey: Self.key) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.key)
            placed.removeAll()
            NSApp.windows.forEach(place)
        }
    }

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.place(window) }
        }
        DispatchQueue.main.async { NSApp.windows.forEach(self.place) }
    }

    /// Moves a window onto the preferred display once, keeping its size; later the user can drag it anywhere.
    func place(_ window: NSWindow) {
        guard window.isVisible, window.styleMask.contains(.titled), !placed.contains(ObjectIdentifier(window)),
              let name = preferredName,
              let screen = NSScreen.screens.first(where: { $0.localizedName == name })
        else { return }
        placed.insert(ObjectIdentifier(window))
        guard window.screen != screen else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.midY - frame.height / 2
        window.setFrame(frame, display: true)
    }
}

/// Window ▸ Keep Burrow Windows On ▸ (display)
struct DisplayMenu: View {
    @State private var selection = DisplayPreference.shared.preferredName

    var body: some View {
        Menu("Keep Burrow Windows On") {
            Button(selection == nil ? "✓ Any Display" : "Any Display") { choose(nil) }
            ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { name in
                Button(selection == name ? "✓ \(name)" : name) { choose(name) }
            }
        }
    }

    private func choose(_ name: String?) {
        selection = name
        DisplayPreference.shared.preferredName = name
    }
}
