// A file entry from GetFileList - port of the parsing in
// yi-m1-remote-control/app/main_window.py's FileBrowserDialog._populate_from_list_response.
//
// Confirmed real response shape (2026-07-07, bug #11): {"code":200,"data":[{"path":"...",
// "date":"<unix timestamp string>","filetype":"picture"|"rawJpeg"|"raw"|"video",
// "protectStatus":false}, ...]}. Parsing keeps a raw-fallback path (see
// FileListResponse.parse) since a different firmware/response shape isn't impossible.
import Foundation

public struct CameraFile: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public let date: Date?
    public let filetype: String
    public let isProtected: Bool

    public init(path: String, date: Date?, filetype: String, isProtected: Bool) {
        self.path = path
        self.date = date
        self.filetype = filetype
        self.isProtected = isProtected
    }

    public var filename: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Used to pick the right Photos asset resource type (.photo vs .video) when saving, and to
    /// choose a fallback type icon when a thumbnail/preview fails to decode.
    public var isVideo: Bool {
        if filetype.lowercased().contains("video") { return true }
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "mp4" || ext == "mov"
    }
}

public enum FileListResponse {
    /// Parses a GetFileList response body. Returns `.ok([CameraFile])` on the confirmed real
    /// shape, `.unrecognized(String)` with a raw preview if the shape doesn't match (so a
    /// caller can show *something* instead of silently failing), or `.cameraError(code,
    /// message)` for a non-200 HTTP status.
    public enum Result {
        case ok([CameraFile])
        case unrecognized(String)
        case httpError(status: Int, bodyPreview: String)
        case parseFailure(String)
    }

    public static func parse(status: Int, body: Data) -> Result {
        guard status == 200 else {
            let preview = String(data: body.prefix(200), encoding: .utf8) ?? "<binary>"
            return .httpError(status: status, bodyPreview: preview)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            let preview = String(data: body.prefix(300), encoding: .utf8) ?? "<binary>"
            return .parseFailure(preview)
        }

        // The confirmed real shape has `data` as a bare array of file dicts. Some tolerance for
        // alternate shapes (data.file_list / data.files / data.list) is kept in case a
        // different firmware nests it, mirroring the macOS fallback logic.
        var candidates: [Any]?
        if let arr = obj["data"] as? [Any] {
            candidates = arr
        } else if let nested = obj["data"] as? [String: Any] {
            for key in ["file_list", "files", "list"] {
                if let arr = nested[key] as? [Any] {
                    candidates = arr
                    break
                }
            }
        }

        guard let candidates else {
            let raw = (try? JSONSerialization.data(withJSONObject: obj))
                .flatMap { String(data: $0.prefix(300), encoding: .utf8) } ?? "<unprintable>"
            return .unrecognized(raw)
        }

        let files: [CameraFile] = candidates.compactMap { entry in
            guard let dict = entry as? [String: Any] else {
                if let s = entry as? String { return CameraFile(path: s, date: nil, filetype: "", isProtected: false) }
                return nil
            }
            let path = (dict["path"] as? String) ?? (dict["name"] as? String) ?? (dict["file"] as? String) ?? ""
            guard !path.isEmpty else { return nil }
            var date: Date?
            if let dateString = dict["date"] as? String, let epoch = TimeInterval(dateString) {
                date = Date(timeIntervalSince1970: epoch)
            } else if let epochNumber = dict["date"] as? Double {
                date = Date(timeIntervalSince1970: epochNumber)
            }
            let filetype = (dict["filetype"] as? String) ?? ""
            let isProtected = (dict["protectStatus"] as? Bool) ?? false
            return CameraFile(path: path, date: date, filetype: filetype, isProtected: isProtected)
        }
        return .ok(files)
    }
}
