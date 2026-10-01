import Foundation

extension HTTPResponse {
    /// The file at `path`, or nil when there is none, answering 304 to a
    /// request that already holds it. Pages rely on that: a response they
    /// cannot revalidate is downloaded and decoded anew on every use.
    public static func file(at path: String, for request: HTTPRequest) -> HTTPResponse? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }

        let modified = info.st_mtimespec.tv_sec * 1000 + info.st_mtimespec.tv_nsec / 1_000_000
        let etag = "\"\(info.st_size)-\(modified)\""
        let headers = ["Content-Type": contentType(for: path), "ETag": etag, "Cache-Control": "no-cache"]
        if request.headers["if-none-match"] == etag {
            return HTTPResponse(status: 304, headers: headers)
        }
        guard let body = FileManager.default.contents(atPath: path) else { return nil }
        return HTTPResponse(headers: headers, body: body)
    }

    static func contentType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "jsx": return "application/javascript; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }
}
