import Foundation
import Network
import CryptoKit

/// The widget pages' live channel: the server pushes widget changes, and any
/// message a page sends is relayed to the others.
///
/// Only text frames are handled, which is all the protocol carries. Frames from
/// a client are always masked; frames to a client never are.
public final class WebSocketHub {
    private static let handshakeGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ub.ws")

    public init() {}

    /// A client that asked for a subprotocol closes the connection unless the
    /// server names one back, so the first requested protocol is echoed.
    public static func acceptResponse(forKey key: String, protocols: String? = nil) -> Data {
        let digest = Insecure.SHA1.hash(data: Data((key + handshakeGUID).utf8))
        let accept = Data(digest).base64EncodedString()

        var head = "HTTP/1.1 101 Switching Protocols\r\n"
        head += "Upgrade: websocket\r\n"
        head += "Connection: Upgrade\r\n"
        head += "Sec-WebSocket-Accept: \(accept)\r\n"
        if let chosen = protocols?
            .split(separator: ",")
            .first?
            .trimmingCharacters(in: .whitespaces),
            !chosen.isEmpty
        {
            head += "Sec-WebSocket-Protocol: \(chosen)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8)
    }

    public func add(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        lock.lock()
        clients[id] = connection
        lock.unlock()
        receive(on: connection, buffer: Data())
    }

    public func send(_ text: String, to connection: NWConnection) {
        connection.send(content: Self.encode(text), completion: .contentProcessed { _ in })
    }

    public func broadcast(_ text: String) {
        let frame = Self.encode(text)
        lock.lock()
        let targets = Array(clients.values)
        lock.unlock()
        for connection in targets {
            connection.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    private func drop(_ connection: NWConnection) {
        lock.lock()
        clients.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
        connection.cancel()
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil || isComplete {
                self.drop(connection)
                return
            }

            var accumulated = buffer
            if let data { accumulated.append(data) }

            while let (opcode, payload, consumed) = Self.decode(accumulated) {
                accumulated.removeFirst(consumed)
                switch opcode {
                case 0x1:
                    // The page relays through the server to its siblings.
                    if let text = String(data: payload, encoding: .utf8) {
                        self.broadcast(text)
                    }
                case 0x8:
                    self.drop(connection)
                    return
                case 0x9:
                    connection.send(content: Self.encode(payload, opcode: 0xA), completion: .contentProcessed { _ in })
                default:
                    break
                }
            }

            self.receive(on: connection, buffer: accumulated)
        }
    }

    static func encode(_ text: String) -> Data {
        encode(Data(text.utf8), opcode: 0x1)
    }

    static func encode(_ payload: Data, opcode: UInt8) -> Data {
        var frame = Data([0x80 | opcode])
        let count = payload.count
        if count < 126 {
            frame.append(UInt8(count))
        } else if count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(count >> 8))
            frame.append(UInt8(count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((count >> shift) & 0xFF))
            }
        }
        frame.append(payload)
        return frame
    }

    /// Returns nil until a whole frame has arrived.
    static func decode(_ data: Data) -> (opcode: UInt8, payload: Data, consumed: Int)? {
        guard data.count >= 2 else { return nil }
        let bytes = [UInt8](data)

        let opcode = bytes[0] & 0x0F
        let masked = bytes[1] & 0x80 != 0
        var length = Int(bytes[1] & 0x7F)
        var offset = 2

        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            length = 0
            for i in 2..<10 { length = length << 8 | Int(bytes[i]) }
            offset = 10
        }

        var mask = [UInt8]()
        if masked {
            guard bytes.count >= offset + 4 else { return nil }
            mask = Array(bytes[offset..<(offset + 4)])
            offset += 4
        }

        guard bytes.count >= offset + length else { return nil }
        var payload = Array(bytes[offset..<(offset + length)])
        if masked {
            for i in 0..<payload.count { payload[i] ^= mask[i % 4] }
        }

        return (opcode, Data(payload), offset + length)
    }
}
