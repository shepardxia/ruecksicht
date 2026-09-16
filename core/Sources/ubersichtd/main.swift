import Foundation
import UebersichtCore

// Serves the widget pages, their bundles and their shell commands. Bundling
// shells out to the esbuild binary and commands run in persistent shells.

struct Options {
    var port: UInt16 = 41416
    var widgetDirectory = "\(NSHomeDirectory())/Library/Application Support/Rücksicht/widgets"
    var registry = "\(NSHomeDirectory())/Library/Application Support/Rücksicht/sources"
    var publicDirectory = "server/public"
    var loginShell = false
    var token: String?
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = CommandLine.arguments.dropFirst()
    while let flag = arguments.popFirst() {
        switch flag {
        case "--login-shell": options.loginShell = true
        case "-p", "--port": options.port = arguments.popFirst().flatMap { UInt16($0) } ?? options.port
        case "-d", "--dir": options.widgetDirectory = arguments.popFirst() ?? options.widgetDirectory
        case "--public": options.publicDirectory = arguments.popFirst() ?? options.publicDirectory
        case "--sources": options.registry = arguments.popFirst() ?? options.registry
        case "--token": options.token = arguments.popFirst()
        default: break
        }
    }
    return options
}

// The app reads this process's stdout through a pipe and watches for the
// startup line; buffered output would strand it waiting.
setvbuf(stdout, nil, _IONBF, 0)

let options = parseOptions()
let shells = ShellPool(loginShell: options.loginShell)
let bundler: Bundler
do {
    bundler = try Bundler(cacheDirectory: NSTemporaryDirectory() + "ubersichtd")
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
let hub = WebSocketHub()
let index = WidgetIndex(registry: options.registry, defaultDirectory: options.widgetDirectory)
let loop = CommandLoop(shells: shells)

func json(_ object: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

// No "error" key when there is no error: the app reads it as `if (error)`, and
// a JSON null deserializes to NSNull, which is not nil.
func payload(_ widget: Widget) -> [String: Any] {
    ["id": widget.id, "filePath": widget.path, "serverDriven": widget.schedule != nil,
     "mtime": Int(widget.modified.timeIntervalSince1970 * 1000)]
}

func message(_ id: String, _ result: TickResult) -> String {
    let body: [String: Any] = result.stderr.isEmpty
        ? ["id": id, "output": result.stdout]
        : ["id": id, "error": result.stderr]
    return json(["type": "WIDGET_COMMAND_RAN", "payload": body])
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
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
          let data = FileManager.default.contents(atPath: path)
    else { return nil }
    return HTTPResponse(status: 200, contentType: contentType(for: path), body: data)
}

var server: HTTPServer!
server = HTTPServer(port: options.port) { request in
    let path = request.path.components(separatedBy: "?")[0]

    // Any local process can reach the loopback port, and /run/ executes shell
    // commands. An Origin header is trivially forged, so when the app supplies
    // a per-launch token the page must present it too.
    if request.method != "GET" {
        guard request.headers["origin"] == "http://127.0.0.1:\(server.port)" else {
            return HTTPResponse.text("", status: 403)
        }
        if let token = options.token, request.headers["x-ubersicht-token"] != token {
            return HTTPResponse.text("", status: 403)
        }
    }

    if request.method == "POST", path == "/run/" {
        do {
            let result = try shells.run(String(decoding: request.body, as: UTF8.self), in: options.widgetDirectory)
            return HTTPResponse(status: result.stderr.isEmpty ? 200 : 500, body: Data((result.stdout + result.stderr).utf8))
        } catch {
            return HTTPResponse.text("\(error)", status: 500)
        }
    }

    if path == "/state/" {
        let widgets = Dictionary(uniqueKeysWithValues: index.all.map { ($0.id, payload($0)) })
        return HTTPResponse.json(json(["widgets": widgets, "settings": [:], "screens": []]))
    }

    if path.hasPrefix("/widgets/") {
        guard let widget = index.widget(id: String(path.dropFirst("/widgets/".count))) else {
            return HTTPResponse.text("", status: 404)
        }
        do {
            return HTTPResponse(status: 200, contentType: "application/javascript; charset=utf-8",
                                body: Data(try bundler.bundle(widget).utf8))
        } catch {
            return HTTPResponse.text("\(error)", status: 500)
        }
    }

    // A widget's files are served under its name, wherever it lives.
    let relative = String(path.drop { $0 == "/" })
    if !relative.isEmpty, !relative.contains("..") {
        let parts = relative.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2, let directory = index.directory(named: parts[0]),
           let file = serveFile((directory as NSString).appendingPathComponent(parts[1])) {
            return file
        }
        for root in [options.publicDirectory, options.widgetDirectory] {
            if let file = serveFile((root as NSString).appendingPathComponent(relative)) { return file }
        }
    }

    // Every screen and layer path renders the same page.
    return serveFile((options.publicDirectory as NSString).appendingPathComponent("index.html"))
        ?? HTTPResponse.text("not found", status: 404)
}

server.onFailure = { error in
    print("listener failed: \(error)")
    exit(1)
}
// The app watches this line for the port, so it is printed once the listener
// is actually bound rather than once start() has been called.
server.onReady = {
    let widgets = index.all
    print("server started on port \(server.port)")
    print("watching \(index.sources.joined(separator: ", "))")
    print("\(widgets.count) widget(s): \(widgets.map(\.id).joined(separator: ", "))")
}
server.onUpgrade = { connection in hub.add(connection) }
// A page that has just connected gets every result already known; without
// this, one opened between two ticks shows placeholders until the next.
server.onUpgraded = { connection in
    Task {
        for (id, result) in await loop.currentResults {
            hub.send(message(id, result), to: connection)
        }
    }
}
server.start()

// Widgets run on one timer armed for the next deadline; a tick re-arms it.
let ticker = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "ub.loop", qos: .utility))
ticker.setEventHandler {
    Task {
        for (id, result) in await loop.tick(now: Date().timeIntervalSince1970) {
            hub.broadcast(message(id, result))
        }
        await arm()
    }
}
ticker.resume()

func arm() async {
    guard let deadline = await loop.nextDeadline else { return }
    ticker.schedule(deadline: .now() + max(0, deadline - Date().timeIntervalSince1970), leeway: .milliseconds(50))
}

// Widget edits reach the pages over the live channel; without it a save would
// only show up on a reload. One watcher per source, and one on the registry's
// directory so adding a source takes effect without a restart.
var known = Set(index.all.map(\.id))
var watchers: [String: DirectoryWatcher] = [:]

func announce() {
    let current = index.refresh()
    let currentIds = Set(current.map(\.id))
    for gone in known.subtracting(currentIds) {
        hub.broadcast(json(["type": "WIDGET_REMOVED", "payload": gone]))
    }
    // Every present widget is re-announced: an edit to one that already exists
    // is a change the pages have to pick up, not just an addition.
    for widget in current {
        hub.broadcast(json(["type": "WIDGET_ADDED", "payload": payload(widget)]))
    }
    known = currentIds
    Task {
        await loop.refresh(widgets: current, now: Date().timeIntervalSince1970)
        await arm()
    }
}

func handle(_ changes: Set<DirectoryWatcher.Change>) {
    if changes.contains(.masterStyle) {
        hub.broadcast(json(["type": "MASTER_STYLE_CHANGED"]))
    }
    if changes.contains(.sources) { watchSources() }
    if changes.contains(.widgets) || changes.contains(.sources) { announce() }
}

func watchSources() {
    let wanted = Set(Sources.read(registry: options.registry, defaultDirectory: options.widgetDirectory))
    for gone in Set(watchers.keys).subtracting(wanted) { watchers.removeValue(forKey: gone)?.stop() }
    for source in wanted where watchers[source] == nil {
        let watcher = DirectoryWatcher(path: source, onChange: handle)
        watcher.start()
        watchers[source] = watcher
    }
}

let registryWatcher = DirectoryWatcher(
    path: (options.registry as NSString).deletingLastPathComponent,
    registry: options.registry,
    onChange: handle
)
registryWatcher.start()
watchSources()

Task {
    await loop.refresh(widgets: index.all, now: Date().timeIntervalSince1970)
    await arm()
    let driven = await loop.drivenWidgets
    print("driving \(driven.count) widget(s): \(driven.joined(separator: ", "))")
}

signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }

// The app is the only reason this process exists. If it goes away without
// terminating us -- a crash, a kill -9 -- the daemon would otherwise keep the
// port bound and keep running widget commands forever.
let parentWatch = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit)
if getppid() != 1 {
    parentWatch.setEventHandler { exit(0) }
    parentWatch.resume()
}
dispatchMain()
