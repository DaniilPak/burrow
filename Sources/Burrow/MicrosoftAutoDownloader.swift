import AppKit
import WebKit

/// Gets the Windows 11 ARM64 ISO from Microsoft's official download page in a hidden
/// browser, taking the same steps a person would: choose the Arm64 edition, choose a
/// language, then follow the download link Microsoft generates. If anything doesn't
/// go to plan, the caller shows the page instead.
@MainActor
final class MicrosoftAutoDownloader: NSObject, WKNavigationDelegate {
    enum Failure: Error { case gaveUp(String) }

    private let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900))
    private var continuation: CheckedContinuation<MicrosoftISODownload, Error>?
    private var stage = Stage.loading
    private var timer: Timer?
    private var deadline = Date()

    private enum Stage { case loading, chooseEdition, chooseLanguage, followLink, downloading }

    /// The language Microsoft lists for this Mac's language (falls back to US English).
    static var preferredLanguageName: String {
        let locale = Locale.current
        let code = locale.language.languageCode?.identifier ?? "en"
        if code == "en" {
            return locale.region?.identifier == "US" || locale.region == nil ? "English (United States)" : "English International"
        }
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English (United States)"
    }

    func start() async throws -> MicrosoftISODownload {
        webView.navigationDelegate = self
        deadline = Date().addingTimeInterval(90)
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: MicrosoftDownloadSheet.pageURL))
        }
    }

    func cancel() {
        fail("Cancelled")
        webView.stopLoading()
    }

    // MARK: Page steps

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard stage == .loading else { return }
        stage = .chooseEdition
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard Date() < deadline else { return fail("Microsoft’s page didn’t respond as expected.") }
        switch stage {
        case .chooseEdition:
            run("""
                var s = document.getElementById('product-edition');
                if (!s) return 'wait';
                var o = Array.from(s.options).find(function (o) { return /arm64/i.test(o.textContent); });
                if (!o) return 'missing';
                s.value = o.value; s.dispatchEvent(new Event('change', { bubbles: true }));
                var b = Array.from(document.querySelectorAll('button')).find(function (b) {
                  return /download now/i.test(b.textContent) && b.offsetParent !== null; });
                if (!b) return 'wait';
                b.click(); return 'done';
                """) { [weak self] result in
                if result == "done" { self?.stage = .chooseLanguage }
                if result == "missing" { self?.fail("Microsoft no longer lists the Arm64 ISO there.") }
            }
        case .chooseLanguage:
            let wanted = Self.preferredLanguageName.replacingOccurrences(of: "'", with: "")
            run("""
                var l = document.getElementById('product-languages');
                if (!l || l.options.length < 2) return 'wait';
                var opts = Array.from(l.options).filter(function (o) { return o.value; });
                var o = opts.find(function (o) { return o.textContent.trim().toLowerCase() === '\(wanted)'.toLowerCase(); })
                     || opts.find(function (o) { return o.textContent.trim().toLowerCase().indexOf('\(wanted)'.toLowerCase()) === 0; })
                     || opts.find(function (o) { return /english \\(united states\\)/i.test(o.textContent); });
                if (!o) return 'wait';
                l.value = o.value; l.dispatchEvent(new Event('change', { bubbles: true }));
                var b = Array.from(document.querySelectorAll('button')).find(function (b) {
                  return /confirm/i.test(b.textContent) && b.offsetParent !== null; });
                if (!b) return 'wait';
                b.click(); return 'done';
                """) { [weak self] result in
                if result == "done" { self?.stage = .followLink }
            }
        case .followLink:
            run("""
                var visibleError = Array.from(document.querySelectorAll('[id*=error]')).some(function (e) {
                  return e.offsetParent !== null && e.textContent.trim().length > 0; });
                if (visibleError) return 'error';
                var a = Array.from(document.querySelectorAll('a')).find(function (a) { return /\\.iso(\\?|$)/i.test(a.href); });
                return a ? a.href : 'wait';
                """) { [weak self] result in
                guard let self else { return }
                if result == "error" { return self.fail("Microsoft declined the automatic download.") }
                if let result, result.hasPrefix("https://"), let url = URL(string: result) {
                    self.stage = .downloading
                    self.timer?.invalidate()
                    self.webView.load(URLRequest(url: url))
                }
            }
        case .loading, .downloading:
            break
        }
    }

    /// Runs a function body in the page and reports its string result.
    private func run(_ body: String, completion: @escaping (String?) -> Void) {
        webView.evaluateJavaScript("(function () {\n\(body)\n})()") { result, _ in
            completion(result as? String)
        }
    }

    // MARK: The download itself

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let isDiscImage = response.response.url?.pathExtension.lowercased() == "iso"
        return isDiscImage || !response.canShowMIMEType ? .download : .allow
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        timer?.invalidate()
        continuation?.resume(returning: MicrosoftISODownload(webView: webView, download: download))
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if stage != .downloading { fail(error.localizedDescription) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // Turning a navigation into a download ends it with an error; that's expected.
        if stage != .downloading { fail(error.localizedDescription) }
    }

    private func fail(_ reason: String) {
        timer?.invalidate()
        continuation?.resume(throwing: Failure.gaveUp(reason))
        continuation = nil
    }
}
