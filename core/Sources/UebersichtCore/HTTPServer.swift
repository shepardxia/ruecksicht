import Foundation
import Network

public struct HTTPRequest {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
}

public struct HTTPResponse {
    public var status: Int
    public var contentType: String
    public var body: Data

    public init(status: Int = 200, contentType: String = "text/plain; charset=utf-8", body: Data = Data()) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    public static func text(_ string: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: Data(string.utf8))
    }

    public static func json(_ string: String) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "application/json; charset=utf-8", body: Data(string.utf8))
    }
}

/// Minimal HTTP/1.1 server on the loopback interface.
///
/// Requests are read until the headers are complete and then until Content-Length
/// is satisfied; a body split across TCP segments is common for widget commands
/// and dropping the remainder would truncate them silently.
public final class HTTPServer {
    public typealias Handler = (HTTPRequest) -> HTTPResponse

    private var listener: NWListener?
    private let handler: Handler
    /// The port actually bound, once `onReady` has fired.
    public private(set) var port: UInt16
    /// Called instead of `handler` when a request asks to switch protocols; the
    /// connection then belongs to the caller and is not closed here.
    public var onUpgrade: ((NWConnection) -> Void)?
    /// Called after the handshake response has been written.
    public var onUpgraded: ((NWConnection) -> Void)?
    // Concurrent: a widget command can block its handler for seconds, and on a
    // serial queue that would stall every other request and the listener.
    private let queue = DispatchQueue(label: "ub.http", qos: .userInitiated, attributes: .concurrent)

    public init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    /// Binding is asynchronous, so callers learn the outcome here rather than
    /// from `start()` returning.
    public var onReady: (() -> Void)?
    public var onFailure: ((Error) -> Void)?

    /// Binds the first free port at or after the one given, up to `attempts`
    /// away. The endpoint is deliberately not reused: a port another Rücksicht
    /// is serving must fail, or two servers would answer the same requests.
    public func start(attempts: Int = 20) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .init(rawValue: port)!)
        guard let listener = try? NWListener(using: parameters) else {
            onFailure?(NWError.posix(.EINVAL))
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.onReady?()
            case .failed(.posix(.EADDRINUSE)) where attempts > 1:
                listener.cancel()
                self.port += 1
                self.start(attempts: attempts - 1)
            case .failed(let error): self.onFailure?(error)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
        }
        listener.start(queue: queue)
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if error != nil || (isComplete && accumulated.isEmpty) {
                connection.cancel()
                return
            }

            guard let request = Self.parse(accumulated) else {
                // Headers or body still incomplete; wait for the rest.
                self.receive(on: connection, buffer: accumulated)
                return
            }

            if let key = request.headers["sec-websocket-key"],
               request.headers["upgrade"]?.lowercased() == "websocket",
               let upgrade = self.onUpgrade {
                // Hand the connection over before replying: arming the read
                // inside the send completion raced the client's first frame.
                upgrade(connection)
                connection.send(
                    content: WebSocketHub.acceptResponse(
                        forKey: key,
                        protocols: request.headers["sec-websocket-protocol"]
                    ),
                    completion: .contentProcessed { [weak self] _ in
                        self?.onUpgraded?(connection)
                    }
                )
                return
            }

            let response = self.handler(request)
            connection.send(content: Self.serialize(response), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[data.startIndex..<headerEnd.lowerBound]
        // Header bytes are Latin-1 by spec, and the app sends Origin: Übersicht.
        // Demanding UTF-8 here rejected that request and stalled the connection.
        guard let headerText = String(data: headerData, encoding: .utf8)
            ?? String(data: headerData, encoding: .isoLatin1)
        else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let expected = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[headerEnd.upperBound...]
        guard body.count >= expected else { return nil }

        return HTTPRequest(
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            headers: headers,
            body: Data(body.prefix(expected))
        )
    }

    private static func serialize(_ response: HTTPResponse) -> Data {
        let reason = response.status == 200 ? "OK"
            : response.status == 404 ? "Not Found"
            : response.status == 403 ? "Forbidden"
            : "Error"
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(response.body)
        return out
    }
}
