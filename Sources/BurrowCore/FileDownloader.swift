import CryptoKit
import Foundation

/// Downloads a large file with progress, verifies it and moves it into place atomically.
public final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var progress: (@Sendable (Double) -> Void)?
    private var task: URLSessionDownloadTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    public override init() {}

    /// Downloads `source` to `destination`. When `checksum` is given the file must match it.
    public func download(from source: URL, to destination: URL, checksum: Checksum? = nil,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        self.progress = progress
        let temporary: URL = try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let task = session.downloadTask(with: source)
            self.task = task
            task.resume()
        }
        session.finishTasksAndInvalidate()
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let checksum {
            progress(1)
            let actual = switch checksum {
            case .sha256: try Self.digest(of: temporary, using: SHA256())
            case .sha512: try Self.digest(of: temporary, using: SHA512())
            }
            guard actual == checksum.value else {
                throw BurrowError.downloadFailed("\(source.lastPathComponent) is corrupt (checksum mismatch). Try again.")
            }
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    public func cancel() {
        task?.cancel()
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            finish(.failure(BurrowError.downloadFailed("The server answered \(response.statusCode) for \(downloadTask.originalRequest?.url?.lastPathComponent ?? "the download").")))
            return
        }
        // The system deletes `location` when this method returns, so keep our own copy.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-download-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    /// Refuses redirects to plain HTTP by upgrading them to HTTPS.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.upgradedToHTTPS)
    }

    private func finish(_ result: Result<URL, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    public static func sha256(of url: URL) throws -> String {
        try digest(of: url, using: SHA256())
    }

    static func digest<H: HashFunction>(of url: URL, using hasher: H) throws -> String {
        var hasher = hasher
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension URLRequest {
    var upgradedToHTTPS: URLRequest {
        guard let url, url.scheme == "http", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return self }
        components.scheme = "https"
        var request = self
        request.url = components.url
        return request
    }
}
