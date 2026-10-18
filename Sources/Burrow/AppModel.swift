import BurrowCore
import Combine
import Foundation
import SwiftUI

struct MachineEntry: Identifiable, Hashable {
    let bundle: MachineBundle
    let config: MachineConfig
    var id: URL { bundle.url }
}

/// Background work that ends in a new machine (downloading an OS, installing macOS),
/// shown in the sidebar with its progress.
@MainActor
final class InstallJob: ObservableObject, Identifiable {
    let id = UUID()
    let name: String
    let guest: GuestOS
    @Published var status = "Starting…"
    @Published var fraction: Double?
    @Published var error: String?
    var cancel: (() -> Void)?
    var installerRef: MacInstaller?

    init(name: String, guest: GuestOS) {
        self.name = name
        self.guest = guest
    }

    var summary: String { error ?? status }

    func show(_ phase: MacInstaller.Phase) {
        switch phase {
        case .findingLatest: update("Finding the latest macOS…", nil)
        case .downloading(let fraction): update("Downloading macOS…", fraction)
        case .preparing: update("Preparing…", nil)
        case .installing(let fraction): update("Installing macOS…", fraction)
        case .finished: update("Installed", 1)
        }
    }

    func update(_ status: String, _ fraction: Double?) {
        self.status = fraction.map { "\(status) \(Int($0 * 100))%" } ?? status
        self.fraction = fraction
    }

    /// A progress callback safe to call from any thread.
    func reporter(_ status: String) -> @Sendable (Double) -> Void {
        { [weak self] fraction in Task { @MainActor in self?.update(status, fraction) } }
    }
}

/// Settings chosen in the new-machine sheet for a Windows machine whose ISO comes from Microsoft.
struct WindowsDownloadRequest: Identifiable {
    let id = UUID()
    let name: String
    let cpus: Int
    let memoryGiB: Int
    let diskGiB: Int
    /// The user's own driver disc; nil downloads virtio-win automatically.
    let drivers: URL?
    /// The account for a fully unattended install; nil lets Setup ask.
    let account: GuestAccount?
}

@MainActor
final class AppModel: ObservableObject {
    let library = MachineLibrary()
    @Published private(set) var machines: [MachineEntry] = []
    @Published var selection: URL?
    @Published var installs: [InstallJob] = []
    @Published var alert: String?
    /// Opens Microsoft's download page in a sheet.
    @Published var windowsDownload: WindowsDownloadRequest?
    /// A machine to open in a window and start; the library view acts on it.
    @Published var launchRequest: MachineBundle?
    /// Keeps Windows ISO downloads (and their web views) alive after the sheet closes.
    private var windowsDownloads: [UUID: MicrosoftISODownload] = [:]

    private var sessions: [URL: MachineSession] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init() {
        reload()
    }

    func reload() {
        do {
            machines = try library.machines().compactMap { bundle in
                (try? bundle.loadConfig()).map { MachineEntry(bundle: bundle, config: $0) }
            }
            if let selection, !machines.contains(where: { $0.id == selection }) {
                self.selection = machines.first?.id
            } else if selection == nil {
                selection = machines.first?.id
            }
        } catch {
            alert = error.localizedDescription
        }
    }

    func entry(for url: URL) -> MachineEntry? {
        machines.first { $0.id == url }
    }

    func session(for bundle: MachineBundle) -> MachineSession {
        if let existing = sessions[bundle.url] { return existing }
        let session = MachineSession(bundle: bundle)
        session.onStop = { [weak self] in self?.objectWillChange.send() }
        // Re-render rows and toolbars when any machine changes state.
        session.$status
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        sessions[bundle.url] = session
        return session
    }

    var hasActiveMachines: Bool {
        sessions.values.contains { $0.status.isActive }
    }

    /// Runs a throwing action and shows its error, then refreshes the list.
    func attempt(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            alert = error.localizedDescription
        }
        reload()
    }

    func update(_ entry: MachineEntry, _ change: (inout MachineConfig) throws -> Void) {
        attempt {
            var config = try entry.bundle.loadConfig()
            try change(&config)
            try entry.bundle.saveConfig(config)
        }
    }

    func clone(_ entry: MachineEntry) {
        attempt {
            let name = library.uniqueName(base: "\(entry.config.name) Clone")
            let clone = try library.cloneMachine(entry.bundle, as: name)
            selection = clone.url
        }
    }

    func trash(_ entry: MachineEntry) {
        sessions[entry.bundle.url] = nil
        attempt { try library.trash(entry.bundle) }
    }

    func rename(_ entry: MachineEntry, to name: String) {
        guard name != entry.config.name else { return }
        attempt {
            let renamed = try library.rename(entry.bundle, to: name)
            sessions[entry.bundle.url] = nil
            selection = renamed.url
        }
    }

    // MARK: Creating

    @discardableResult
    func createLinux(name: String, iso: URL?, cpus: Int, memoryGiB: Int, diskGiB: Int) -> MachineBundle? {
        var created: MachineBundle?
        attempt {
            created = try library.createLinuxMachine(
                name: name, installerISO: iso, cpuCount: cpus,
                memoryBytes: .gibibytes(memoryGiB), diskBytes: .gibibytes(diskGiB))
        }
        if let created { selection = created.url }
        return created
    }

    @discardableResult
    func createWindows(name: String, iso: URL?, drivers: URL?, cpus: Int, memoryGiB: Int, diskGiB: Int) -> MachineBundle? {
        guard let iso else { return nil }
        var created: MachineBundle?
        attempt {
            created = try library.createWindowsMachine(
                name: name, installerISO: iso, driversISO: drivers, cpuCount: cpus,
                memoryBytes: .gibibytes(memoryGiB), diskBytes: .gibibytes(diskGiB))
        }
        if let created { selection = created.url }
        return created
    }

    /// Downloads a Linux distribution, creates the machine and starts it.
    func createLinux(from image: CatalogImage, name: String, cpus: Int, memoryGiB: Int, diskGiB: Int) {
        let job = InstallJob(name: name, guest: .linux)
        installs.append(job)
        let downloader = FileDownloader()
        job.cancel = { downloader.cancel() }
        Task {
            do {
                job.update("Finding the latest \(image.name)…", nil)
                let resolved = try await ImageCatalog.resolve(image)
                let iso = try await ImageCatalog.fetch(resolved, downloader: downloader, progress: job.reporter("Downloading \(image.name) \(resolved.version)…"))
                job.update("Creating the machine…", nil)
                finish(job) { try self.library.createLinuxMachine(
                    name: name, installerISO: iso, cpuCount: cpus,
                    memoryBytes: .gibibytes(memoryGiB), diskBytes: .gibibytes(diskGiB)) }
            } catch {
                job.error = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    /// Called by the Microsoft download sheet once the user has clicked Download.
    func adoptWindowsDownload(_ download: MicrosoftISODownload, for request: WindowsDownloadRequest, job existing: InstallJob? = nil) {
        windowsDownload = nil
        let job = existing ?? InstallJob(name: request.name, guest: .windows)
        if existing == nil { installs.append(job) }
        windowsDownloads[job.id] = download
        job.cancel = { [weak self] in
            download.cancel()
            self?.windowsDownloads[job.id] = nil
        }
        // The drivers download alongside the much larger Windows image.
        let driverTask = Task { () throws -> URL? in
            if let drivers = request.drivers { return drivers }
            let resolved = try await ImageCatalog.resolveVirtioWin()
            return try await ImageCatalog.fetch(resolved, downloader: FileDownloader()) { _ in }
        }
        Task {
            do {
                let iso = try await download.finished { fraction in job.update("Downloading Windows 11…", fraction) }
                windowsDownloads[job.id] = nil
                job.update("Getting drivers…", nil)
                let drivers = try await driverTask.value
                job.update("Creating the machine…", nil)
                finish(job) { try self.library.createWindowsMachine(
                    name: request.name, installerISO: iso, driversISO: drivers, account: request.account, cpuCount: request.cpus,
                    memoryBytes: .gibibytes(request.memoryGiB), diskBytes: .gibibytes(request.diskGiB)) }
            } catch {
                driverTask.cancel()
                windowsDownloads[job.id] = nil
                job.error = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    /// The whole thing in one click: sensible hardware, the Mac user's name, no password.
    func quickInstallWindows() {
        let cores = ProcessInfo.processInfo.processorCount
        let memory = Int(ProcessInfo.processInfo.physicalMemory >> 30)
        installWindows(WindowsDownloadRequest(
            name: library.uniqueName(base: "Windows 11"),
            cpus: min(8, max(2, cores / 2)),
            memoryGiB: min(16, max(4, memory / 2)),
            diskGiB: 80,
            drivers: nil,
            account: GuestAccount.suggested()))
    }

    /// Installs Windows from a cached ISO right away; otherwise gets it from Microsoft
    /// automatically, showing Microsoft's page only if that doesn't work.
    func installWindows(_ request: WindowsDownloadRequest) {
        if let iso = ImageCatalog.cachedWindowsISO() {
            createWindows(fromISO: iso, name: request.name, account: request.account, drivers: request.drivers,
                          cpus: request.cpus, memoryGiB: request.memoryGiB, diskGiB: request.diskGiB)
            return
        }
        let job = InstallJob(name: request.name, guest: .windows)
        job.update("Getting Windows 11 from Microsoft…", nil)
        installs.append(job)
        let fetcher = MicrosoftAutoDownloader()
        job.cancel = { fetcher.cancel() }
        Task {
            do {
                let download = try await fetcher.start()
                adoptWindowsDownload(download, for: request, job: job)
            } catch {
                // Fall back to the page itself: two clicks there and Burrow carries on.
                installs.removeAll { $0.id == job.id }
                windowsDownload = request
            }
        }
    }

    /// Windows from an ISO already on this Mac, with drivers downloaded automatically.
    func createWindows(fromISO iso: URL, name: String, account: GuestAccount?, drivers ownDrivers: URL? = nil,
                       cpus: Int, memoryGiB: Int, diskGiB: Int) {
        let job = InstallJob(name: name, guest: .windows)
        installs.append(job)
        let downloader = FileDownloader()
        job.cancel = { downloader.cancel() }
        Task {
            do {
                var drivers = ownDrivers
                if drivers == nil {
                    job.update("Getting drivers…", nil)
                    let resolved = try await ImageCatalog.resolveVirtioWin()
                    drivers = try await ImageCatalog.fetch(resolved, downloader: downloader, progress: job.reporter("Downloading drivers…"))
                }
                job.update("Preparing Windows Setup…", nil)
                finish(job) { try self.library.createWindowsMachine(
                    name: name, installerISO: iso, driversISO: drivers, account: account, cpuCount: cpus,
                    memoryBytes: .gibibytes(memoryGiB), diskBytes: .gibibytes(diskGiB)) }
            } catch {
                job.error = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    /// Creates the machine, removes the job and launches the result.
    private func finish(_ job: InstallJob, create: () throws -> MachineBundle) {
        do {
            let bundle = try create()
            installs.removeAll { $0.id == job.id }
            reload()
            selection = bundle.url
            launchRequest = bundle
        } catch {
            job.error = error.localizedDescription
        }
    }

    /// Starts a background macOS install; `ipsw` nil downloads the latest supported release.
    func installMac(name: String, ipsw: URL?, cpus: Int, memoryGiB: Int, diskGiB: Int) {
        let job = InstallJob(name: name, guest: .macOS)
        job.cancel = { job.installerRef?.cancelDownload() }
        installs.append(job)
        let installer = MacInstaller()
        job.installerRef = installer
        Task {
            do {
                let image: URL
                if let ipsw {
                    image = ipsw
                } else {
                    image = try await installer.downloadLatestRestoreImage { job.show($0) }
                }
                let bundle = try await installer.install(
                    restoreImage: image, name: name, library: library,
                    cpuCount: cpus, memoryBytes: .gibibytes(memoryGiB), diskBytes: .gibibytes(diskGiB)
                ) { job.show($0) }
                installs.removeAll { $0.id == job.id }
                reload()
                selection = bundle.url
            } catch {
                job.error = "Install failed: \(error.localizedDescription)"
                reload()
            }
        }
    }

    func dismiss(_ job: InstallJob) {
        job.cancel?()
        installs.removeAll { $0.id == job.id }
    }
}
