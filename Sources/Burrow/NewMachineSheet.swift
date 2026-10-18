import AppKit
import BurrowCore
import SwiftUI
import UniformTypeIdentifiers

struct NewMachineSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// Where the operating system comes from: downloaded by Burrow, or a file the user has.
    enum Source: Hashable {
        case download
        case file
    }

    @State private var guest: GuestOS = .windows
    @State private var name = ""
    @State private var source: Source = .download
    @State private var distro: CatalogImage = ImageCatalog.ubuntuDesktop
    @State private var isoURL: URL?
    @State private var ipswURL: URL?
    @State private var driversURL: URL?
    @State private var downloadDrivers = true
    @State private var account = GuestAccount.suggested()
    @State private var automaticSetup = true
    private let cachedWindows = ImageCatalog.cachedWindowsISO()
    @State private var cpus = min(4, ProcessInfo.processInfo.processorCount)
    @State private var memoryGiB: Double = 4
    @State private var diskGiB: Double = 64

    private let hostCores = ProcessInfo.processInfo.processorCount
    private let hostMemoryGiB = max(4, Int(ProcessInfo.processInfo.physicalMemory >> 30) - 2)

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Operating system", selection: $guest) {
                        ForEach(GuestOS.allCases, id: \.self) { guest in
                            Label(guest.displayName, systemImage: guest.symbolName).tag(guest)
                        }
                    }
                    .pickerStyle(.segmented)
                    TextField("Name", text: $name, prompt: Text(defaultName))
                }

                switch guest {
                case .linux: linuxSection
                case .windows: windowsSection
                case .macOS: macSection
                }

                Section("Hardware") {
                    Stepper("Processors: \(cpus)", value: $cpus, in: 1...hostCores)
                    LabeledSlider(title: "Memory", value: $memoryGiB, range: 2...Double(hostMemoryGiB), unit: "GB")
                    LabeledSlider(title: "Disk", value: $diskGiB, range: 16...1024, unit: "GB")
                    Text("The disk is sparse: it only takes up the space the guest actually uses.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(primaryTitle, action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
            .padding()
        }
        .frame(width: 580, height: 640)
        .onChange(of: guest) {
            source = .download
            isoURL = nil
            memoryGiB = guest == .linux ? 4 : min(8, Double(hostMemoryGiB))
            diskGiB = guest == .linux ? 64 : 80
        }
        .onAppear {
            memoryGiB = min(8, Double(hostMemoryGiB))
            diskGiB = 80
        }
    }

    // MARK: Sections

    private var linuxSection: some View {
        Section("Distribution") {
            Picker("Source", selection: $source) {
                Text("Download for me").tag(Source.download)
                Text("Use an ISO on this Mac").tag(Source.file)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if source == .download {
                Picker("Distribution", selection: $distro) {
                    ForEach(ImageCatalog.linux) { image in
                        Text("\(image.name) — \(image.summary)").tag(image)
                    }
                }
                Text("Burrow downloads the latest release (\(distro.approximateSize)) from the publisher’s servers, checks its signature checksum, and starts the installer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                fileRow(isoURL, placeholder: "No ISO chosen", button: "Choose ISO…", action: chooseISO)
                Text("Any ARM64 (aarch64) Linux ISO.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var windowsSection: some View {
        Group {
            Section("Windows 11") {
                Picker("Source", selection: $source) {
                    Text("Get it from Microsoft").tag(Source.download)
                    Text("Use an ISO on this Mac").tag(Source.file)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if source == .download {
                    if let cachedWindows {
                        Label("Already downloaded (\(cachedWindows.lastPathComponent)). Installs right away.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("Burrow downloads Windows 11 from Microsoft for you (≈ 5 GB) and keeps it for later machines.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    fileRow(isoURL, placeholder: "No Windows 11 ARM64 ISO chosen", button: "Choose ISO…", action: chooseISO)
                }
            }
            Section("Your Windows account") {
                Toggle("Install automatically (no setup screens)", isOn: $automaticSetup)
                if automaticSetup {
                    TextField("Full name", text: $account.fullName)
                    TextField("Username", text: $account.username)
                    SecureField("Password (optional)", text: $account.password)
                    Text("Burrow installs Windows 11 Pro, creates this account and signs you in. Activate Windows later with your own license.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Download drivers automatically (virtio-win, ≈ 880 MB)", isOn: $downloadDrivers)
                if !downloadDrivers {
                    fileRow(driversURL, placeholder: "No driver disc — Windows will have no network", button: "Choose…", action: chooseDrivers)
                }
            }
        }
    }

    private var macSection: some View {
        Section("macOS") {
            Picker("Source", selection: $source) {
                Text("Download the latest from Apple").tag(Source.download)
                Text("Use an IPSW on this Mac").tag(Source.file)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if source == .file {
                fileRow(ipswURL, placeholder: "No IPSW chosen", button: "Choose IPSW…", action: chooseIPSW)
            } else {
                Text("About 15 GB, kept in Burrow’s cache for later installs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func fileRow(_ url: URL?, placeholder: String, button: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(url?.lastPathComponent ?? placeholder)
                .foregroundStyle(url == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(button, action: action)
        }
    }

    // MARK: Derived

    private var defaultName: String {
        if guest == .linux, source == .download { return model.library.uniqueName(base: distro.machineName) }
        if guest == .linux, let isoURL {
            return model.library.uniqueName(base: isoURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "/", with: "-"))
        }
        return model.library.uniqueName(base: guest == .windows ? "Windows 11" : guest.displayName)
    }

    private var finalName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultName : trimmed
    }

    private var canCreate: Bool {
        switch (guest, source) {
        case (.windows, _) where automaticSetup && (try? account.validate(requirePassword: false)) == nil: false
        case (_, .download): true
        case (.linux, .file), (.windows, .file): isoURL != nil
        case (.macOS, .file): ipswURL != nil
        }
    }

    private var primaryTitle: String {
        switch (guest, source) {
        case (.windows, .download): "Install Windows"
        case (.windows, .file): "Install Windows"
        case (_, .download): "Download & Create"
        case (.macOS, .file): "Install"
        default: "Create"
        }
    }

    private var footnote: String {
        source == .download ? "Downloads continue in the sidebar." : ""
    }

    // MARK: Actions

    private func chooseISO() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage, .diskImage]
        if panel.runModal() == .OK { isoURL = panel.url }
    }

    private func chooseDrivers() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage, .diskImage]
        if panel.runModal() == .OK { driversURL = panel.url }
    }

    private func chooseIPSW() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipsw") ?? .data]
        if panel.runModal() == .OK { ipswURL = panel.url }
    }

    private func create() {
        do {
            try model.library.validate(name: finalName)
        } catch {
            model.alert = error.localizedDescription
            return
        }
        let memory = Int(memoryGiB)
        let disk = Int(diskGiB)
        switch (guest, source) {
        case (.linux, .download):
            model.createLinux(from: distro, name: finalName, cpus: cpus, memoryGiB: memory, diskGiB: disk)
            dismiss()
        case (.windows, .download):
            let request = WindowsDownloadRequest(
                name: finalName, cpus: cpus, memoryGiB: memory, diskGiB: disk,
                drivers: downloadDrivers ? nil : driversURL, account: automaticSetup ? account : nil)
            dismiss()
            // Microsoft's page (if needed) appears once this sheet has gone away.
            DispatchQueue.main.async { model.installWindows(request) }
        case (.windows, .file):
            model.createWindows(fromISO: isoURL!, name: finalName, account: automaticSetup ? account : nil,
                                drivers: downloadDrivers ? nil : driversURL, cpus: cpus, memoryGiB: memory, diskGiB: disk)
            dismiss()
        case (.linux, .file):
            guard let bundle = model.createLinux(name: finalName, iso: isoURL, cpus: cpus, memoryGiB: memory, diskGiB: disk) else { return }
            dismiss()
            model.launchRequest = bundle
        case (.macOS, _):
            model.installMac(name: finalName, ipsw: source == .file ? ipswURL : nil, cpus: cpus, memoryGiB: memory, diskGiB: disk)
            dismiss()
        }
    }
}
