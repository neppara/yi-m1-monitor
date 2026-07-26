// HTTP control client - port of yi-m1-remote-control/app/camera_session.py's _send /
// _do_download / _download_preview_with_progress.
//
// Endpoint: GET http://192.168.0.10/?data=<json>, json = {"command":"...", ...}.
//
// *** PROTOCOL COMPATIBILITY - RESOLVED 2026-07-08 after on-device testing ***
// GetFile/DeleteFile (both have a "/"-containing camera file path) failed on-device while
// slash-free commands (GetFileList, GetCameraStatus) worked. Two independent bugs, both about
// forward slashes, both now fixed:
// 1. `JSONSerialization.data(withJSONObject:)` escapes "/" as "\/" in its output by default (a
//    legacy JS-embedding-safety behavior; Python's `json.dumps`, which the reference uses, does
//    NOT do this) - so a path like "/DCIM/100YICAM/P1.DNG" was actually being sent as
//    "\/DCIM\/100YICAM\/P1.DNG". Valid JSON (`\/` is a legal escape for `/`), but the camera's
//    embedded parser almost certainly doesn't bother unescaping it, so the path it read back
//    never matched a real file. Fixed by stripping the escape back out post-serialization (safe
//    here since nothing in this app's command vocabulary ever contains a literal backslash).
// 2. This file previously ALSO percent-encoded the resulting JSON string before building the URL
//    (conservatively, RFC 3986 "unreserved" characters only), turning "/" into "%2F" - on top of
//    the above. Removed: `URL(string:)` accepts the raw JSON directly (verified empirically - it
//    only forces its own encoding for "[" / "]" -> %5B/%5D), which is much closer to what the
//    Python reference sends (it puts the raw json.dumps() output straight into the URL, unescaped,
//    and urllib3 doesn't re-encode it).
import Foundation

// *** ONE REQUEST AT A TIME - the camera cannot handle concurrent HTTP (found on-device
// 2026-07-08) ***
// The macOS reference runs ALL its HTTP on a single thread through a request queue, so requests
// are naturally sequential and urllib3 reuses one keep-alive TCP connection. This port's callers
// are concurrent Swift Tasks (the 5s GetCameraStatus poll, GetFileList, downloads, setting
// changes can all fire at once), and URLSession additionally opens parallel TCP connections per
// host by default. The camera's embedded server rejects that with {"code":1515,"rc only one"} -
// observed as "opening the file browser fails the first time, works the second" (the first
// GetFileList collided with an in-flight status poll; the retry landed between polls). Two
// defenses, both needed: every send()/download() is serialized through `chainTail` below (so
// requests are strictly one-after-another, like the macOS thread), and the default URLSession is
// configured with httpMaximumConnectionsPerHost = 1 (so even a bug in the serialization can't
// open a second TCP connection to the camera).
public actor HTTPClient {
    public struct Response: Sendable {
        public let status: Int
        public let body: Data

        /// The camera reports command failures as HTTP 200 with an error code in the JSON body
        /// (observed live: {"code":1515,"data":"rc only one"}, {"code":1502,"data":"get filelist
        /// err"}) - the transport status alone is NOT success. Found the hard way on-device
        /// 2026-07-09: rapid record start/stop cycles desynced the UI from the camera because a
        /// failed VideoRecordingStop still came back as HTTP 200 and the recording flag was
        /// flipped anyway. True when the transport succeeded AND the body either carries
        /// code 200 or isn't JSON-with-a-code at all (some success responses are raw data).
        public var isCameraSuccess: Bool {
            guard status == 200 else { return false }
            guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                return true
            }
            if let code = obj["code"] as? Int { return code == 200 }
            if let codeString = obj["code"] as? String, let code = Int(codeString) { return code == 200 }
            return true
        }
    }

    public enum HTTPClientError: Error, Sendable {
        case invalidURL
        case badResponse
    }

    private let host: String
    private let session: URLSession

    /// Tail of the request chain - each new request awaits the previous one's completion first.
    private var chainTail: Task<Void, Never>?

    public init(host: String = "192.168.0.10", session: URLSession? = nil) {
        self.host = host
        self.session = session ?? {
            let config = URLSessionConfiguration.ephemeral
            config.httpMaximumConnectionsPerHost = 1
            return URLSession(configuration: config)
        }()
    }

    /// Runs `op` only after every previously-enqueued request has fully completed - the actor's
    /// own isolation is not enough (it releases during `await session.data(...)`, letting a
    /// second request start mid-flight), hence this explicit chain.
    private func serialized<T: Sendable>(_ op: @escaping @Sendable () async -> T) async -> T {
        let previous = chainTail
        let task = Task<T, Never> {
            await previous?.value
            return await op()
        }
        chainTail = Task { _ = await task.value }
        return await task.value
    }

    // internal, not private, so HTTPClientTests can assert on the exact URL built (see file
    // header - this is the exact spot the on-device GetFile/DeleteFile bug lived in).
    func buildURL(_ command: [String: Any]) -> URL? {
        guard JSONSerialization.isValidJSONObject(command),
              let jsonData = try? JSONSerialization.data(withJSONObject: command, options: [.sortedKeys]),
              var jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }
        // Undo JSONSerialization's default "/" -> "\/" escaping (see file header) - matches what
        // Python's json.dumps actually sends.
        jsonString = jsonString.replacingOccurrences(of: "\\/", with: "/")

        // Send the raw JSON directly, matching the proven-working Python reference as closely as
        // Foundation's URL parser allows (see file header) - this keeps "/" in file paths literal
        // instead of turning it into "%2F", which broke GetFile/DeleteFile on-device.
        if let url = URL(string: "http://\(host)/?data=\(jsonString)") {
            return url
        }
        // Fallback for the rare command value URL(string:) can't parse raw at all.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = jsonString.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "http://\(host)/?data=\(encoded)")
    }

    /// Send a command and get back the raw status + body. Never decodes the body as text
    /// implicitly for the caller - JSON commands should JSON-parse it themselves; GetFile
    /// callers must use `download(_:)` instead, which preserves raw bytes (decoding as UTF-8
    /// text here would corrupt binary JPEG/DNG/MP4 data - see camera_session.py's _do_download
    /// comment for the same lesson learned on macOS).
    public func send(_ command: [String: Any], timeout: TimeInterval = 3.0) async -> Response {
        guard let url = buildURL(command) else {
            return Response(status: 0, body: Data())
        }
        let session = self.session
        return await serialized {
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = "GET"
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                return Response(status: status, body: data)
            } catch {
                return Response(status: 0, body: Data())
            }
        }
    }

    /// Convenience for the common [String: String] command builders.
    public func send(_ command: [String: String], timeout: TimeInterval = 3.0) async -> Response {
        await send(command as [String: Any], timeout: timeout)
    }

    /// Streaming download with progress, for GetFile - both the fast MidThumb photo-review
    /// preview and full-size Original downloads (which can be ~32MB, confirmed via a real DNG -
    /// see fable research/live-testing-findings.md bug #11). Reports (bytesReceived, totalBytes)
    /// as data arrives; totalBytes is -1 if the camera doesn't send Content-Length (observed to
    /// always send it in testing, but don't assume).
    ///
    /// Performance note: iterates the response byte-by-byte via URLSession's AsyncBytes, which
    /// is correct but not maximally fast for large files. If 32MB downloads feel slow on-device,
    /// switching to URLSessionDownloadTask with delegate-based progress is the known fix -
    /// not done here to keep this dependency-free and simple for v1.
    /// Hard ceiling for downloads kept in memory. A thumbnail/preview is ~228 KB; anything
    /// approaching this is the camera streaming a whole file, which must never be buffered on a
    /// phone. Use `download(_:to:...)` for real files - it streams to disk instead.
    public static let maxInMemoryDownloadBytes = 32 * 1024 * 1024

    public func download(
        _ command: [String: Any],
        timeout: TimeInterval = 30.0,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> Data {
        guard let url = buildURL(command) else { throw HTTPClientError.invalidURL }
        let session = self.session
        // Serialized like send() - a download holds the chain for its whole duration, so e.g.
        // the status poll queues behind it instead of opening a second connection the camera
        // would reject. (A queued send just waits - its URLRequest timeout doesn't start
        // ticking until the request is actually sent.)
        let result: Result<Data, Error> = await serialized {
            do {
                return .success(try await Self.performDownload(
                    session: session, url: url, timeout: timeout,
                    destination: nil, maxBytes: Self.maxInMemoryDownloadBytes,
                    onProgress: onProgress))
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }

    /// Streams a response straight to `destination` on disk.
    ///
    /// Added 2026-07-24 after review: the in-memory path accumulated the WHOLE file in a `Data`
    /// (and even called `reserveCapacity(Content-Length)` up front). A clip off this camera runs
    /// up to the 4 GB FAT32 ceiling, so downloading one on an iPhone reserved gigabytes and got
    /// the app killed by jetsam long before it finished. Bytes now go to a file handle in 64 KB
    /// chunks and peak memory stays flat regardless of file size.
    public func download(
        _ command: [String: Any],
        to destination: URL,
        timeout: TimeInterval = 300.0,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async throws {
        guard let url = buildURL(command) else { throw HTTPClientError.invalidURL }
        let session = self.session
        let result: Result<Void, Error> = await serialized {
            do {
                _ = try await Self.performDownload(
                    session: session, url: url, timeout: timeout,
                    destination: destination, maxBytes: nil, onProgress: onProgress)
                return .success(())
            } catch {
                // Never leave a truncated file behind: it looks valid in Files and fails to play.
                try? FileManager.default.removeItem(at: destination)
                return .failure(error)
            }
        }
        return try result.get()
    }

    private static func performDownload(
        session: URLSession,
        url: URL,
        timeout: TimeInterval,
        destination: URL?,
        maxBytes: Int?,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"

        let (asyncBytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPClientError.badResponse
        }

        let total: Int = {
            guard let lengthHeader = httpResponse.value(forHTTPHeaderField: "Content-Length"),
                  let length = Int(lengthHeader) else { return -1 }
            return length
        }()

        // Chunked, not byte-by-byte: `append` per byte over an AsyncSequence means one
        // iteration per byte - billions of them for a multi-GB clip. 64 KB chunks keep both the
        // allocation count and the progress-callback rate sane.
        let chunkSize = 64 * 1024
        var handle: FileHandle?
        if let destination {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            handle = try FileHandle(forWritingTo: destination)
        }
        defer { try? handle?.close() }

        var data = Data()            // stays empty when streaming to disk
        var chunk = Data()
        chunk.reserveCapacity(chunkSize)
        var received = 0
        var lastReported = 0

        func flush() throws {
            guard !chunk.isEmpty else { return }
            if let handle {
                try handle.write(contentsOf: chunk)
            } else {
                data.append(chunk)
            }
            chunk.removeAll(keepingCapacity: true)
        }

        for try await byte in asyncBytes {
            chunk.append(byte)
            received += 1
            if chunk.count >= chunkSize {
                try flush()
            }
            // Only in-memory downloads are capped; a disk-bound one may legitimately be huge.
            if let maxBytes, received > maxBytes {
                throw NSError(domain: "YiM1Core.HTTPClient", code: -2, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Response exceeded \(maxBytes) bytes - the camera is streaming a whole "
                        + "file rather than a preview (expected for video). Aborted.",
                ])
            }
            if received - lastReported >= chunkSize {
                onProgress(received, total)
                lastReported = received
            }
        }
        try flush()
        onProgress(received, total)

        guard httpResponse.statusCode == 200 else {
            throw NSError(domain: "YiM1Core.HTTPClient", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)",
                "bodyPreview": String(data: data.prefix(200), encoding: .utf8) ?? "<binary>",
            ])
        }
        return data
    }
}
