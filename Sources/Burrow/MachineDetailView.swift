import BurrowCore
import SwiftUI

struct MachineDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let entry: MachineEntry
    @ObservedObject var session: MachineSession
    @State private var showingSettings = false
    @State private var snapshots: [Snapshot] = []
    @State private var newName = ""
    @State private var renaming = false

    private var config: MachineConfig { entry.config }
    private var isActive: Bool { session.status.isActive }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if case .failed(let message) = session.status {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                specs
                if config.guest == .linux { linuxHints }
                if config.guest == .windows { windowsHints }
                snapshotSection
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showingSettings) {
            MachineSettingsView(entry: entry)
        }
        .onAppear(perform: loadSnapshots)
        .onChange(of: session.status) { loadSnapshots() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            GuestIcon(guest: config.guest).frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                if renaming {
                    TextField("Name", text: $newName, onCommit: {
                        renaming = false
                        model.rename(entry, to: newName)
                    })
                    .textFieldStyle(.roundedBorder)
                    .font(.title2)
                    .frame(maxWidth: 320)
                } else {
                    Text(config.name).font(.title.bold())
                        .onTapGesture(count: 2) {
                            guard !isActive else { return }
                            newName = config.name
                            renaming = true
                        }
                }
                Text("\(config.guest.displayName) · \(stateDescription)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Button {
                    openWindow(id: "machine", value: entry.id)
                    if !isActive { Task { await session.start() } }
                } label: {
                    Label(isActive ? "Show" : (entry.bundle.hasSavedState ? "Resume" : "Start"),
                          systemImage: isActive ? "macwindow" : "play.fill")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)

                Menu {
                    Button("Settings…") { showingSettings = true }.disabled(isActive)
                    Button("Clone") { model.clone(entry) }.disabled(isActive)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.bundle.url]) }
                    if entry.bundle.hasSavedState && !isActive {
                        Button("Discard Suspended State") {
                            entry.bundle.discardSavedState()
                            model.reload()
                        }
                    }
                    Divider()
                    Button("Move to Trash", role: .destructive) { model.trash(entry) }.disabled(isActive)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private var stateDescription: String {
        if case .stopped = session.status, entry.bundle.hasSavedState { return "Suspended" }
        return session.status.label
    }

    private var specs: some View {
        let disk = entry.bundle.diskURL(for: config)
        let used = ByteCountFormatter.string(fromByteCount: Int64(DiskImage.allocatedSize(of: disk)), countStyle: .file)
        return GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow { Text("Processors").foregroundStyle(.secondary); Text("\(config.cpuCount) cores") }
                GridRow { Text("Memory").foregroundStyle(.secondary); Text("\(Int(config.memoryBytes.gibibytes)) GB") }
                GridRow { Text("Disk").foregroundStyle(.secondary); Text("\(Int(config.diskBytes.gibibytes)) GB \(disk.pathExtension.uppercased()) · \(used) used on this Mac") }
                GridRow { Text("Display").foregroundStyle(.secondary); Text(verbatim: "\(config.display.width) × \(config.display.height)") }
                GridRow { Text("Network").foregroundStyle(.secondary); Text("Shared (NAT) · \(config.macAddress)") }
                GridRow {
                    Text("Shared folders").foregroundStyle(.secondary)
                    Text(config.sharedFolders.isEmpty ? "None" : config.sharedFolders.map(\.name).joined(separator: ", "))
                }
                if config.guest == .windows {
                    GridRow {
                        Text("Installer").foregroundStyle(.secondary)
                        Text(config.installerImagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None")
                    }
                    GridRow {
                        Text("Drivers").foregroundStyle(.secondary)
                        Text(config.driversImagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None — no networking until virtio-win is installed")
                    }
                }
                if config.guest == .linux {
                    GridRow { Text("Rosetta").foregroundStyle(.secondary); Text(config.rosetta ? "On — run x86-64 Linux binaries" : "Off") }
                    GridRow {
                        Text("Installer").foregroundStyle(.secondary)
                        Text(config.installerImagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        } label: {
            HStack {
                Text("Hardware")
                Spacer()
                Button("Edit…") { showingSettings = true }
                    .buttonStyle(.link)
                    .disabled(isActive)
            }
        }
    }

    private var linuxHints: some View {
        GroupBox("Inside the guest") {
            VStack(alignment: .leading, spacing: 6) {
                if !config.sharedFolders.isEmpty {
                    hint("Mount shared folders", "sudo mount -t virtiofs \(MachineBuilder.linuxShareTag) /mnt/burrow")
                }
                if config.rosetta {
                    hint("Mount Rosetta", "sudo mount -t virtiofs \(MachineBuilder.rosettaTag) /mnt/rosetta")
                }
                if config.clipboardSharing {
                    hint("Clipboard sharing", "install spice-vdagent")
                }
                if config.sharedFolders.isEmpty && !config.rosetta && !config.clipboardSharing {
                    Text("Nothing to set up.").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var windowsHints: some View {
        GroupBox("Installing Windows") {
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Start the machine and press a key when asked to boot from the installer disc.")
                Text("2. Setup skips the TPM and Secure Boot checks automatically. Choose “I don’t have a product key” to activate later.")
                Text("3. Create a local account when asked. The internet connection step can be skipped.")
                Text("4. At first sign-in, drivers from the virtio-win disc install automatically and networking comes up.")
                Text("5. Eject the installer: ••• in the machine window ▸ Eject Installer at Next Start.")
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private func hint(_ title: String, _ command: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }

    private var snapshotSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if snapshots.isEmpty {
                    Text("Snapshots save the disk as it is now, so you can return to this point later. They’re instant and only use space for blocks that change afterwards.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(snapshots.reversed()) { snapshot in
                    HStack {
                        Image(systemName: "camera.metering.center.weighted")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(snapshot.label)
                            Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore") { restore(snapshot) }.disabled(!canSnapshot)
                        Button(role: .destructive) {
                            model.attempt { try SnapshotStore(bundle: entry.bundle).delete(snapshot.id) }
                            loadSnapshots()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        } label: {
            HStack {
                Text("Snapshots")
                Spacer()
                Button("Take Snapshot") {
                    let label = Date().formatted(date: .abbreviated, time: .shortened)
                    model.attempt { try SnapshotStore(bundle: entry.bundle).take(label: label) }
                    loadSnapshots()
                }
                .buttonStyle(.link)
                .disabled(!canSnapshot)
                .help(canSnapshot ? "" : "Shut the machine down (not suspended) to take or restore snapshots")
            }
        }
    }

    private var canSnapshot: Bool { !isActive && !entry.bundle.hasSavedState }

    private func restore(_ snapshot: Snapshot) {
        let alert = NSAlert()
        alert.messageText = "Restore “\(snapshot.label)”?"
        alert.informativeText = "The machine’s current disk is replaced. Take a snapshot first if you want to keep it."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.attempt { try SnapshotStore(bundle: entry.bundle).restore(snapshot.id) }
        loadSnapshots()
    }

    private func loadSnapshots() {
        snapshots = (try? SnapshotStore(bundle: entry.bundle).list()) ?? []
    }
}
