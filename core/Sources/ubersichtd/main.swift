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
    var token: String?
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
        case "--token":
            if let value = arguments.first {
                options.token = value
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

// The app reads this process's stdout through a pipe and watches for the
// startup line; buffered output would strand it waiting.
setvbuf(stdout, nil, _IONBF, 0)

let options = parseOptions()

let shells = ShellPool(
    workingDirectory: options.widgetDirectory,
    loginShell: options.loginShell
)

let bundler: Bundler
do {
    bundler = try Bundler(cacheDirectory: NSTemporaryDirectory() + "ubersichtd")
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

let allowedOrigin = "http://127.0.0.1:\(options.port)"
let hub = WebSocketHub()
let index = WidgetIndex(directory: options.widgetDirectory)

func jsonString(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
    return "\"\(escaped)\""
}

func widgetPayload(_ widget: Widget) -> String {
    // No "error" key when there is no error: the app reads it as `if (error)`,
    // and a JSON null deserializes to NSNull, which is not nil. Every healthy
    // widget would look like a failing one.
    return """
        {"id":\(jsonString(widget.id)),"filePath":\(jsonString(widget.path)),\
        "serverDriven":\(index.isServerDriven(widget.id)),\
        "mtime":\(Int(widget.modified.timeIntervalSince1970 * 1000))}
        """
}

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
    let entries = index.all.map { widget -> String in
        "\(jsonString(widget.id)):\(widgetPayload(widget))"
    }
    return "{\"widgets\":{\(entries.joined(separator: ","))},\"settings\":{},\"screens\":[]}"
}

let server = try HTTPServer(port: options.port) { request in
    let path = request.path.components(separatedBy: "?")[0]

    // Any local process can reach the loopback port, and /run/ executes shell
    // commands. An Origin header is trivially forged, so when the app supplies
    // a per-launch token the page must present it too.
    if request.method != "GET" {
        guard request.headers["origin"] == allowedOrigin else {
            return HTTPResponse.text("", status: 403)
        }
        if let token = options.token, request.headers["x-ubersicht-token"] != token {
            return HTTPResponse.text("", status: 403)
        }
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
        guard let widget = index.widget(id: id) else {
            return HTTPResponse.text("", status: 404)
        }
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

// The app watches stdout for EADDRINUSE and retries on the next port.
server.onFailure = { error in
    let message = "\(error)".contains("Address already in use")
        ? "EADDRINUSE: port \(options.port) is already serving"
        : "listener failed: \(error)"
    print(message)
    exit(1)
}
// The app watches this line to know the port is live, so it is printed once
// the listener is actually bound rather than once start() has been called.
server.onReady = {
    let widgets = index.all
    print("server started on port \(options.port)")
    print("watching \(options.widgetDirectory)")
    print("\(widgets.count) widget(s): \(widgets.map(\.id).joined(separator: ", "))")
}
server.onUpgrade = { connection, _ in hub.add(connection) }
server.onUpgraded = { connection in hub.ready(connection) }
server.start()

// Widget edits reach the pages over the live channel; without it a save would
// only show up on a reload.
var known = Set(index.all.map(\.id))
let watcher = DirectoryWatcher(path: options.widgetDirectory) { changes in
    if changes.contains(.masterStyle) {
        hub.broadcast("{\"type\":\"MASTER_STYLE_CHANGED\"}")
    }
    guard changes.contains(.widgets) else { return }

    let current = index.refresh()
    let currentIds = Set(current.map(\.id))

    for gone in known.subtracting(currentIds) {
        hub.broadcast("{\"type\":\"WIDGET_REMOVED\",\"payload\":\"\(gone)\"}")
    }
    // Every present widget is re-announced: an edit to one that already exists
    // is a change the pages have to pick up, not just an addition.
    for widget in current {
        hub.broadcast("{\"type\":\"WIDGET_ADDED\",\"payload\":\(widgetPayload(widget))}")
    }
    known = currentIds
    Task { await loop.refresh(now: Date().timeIntervalSince1970) }
}
watcher.start()
// The command loop lives here rather than in each page, so a widget's command
// runs once however many screens show it, and an unchanged result never wakes
// a page to re-render the same thing.
let loop = CommandLoop(shells: shells, widgetDirectory: options.widgetDirectory)

func message(_ id: String, _ result: TickResult) -> String {
    let payload = result.stderr.isEmpty
        ? "{\"id\":\"\(id)\",\"output\":\(jsonString(result.stdout))}"
        : "{\"id\":\"\(id)\",\"error\":\(jsonString(result.stderr))}"
    return "{\"type\":\"WIDGET_COMMAND_RAN\",\"payload\":\(payload)}"
}

func broadcastResult(_ id: String, _ result: TickResult) {
    hub.broadcast(message(id, result))
}

let ticker = DispatchSource.makeTimerSource(
    queue: DispatchQueue(label: "ub.loop", qos: .utility)
)
ticker.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(50))
ticker.setEventHandler {
    Task {
        for (id, result) in await loop.tick(now: Date().timeIntervalSince1970) {
            broadcastResult(id, result)
        }
    }
}
ticker.resume()

hub.onConnect = { connection in
    Task {
        for (id, result) in await loop.currentResults() {
            hub.send(message(id, result), to: connection)
        }
    }
}

Task {
    await loop.refresh(now: Date().timeIntervalSince1970)
    let driven = await loop.drivenWidgets
    print("driving \(driven.count) widget(s): \(driven.joined(separator: ", "))")
}


signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }

// The app is the only reason this process exists. If it goes away without
// terminating us -- a crash, a kill -9 -- the daemon would otherwise keep the
// port bound and keep running widget commands forever.
// Held at top level: a timer source that goes out of scope is cancelled.
let parentWatch = DispatchSource.makeTimerSource(
    queue: DispatchQueue(label: "ub.parent", qos: .background)
)
if getppid() != 1 {
    parentWatch.schedule(deadline: .now() + 2, repeating: 2, leeway: .seconds(1))
    parentWatch.setEventHandler { if getppid() == 1 { exit(0) } }
    parentWatch.resume()
}
dispatchMain()
