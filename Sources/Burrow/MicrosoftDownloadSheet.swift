import BurrowCore
import SwiftUI
import WebKit

/// Shows Microsoft's official Windows 11 ARM64 download page. Microsoft only hands
/// out ISO links to a person using a browser, so the user picks the edition and
/// language there; as soon as they click Download, Burrow takes the file over.
struct MicrosoftDownloadSheet: View {
    @EnvironmentObject private var model: AppModel
    let request: WindowsDownloadRequest

    static let pageURL = URL(string: "https://www.microsoft.com/en-us/software-download/windows11arm64")!

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Download Windows 11 from Microsoft").font(.headline)
                    Text("Microsoft only gives the download to a person: click **Download Now** below, pick your language, confirm, and click **Download**. Burrow does everything else — drivers, the machine and the whole Windows install. You only do this once; later Windows machines reuse the download.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Cancel") { model.windowsDownload = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            MicrosoftWebView(request: request)
        }
        .frame(width: 980, height: 760)
    }
}

private struct MicrosoftWebView: NSViewRepresentable {
    @EnvironmentObject private var model: AppModel
    let request: WindowsDownloadRequest

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, request: request)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: MicrosoftDownloadSheet.pageURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let model: AppModel
        let request: WindowsDownloadRequest

        init(model: AppModel, request: WindowsDownloadRequest) {
            self.model = model
            self.request = request
        }

        /// Brings the ARM64 ISO section into view with its edition already chosen.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("""
                (function () {
                  var select = document.getElementById('product-edition');
                  if (!select) return;
                  var option = Array.from(select.options).find(function (o) { return /arm64/i.test(o.textContent); });
                  if (option) { select.value = option.value; select.dispatchEvent(new Event('change', { bubbles: true })); }
                  select.scrollIntoView({ block: 'center' });
                })();
                """)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.shouldPerformDownload ? .download : .allow
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            let isDiscImage = response.response.url?.pathExtension.lowercased() == "iso"
            return isDiscImage || !response.canShowMIMEType ? .download : .allow
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            adopt(download, from: webView)
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            adopt(download, from: webView)
        }

        /// Links that open a new window load in this one instead.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            webView.load(action.request)
            return nil
        }

        private func adopt(_ download: WKDownload, from webView: WKWebView) {
            model.adoptWindowsDownload(MicrosoftISODownload(webView: webView, download: download), for: request)
        }
    }
}

/// A Windows ISO download that outlives the sheet it started in.
@MainActor
final class MicrosoftISODownload: NSObject, WKDownloadDelegate {
    // The web view owns the download's networking, so it stays alive with it.
    private let webView: WKWebView
    private let download: WKDownload
    private var observation: NSKeyValueObservation?
    private var destination: URL?
    private var partial: URL?
    private var expectedLength: Int64 = -1
    private var result: Result<URL, Error>?
    private var continuation: CheckedContinuation<URL, Error>?
    private var onProgress: ((Double) -> Void)?

    init(webView: WKWebView, download: WKDownload) {
        self.webView = webView
        self.download = download
        super.init()
        download.delegate = self
        observation = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in self?.onProgress?(fraction) }
        }
    }

    /// Waits for the file, reporting progress along the way.
    func finished(progress: @escaping (Double) -> Void) async throws -> URL {
        onProgress = progress
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func cancel() {
        download.cancel { _ in }
        complete(.failure(CancellationError()))
    }

    /// The download is written beside its final name as ".partial" and only renamed once
    /// complete, so an interrupted download never looks like a usable ISO.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let directory = ImageCatalog.cacheDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = suggestedFilename.isEmpty ? "Windows11_ARM64.iso" : suggestedFilename
        let destination = directory.appendingPathComponent(name)
        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        self.destination = destination
        self.partial = partial
        expectedLength = response.expectedContentLength
        return partial
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let destination, let partial else { return complete(.failure(BurrowError.downloadFailed("The download had no destination."))) }
        let size = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard expectedLength <= 0 || size == expectedLength, ImageCatalog.looksLikeDiscImage(partial) else {
            try? FileManager.default.removeItem(at: partial)
            return complete(.failure(BurrowError.downloadFailed("The Windows download was incomplete. Try again.")))
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partial, to: destination)
            complete(.success(destination))
        } catch {
            complete(.failure(error))
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let partial { try? FileManager.default.removeItem(at: partial) }
        complete(.failure(error))
    }

    private func complete(_ result: Result<URL, Error>) {
        guard self.result == nil else { return }
        self.result = result
        observation = nil
        continuation?.resume(with: result)
        continuation = nil
    }
}
