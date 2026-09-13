import Foundation
import UebersichtCore

// Serves the widget pages, their bundles and their shell commands.
// Replaces the bundled Node server: bundling shells out to the esbuild binary
// and commands run in persistent shells, so no JavaScript runtime is involved.

struct Options {
    var port: UInt16 = 41416
    var widgetDirectory = "\(NSHomeDirectory())/Library/Application Support/Übersicht/widgets"
    var publicDirectory = "server/public"
    var loginShell = false
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while let flag = arguments.first {
        arguments.removeFirst()
        switch flag {
        case "-p", "--port":
            if let value = arguments.first, let port = UInt16(value) {
                options.port = port
                arguments.removeFirst()
            }
        case "-d", "--dir":
            if let value = arguments.first {
                options.widgetDirectory = value
                arguments.removeFirst()
            }
        case "--public":
            if let value = arguments.first {
                options.publicDirectory = value
                arguments.removeFirst()
            }
        case "--login-shell":
            options.loginShell = true
        default:
            break
        }
    }
    return options
}

let options = parseOptions()

let shells = ShellPool(
    workingDirectory: options.widgetDirectory,
    loginShell: options.loginShell
)

guard
    let bundler = Bundler(
        cacheDirectory: NSTemporaryDirectory() + "ubersichtd"
    )
else {
    FileHandle.standardError.write(Data("could not find the esbuild binary\n".utf8))
    exit(1)
}

let allowedOrigin = "http://127.0.0.1:\(options.port)"

func contentType(for path: String) -> String {
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

func serveFile(_ path: String) -> HTTPResponse? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
          !isDirectory.boolValue,
          let data = FileManager.default.contents(atPath: path)
    else { return nil }
    return HTTPResponse(status: 200, contentType: contentType(for: path), body: data)
}

func widgetsJSON() -> String {
    let entries = WidgetDirectory.scan(options.widgetDirectory).map { widget -> String in
        let escapedPath = widget.path.replacingOccurrences(of: "\"", with: "\\\"")
        return """
            "\(widget.id)":{"id":"\(widget.id)","filePath":"\(escapedPath)",\
            "mtime":\(Int(widget.modified.timeIntervalSince1970 * 1000))}
            """
    }
    return "{\"widgets\":{\(entries.joined(separator: ","))},\"settings\":{},\"screens\":[]}"
}

let server = try HTTPServer(port: options.port) { request in
    let path = request.path.components(separatedBy: "?")[0]

    // Any local process can reach the loopback port, so a request that runs a
    // shell command must come from the page itself.
    if request.method != "GET", request.headers["origin"] != allowedOrigin {
        return HTTPResponse.text("", status: 403)
    }

    if request.method == "POST", path == "/run/" {
        let command = String(decoding: request.body, as: UTF8.self)
        do {
            let result = try shells.run(command)
            return HTTPResponse(
                status: result.stderr.isEmpty ? 200 : 500,
                body: Data((result.stdout + result.stderr).utf8)
            )
        } catch {
            return HTTPResponse.text("\(error)", status: 500)
        }
    }

    if path == "/state/" {
        return HTTPResponse.json(widgetsJSON())
    }

    if path.hasPrefix("/widgets/") {
        let id = String(path.dropFirst("/widgets/".count))
        guard let widget = WidgetDirectory.scan(options.widgetDirectory).first(where: { $0.id == id })
        else { return HTTPResponse.text("", status: 404) }
        do {
            return HTTPResponse(
                status: 200,
                contentType: "application/javascript; charset=utf-8",
                body: Data(try bundler.bundle(widget).utf8)
            )
        } catch {
            return HTTPResponse.text("\(error)", status: 500)
        }
    }

    let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
    if !relative.isEmpty, !relative.contains("..") {
        for root in [options.publicDirectory, options.widgetDirectory] {
            if let file = serveFile((root as NSString).appendingPathComponent(relative)) {
                return file
            }
        }
    }

    // Every screen and layer path renders the same page.
    if let index = serveFile((options.publicDirectory as NSString).appendingPathComponent("index.html")) {
        return index
    }
    return HTTPResponse.text("not found", status: 404)
}

server.start()

let widgets = WidgetDirectory.scan(options.widgetDirectory)
print("ubersichtd on \(allowedOrigin)")
print("watching \(options.widgetDirectory)")
print("\(widgets.count) widget(s): \(widgets.map(\.id).joined(separator: ", "))")

signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }
dispatchMain()
