import AppKit
import BurrowCore
import SwiftUI
import UniformTypeIdentifiers

struct MachineSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let entry: MachineEntry
    @State private var draft: MachineConfig
    @State private var memoryGiB: Double
    @State private var diskGiB: Double
    private let originalDiskGiB: Double

    init(entry: MachineEntry) {
        self.entry = entry
        _draft = State(initialValue: entry.config)
        _memoryGiB = State(initialValue: entry.config.memoryBytes.gibibytes.rounded())
        let disk = entry.config.diskBytes.gibibytes.rounded()
        _diskGiB = State(initialValue: disk)
        originalDiskGiB = disk
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if entry.bundle.hasSavedState {
                    Label("This machine is suspended. Saving hardware or sharing changes discards the suspended state, as if its power had been cut.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Section("Hardware") {
                    Stepper("Processors: \(draft.cpuCount)", value: $draft.cpuCount, in: 1...hostCores)
                    LabeledSlider(title: "Memory", value: $memoryGiB, range: 2...Double(hostMemoryGiB), unit: "GB")
                    LabeledSlider(title: "Disk", value: $diskGiB, range: originalDiskGiB...max(originalDiskGiB, 2048), unit: "GB")
                    Text("Disks can grow but not shrink. Grow the partition inside the guest afterwards.")
                        .font(.caption).foregroundStyle(.secondary)
                    // Windows follows the Mac's screen by itself (Burrow Tools), so it has no fixed size.
                    if draft.guest != .windows {
                        Picker("Display", selection: resolution) {
                            ForEach(Self.resolutions, id: \.self) { size in
                                Text(verbatim: "\(size.width) × \(size.height)").tag(size)
                            }
                        }
                    }
                }

                Section("Sharing") {
                    Toggle("Share clipboard", isOn: $draft.clipboardSharing)
                    Toggle("Allow microphone", isOn: $draft.audioInput)
                    ForEach(draft.sharedFolders) { folder in
                        HStack {
                            Image(systemName: "folder")
                            VStack(alignment: .leading) {
                                Text(folder.name)
                                Text(folder.hostPath).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if folder.readOnly { Text("Read-only").font(.caption).foregroundStyle(.secondary) }
                            Button(role: .destructive) {
                                draft.sharedFolders.removeAll { $0.name == folder.name }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button("Add Shared Folder…", action: addFolder)
                }

                if draft.guest == .windows {
                    Section("Windows") {
                        DiscRow(title: "Installer disc", path: $draft.installerImagePath, kinds: ["iso"])
                        DiscRow(title: "Driver disc (virtio-win)", path: $draft.driversImagePath, kinds: ["iso"])
                        Picker("Display", selection: Binding(
                            get: { draft.windowsDisplayMode ?? .sharp },
                            set: { draft.windowsDisplayMode = $0 == .sharp ? nil : $0 }
                        )) {
                            ForEach(WindowsDisplayMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text("\((draft.windowsDisplayMode ?? .sharp).summary) Takes effect the next time Windows starts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Eject the installer once Windows is installed. Keep the driver disc until the first sign-in has installed the drivers.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if draft.guest == .linux {
                    Section("Linux") {
                        Toggle("Rosetta for x86-64 binaries", isOn: $draft.rosetta)
                            .disabled(!LinuxRosetta.isSupported)
                        if draft.rosetta && !LinuxRosetta.isInstalled {
                            HStack {
                                Text("Rosetta isn’t installed on this Mac.").foregroundStyle(.secondary)
                                Button("Install") {
                                    Task {
                                        do { try await LinuxRosetta.install() } catch { model.alert = error.localizedDescription }
                                    }
                                }
                            }
                        }
                        HStack {
                            Text("Installer disc")
                            Spacer()
                            Text(draft.installerImagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None")
                                .foregroundStyle(.secondary)
                            Button("Choose…", action: chooseISO)
                            if draft.installerImagePath != nil {
                                Button("Eject") { draft.installerImagePath = nil }
                            }
                        }
                    }
                }

                Section("Notes") {
                    TextEditor(text: $draft.notes).frame(minHeight: 60)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 640)
    }

    private var hostCores: Int { ProcessInfo.processInfo.processorCount }
    private var hostMemoryGiB: Int { max(4, Int(ProcessInfo.processInfo.physicalMemory >> 30) - 2) }

    struct Resolution: Hashable {
        let width: Int
        let height: Int
    }

    static let resolutions = [
        Resolution(width: 1280, height: 800), Resolution(width: 1440, height: 900),
        Resolution(width: 1920, height: 1080), Resolution(width: 1920, height: 1200),
        Resolution(width: 2560, height: 1440), Resolution(width: 2560, height: 1600),
        Resolution(width: 3024, height: 1964), Resolution(width: 3840, height: 2160),
    ]

    private var resolution: Binding<Resolution> {
        Binding(
            get: { Resolution(width: draft.display.width, height: draft.display.height) },
            set: {
                draft.display.width = $0.width
                draft.display.height = $0.height
            })
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Share"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var name = url.lastPathComponent
        var counter = 2
        while draft.sharedFolders.contains(where: { $0.name == name }) {
            name = "\(url.lastPathComponent) \(counter)"
            counter += 1
        }
        draft.sharedFolders.append(SharedFolder(name: name, hostPath: url.path))
    }

    private func chooseISO() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "iso")!, .diskImage]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.installerImagePath = url.path
    }

    private func save() {
        let disk = UInt64.gibibytes(Int(diskGiB))
        model.update(entry) { config in
            if disk > config.diskBytes {
                try DiskImage.grow(at: entry.bundle.diskURL(for: config), to: disk)
            }
            config = draft
            config.memoryBytes = .gibibytes(Int(memoryGiB))
            config.diskBytes = max(disk, entry.config.diskBytes)
        }
        // A suspended state belongs to the old hardware layout.
        var original = entry.config
        var edited = draft
        original.notes = ""
        edited.notes = ""
        if edited != original || Int(memoryGiB) != Int(entry.config.memoryBytes.gibibytes) || disk > entry.config.diskBytes {
            entry.bundle.discardSavedState()
        }
        dismiss()
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String

    var body: some View {
        HStack {
            Text(title)
            Slider(value: $value, in: range, step: 1)
            Text("\(Int(value)) \(unit)")
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
        }
    }
}

/// An optional disc image with Choose… and Eject buttons.
struct DiscRow: View {
    let title: String
    @Binding var path: String?
    let kinds: [String]

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = kinds.compactMap { UTType(filenameExtension: $0) } + [.diskImage]
                if panel.runModal() == .OK, let url = panel.url { path = url.path }
            }
            if path != nil {
                Button("Eject") { path = nil }
            }
        }
    }
}
