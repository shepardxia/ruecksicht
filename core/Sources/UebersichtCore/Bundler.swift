import Foundation

/// Builds widget bundles by invoking the esbuild binary directly.
///
/// esbuild ships as a native executable, so bundling needs no JavaScript
/// runtime of its own. A bundle registers its exports on globalThis.__ubWidgets
/// under the widget's id, and resolves `uebersicht` to the page's own copy so
/// React and emotion are shared rather than duplicated per widget.
public final class Bundler {
    private let esbuild: String
    private let shimPath: String
    private let cacheDirectory: String
    private var cache: [String: (source: String, modified: Date)] = [:]
    private let lock = NSLock()

    public init?(esbuildPath: String? = nil, cacheDirectory: String) {
        guard let binary = esbuildPath ?? Self.locate() else { return nil }
        self.esbuild = binary
        self.cacheDirectory = cacheDirectory
        self.shimPath = (cacheDirectory as NSString).appendingPathComponent("uebersicht-shim.js")

        try? FileManager.default.createDirectory(
            atPath: cacheDirectory, withIntermediateDirectories: true
        )
        try? "module.exports = globalThis.__ubersicht;\n".write(
            toFile: shimPath, atomically: true, encoding: .utf8
        )
    }

    private static func locate() -> String? {
        let candidates = [
            "node_modules/@esbuild/darwin-arm64/bin/esbuild",
            "node_modules/@esbuild/darwin-x64/bin/esbuild",
            "node_modules/.bin/esbuild",
        ]
        let roots = [
            FileManager.default.currentDirectoryPath,
            (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent("server"),
        ]
        for root in roots {
            for candidate in candidates {
                let path = (root as NSString).appendingPathComponent(candidate)
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        return ["/opt/homebrew/bin/esbuild", "/usr/local/bin/esbuild"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    public func bundle(_ widget: Widget) throws -> String {
        lock.lock()
        if let cached = cache[widget.id], cached.modified == widget.modified {
            lock.unlock()
            return cached.source
        }
        lock.unlock()

        let footer = """
            globalThis.__ubWidgets=globalThis.__ubWidgets||{};\
            globalThis.__ubWidgets["\(widget.id)"]=__ubWidget&&__ubWidget.default\
            &&Object.keys(__ubWidget).length===1?__ubWidget.default:__ubWidget;
            """

        var arguments = [
            widget.path,
            "--bundle",
            "--format=iife",
            "--global-name=__ubWidget",
            "--platform=browser",
            "--target=safari15",
            "--jsx=transform",
            "--jsx-factory=html",
            "--jsx-fragment=html.Fragment",
            "--loader:.js=jsx",
            "--alias:uebersicht=\(shimPath)",
            "--footer:js=\(footer)",
        ]
        if widget.path.hasSuffix(".jsx") { arguments.append("--loader:.jsx=jsx") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: esbuild)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()

        let source = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let failure = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "ub.bundler", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: failure]
            )
        }

        lock.lock()
        cache[widget.id] = (source, widget.modified)
        lock.unlock()
        return source
    }
}
