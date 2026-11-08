import Foundation
import Network

/// Minimal MCP server on 127.0.0.1: exposes JARVIS's tools to Claude Code,
/// so in Claude mode Claude itself opens apps, reads the calendar, etc.
/// It accepts only requests carrying the token generated at every app launch.
final class MCPServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "jarvis.mcp")
    let token = UUID().uuidString
    private(set) var port: UInt16 = 0

    /// List of tools in MCP format (name, description, inputSchema).
    var tools: () -> [[String: Any]] = { [] }
    /// Runs a tool and returns the MCP contents of the result (text, images).
    var call: (String, [String: Any]) async -> [[String: Any]] = { _, _ in [] }

    var url: String { "http://127.0.0.1:\(port)/mcp" }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = listener.port?.rawValue ?? 0
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        self.listener = listener
    }

    /// Configuration to pass to `claude --mcp-config`.
    var claudeConfig: String {
        let config: [String: Any] = ["mcpServers": ["jarvis": [
            "type": "http", "url": url, "headers": ["Authorization": "Bearer \(token)"],
        ]]]
        let data = (try? JSONSerialization.data(withJSONObject: config)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest(buffer) {
                Task { await self.handle(request, on: connection) }
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) async {
        guard request.headers["authorization"] == "Bearer \(token)" else {
            return send(connection, status: "401 Unauthorized", body: nil)
        }
        // No requests from the browser (Origin) or with a different Host (DNS rebinding).
        let host = request.headers["host"] ?? ""
        guard request.headers["origin"] == nil, host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else {
            return send(connection, status: "403 Forbidden", body: nil)
        }
        guard request.method == "POST" else {
            return send(connection, status: "405 Method Not Allowed", body: nil)
        }
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let method = json["method"] as? String else {
            return send(connection, status: "400 Bad Request", body: nil)
        }
        // Notifications have no id and want no answer.
        guard let id = json["id"] else { return send(connection, status: "202 Accepted", body: nil) }
        let params = json["params"] as? [String: Any] ?? [:]

        var result: [String: Any] = [:]
        switch method {
        case "initialize":
            result = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                      "capabilities": ["tools": [:]],
                      "serverInfo": ["name": "jarvis", "version": "0.3.0"]]
        case "tools/list":
            result = ["tools": tools()]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            result = ["content": await call(name, arguments), "isError": false]
        case "ping":
            result = [:]
        default:
            let error: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]
            return send(connection, status: "200 OK", body: error)
        }
        send(connection, status: "200 OK", body: ["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(_ connection: NWConnection, status: String, body: [String: Any]?) {
        let data = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(data.count)\r\nConnection: close\r\n"
        if body != nil { head += "Content-Type: application/json\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Complete HTTP/1.1 request (headers + body according to Content-Length).
private struct HTTPRequest {
    let method: String
    let headers: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<separator.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard let method = requestLine.first else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[separator.upperBound...]
        guard body.count >= length else { return nil }
        self.method = String(method)
        self.headers = headers
        self.body = Data(body.prefix(length))
    }
}
