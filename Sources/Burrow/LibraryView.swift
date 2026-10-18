import BurrowCore
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) fileprivate var openWindow
    @State private var showingNewMachine = false

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                if !model.installs.isEmpty {
                    Section("In Progress") {
                        ForEach(model.installs) { job in
                            InstallRow(job: job)
                        }
                    }
                }
                Section("Machines") {
                    ForEach(model.machines) { entry in
                        MachineRow(entry: entry, session: model.session(for: entry.bundle))
                            .tag(entry.id)
                            .contextMenu { MachineContextMenu(entry: entry) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .overlay {
                if model.machines.isEmpty && model.installs.isEmpty {
                    ContentUnavailableView {
                        Label("No Machines", systemImage: "square.stack.3d.down.right")
                    } description: {
                        Text("One click downloads and installs Windows 11 for you.")
                    } actions: {
                        Button {
                            model.quickInstallWindows()
                        } label: {
                            Label("Install Windows 11", systemImage: "pc")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        Button("Other Options…") { showingNewMachine = true }
                    }
                }
            }
        } detail: {
            if let url = model.selection, let entry = model.entry(for: url) {
                MachineDetailView(entry: entry, session: model.session(for: entry.bundle))
                    .id(entry.id)
            } else {
                Text("Select a machine")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.quickInstallWindows()
                } label: {
                    Label("Install Windows 11", systemImage: "pc")
                        .labelStyle(.titleAndIcon)
                }
                .help("Download and install Windows 11 — one click, nothing to fill in")
                Button {
                    showingNewMachine = true
                } label: {
                    Label("New Machine", systemImage: "plus")
                }
                .help("Create a machine with custom options")
            }
        }
        .focusedSceneValue(\.newMachineAction) { showingNewMachine = true }
        .sheet(isPresented: $showingNewMachine) {
            NewMachineSheet()
        }
        .sheet(item: $model.windowsDownload) { request in
            MicrosoftDownloadSheet(request: request)
        }
        .onChange(of: model.launchRequest) {
            guard let bundle = model.launchRequest else { return }
            model.launchRequest = nil
            openWindow(id: "machine", value: bundle.url)
            let session = model.session(for: bundle)
            Task { await session.start() }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.alert != nil },
            set: { if !$0 { model.alert = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
        .onAppear(perform: autostartIfRequested)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Pick up changes made by burrowctl while the app was in the background.
            model.reload()
        }
    }
}

extension LibraryView {
    /// `Burrow -BurrowAutostart "<name>"` opens and starts a machine at launch,
    /// which makes Burrow scriptable (login items, Shortcuts, automation).
    fileprivate func autostartIfRequested() {
        openSheetIfRequested()
        guard let name = UserDefaults.standard.string(forKey: "BurrowAutostart"),
              let entry = model.machines.first(where: { $0.config.name == name })
        else { return }
        UserDefaults.standard.removeObject(forKey: "BurrowAutostart")
        model.selection = entry.id
        openWindow(id: "machine", value: entry.id)
        let session = model.session(for: entry.bundle)
        Task { await session.start() }
    }
}

extension LibraryView {
    /// `Burrow -BurrowPresent newMachine|windowsDownload` opens a sheet at launch (used for UI testing).
    fileprivate func openSheetIfRequested() {
        switch UserDefaults.standard.string(forKey: "BurrowPresent") {
        case "newMachine": showingNewMachine = true
        case "windowsDownload":
            model.windowsDownload = WindowsDownloadRequest(name: "Windows 11", cpus: 4, memoryGiB: 8, diskGiB: 80, drivers: nil, account: nil)
        default: break
        }
    }
}

struct MachineRow: View {
    let entry: MachineEntry
    @ObservedObject var session: MachineSession

    var body: some View {
        HStack(spacing: 10) {
            GuestIcon(guest: entry.config.guest)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.config.name)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        if case .stopped = session.status, entry.bundle.hasSavedState { return "Suspended" }
        return session.status.label
    }

    private var statusColor: Color {
        switch session.status {
        case .running: .green
        case .paused, .suspending, .starting, .stopping: .orange
        case .failed: .red
        case .stopped: entry.bundle.hasSavedState ? .blue : .gray
        }
    }
}

struct InstallRow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var job: InstallJob

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                GuestIcon(guest: job.guest).frame(width: 20, height: 20)
                Text(job.name).lineLimit(1)
                Spacer()
                Button {
                    model.dismiss(job)
                } label: {
                    Image(systemName: job.error == nil ? "xmark.circle" : "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help(job.error == nil ? "Cancel" : "Dismiss")
            }
            if let fraction = job.fraction {
                ProgressView(value: fraction)
            } else if job.error == nil {
                ProgressView().controlSize(.small)
            }
            Text(job.summary)
                .font(.caption)
                .foregroundStyle(job.error == nil ? Color.secondary : Color.red)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}

struct MachineContextMenu: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let entry: MachineEntry

    var body: some View {
        MachineContextMenuItems(entry: entry, session: model.session(for: entry.bundle))
    }
}

/// Observes the session so Start and Force Stop track the machine's live status.
private struct MachineContextMenuItems: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let entry: MachineEntry
    @ObservedObject var session: MachineSession

    var body: some View {
        let isActive = session.status.isActive
        Button("Open") { openWindow(id: "machine", value: entry.id) }
        if isActive {
            Button("Force Stop", role: .destructive) { Task { await session.forceStop() } }
        } else {
            Button(entry.bundle.hasSavedState ? "Resume" : "Start") {
                openWindow(id: "machine", value: entry.id)
                Task { await session.start() }
            }
        }
        Divider()
        Button("Clone") { model.clone(entry) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.bundle.url]) }
        Divider()
        Button("Move to Trash", role: .destructive) { model.trash(entry) }.disabled(isActive)
    }
}

struct GuestIcon: View {
    let guest: GuestOS

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: guest.tileColors, startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: guest.symbolName)
                .resizable()
                .scaledToFit()
                .padding(6)
                .foregroundStyle(.white)
        }
    }
}

extension GuestOS {
    var symbolName: String {
        switch self {
        case .linux: "terminal.fill"
        case .windows: "pc"
        case .macOS: "apple.logo"
        }
    }

    var tileColors: [Color] {
        switch self {
        case .linux: [.orange, .yellow]
        case .windows: [.cyan, .blue]
        case .macOS: [.blue, .purple]
        }
    }
}
