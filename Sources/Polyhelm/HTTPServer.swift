import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let body: Data

    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }
}

struct HTTPResponse {
    var status: Int = 200
    var json: [String: Any] = [:]

    static let ok = HTTPResponse()
    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status, json: ["error": message])
    }
}

/// Minimal loopback-only HTTP/1.1 server.
///
/// Deliberately tiny: it only ever talks to hook subprocesses on this machine.
/// Responses may be deferred indefinitely — that is what lets a PreToolUse hook
/// block in the terminal while the user decides in the notch.
final class HTTPServer {
    typealias Handler = (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "polyhelm.http", qos: .userInitiated)
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start(port: UInt16) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback),
                                                          port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        read(conn, buffer: Data())
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] chunk, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            if let error {
                NSLog("Polyhelm: connection error \(error)")
                conn.cancel()
                return
            }

            switch self.parse(buffer) {
            case .incomplete:
                if done { conn.cancel() } else { self.read(conn, buffer: buffer) }
            case .malformed:
                self.write(conn, .error(400, "malformed request"))
            case .complete(let request):
                self.handler(request) { response in
                    self.write(conn, response)
                }
            }
        }
    }

    private enum ParseResult {
        case incomplete
        case malformed
        case complete(HTTPRequest)
    }

    private func parse(_ buffer: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else { return .incomplete }

        guard let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
            return .malformed
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.components(separatedBy: " ") ?? []
        guard requestLine.count >= 2 else { return .malformed }

        var contentLength = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        let body = buffer[headerEnd.upperBound...]
        guard body.count >= contentLength else { return .incomplete }

        // Split "/path?a=1&b=2" without pulling in URLComponents' absolute-URL requirements.
        let target = requestLine[1]
        let pieces = target.split(separator: "?", maxSplits: 1)
        let path = String(pieces.first ?? "/")
        var query: [String: String] = [:]
        if pieces.count > 1 {
            for pair in pieces[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard let key = kv.first?.removingPercentEncoding else { continue }
                query[key] = kv.count > 1 ? (kv[1].removingPercentEncoding ?? "") : ""
            }
        }

        return .complete(HTTPRequest(method: requestLine[0],
                                     path: path,
                                     query: query,
                                     body: Data(body.prefix(contentLength))))
    }

    private func write(_ conn: NWConnection, _ response: HTTPResponse) {
        let payload = (try? JSONSerialization.data(withJSONObject: response.json)) ?? Data("{}".utf8)
        let reason = response.status == 200 ? "OK" : "Error"
        var out = Data("""
        HTTP/1.1 \(response.status) \(reason)\r
        Content-Type: application/json\r
        Content-Length: \(payload.count)\r
        Connection: close\r
        \r

        """.utf8)
        out.append(payload)

        conn.send(content: out, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}
