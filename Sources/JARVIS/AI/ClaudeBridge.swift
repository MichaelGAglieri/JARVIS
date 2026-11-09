import Foundation

enum ClaudeEvent {
    case text(String)
    case tool(String)
    /// An observable activity for the HUD: a tool call, its result, or a run status.
    case trace(String)
}

extension ClaudeBridge {
    /// One line describing a tool call: the search query, the file read, the arguments.
    static func describeToolUse(_ name: String, _ input: [String: Any]) -> String {
        let short = name.replacingOccurrences(of: "mcp__jarvis__", with: "")
        switch short {
        case "WebSearch", "web_search": return "⌕ web: \"\(input["query"] as? String ?? "")\""
        case "Read": return "▤ legge \(input["file_path"] as? String ?? "")"
        case "Glob": return "▤ cerca file \(input["pattern"] as? String ?? "") in \(input["path"] as? String ?? "~/Projects")"
        case "Grep": return "▤ cerca \"\(input["pattern"] as? String ?? "")\" in \(input["path"] as? String ?? "~/Projects")"
        default:
            let hiddenKeys: Set<String> = ["password", "token", "api_key", "apikey", "authorization", "secret", "body", "content"]
            let args = input.keys.sorted().map { key in
                let value = hiddenKeys.contains(key.lowercased()) ? "…" : String(describing: input[key] ?? "").prefix(100)
                return "\(key)=\(value)"
            }.joined(separator: " ")
            return "$ \(short) \(args)"
        }
    }

    /// A result summary with domains only when the tool actually searched the web.
    static func describeToolResult(_ content: Any?, tool name: String?, isError: Bool) -> String {
        let tool = name?.replacingOccurrences(of: "mcp__jarvis__", with: "")
        let blocks = content as? [[String: Any]] ?? []
        let text = content as? String ?? blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let error = (content as? [String: Any])?["error_code"] as? String {
            return "✕ " + error
        }
        if isError { return "✕ " + (flat.isEmpty ? "strumento non riuscito" : String(flat.prefix(160))) }
        if tool == "Read" || tool == "read_webpage" { return "← contenuto acquisito" }
        if tool == "WebSearch" || tool == "web_search" {
            let urls = blocks.compactMap { $0["url"] as? String }
            let matches = sourceURL.matches(in: text, range: NSRange(text.startIndex..., in: text))
            let links = urls + matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } }
            var seen: Set<String> = []
            let hosts = links.compactMap { URL(string: $0)?.host?.lowercased() }.compactMap { host -> String? in
                let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                return seen.insert(domain).inserted ? domain : nil
            }
            if !hosts.isEmpty {
                let more = hosts.count > 5 ? " (+\(hosts.count - 5))" : ""
                return "← \(hosts.count) domini: " + hosts.prefix(5).joined(separator: ", ") + more
            }
        }
        if blocks.contains(where: { $0["type"] as? String == "image" }) && flat.isEmpty {
            return "← immagine acquisita"
        }
        return "← " + (flat.isEmpty ? "nessun risultato testuale" : String(flat.prefix(160)))
    }

    private static let sourceURL = try! NSRegularExpression(pattern: #"https?://[^\s<>"\[\](){}]+"#)
}

/// Keeps complete tool calls and results associated by ID. Partial text and
/// tool-start events continue to drive the existing speech and HUD state.
struct ClaudeActivity {
    private var tools: [String: String] = [:]
    private var results: Set<String> = []

    mutating func lines(from json: [String: Any]) -> [String] {
        switch json["type"] as? String {
        case "assistant", "user":
            let content = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.compactMap { block in
                switch block["type"] as? String {
                case "tool_use", "server_tool_use":
                    guard let name = block["name"] as? String else { return nil }
                    if let id = block["id"] as? String {
                        guard tools.updateValue(name, forKey: id) == nil else { return nil }
                    }
                    return ClaudeBridge.describeToolUse(name, block["input"] as? [String: Any] ?? [:])
                case "tool_result", "web_search_tool_result":
                    let id = block["tool_use_id"] as? String
                    if let id, !results.insert(id).inserted { return nil }
                    let tool = block["type"] as? String == "web_search_tool_result" ? "web_search" : id.flatMap { tools[$0] }
                    return ClaudeBridge.describeToolResult(block["content"], tool: tool,
                                                          isError: block["is_error"] as? Bool == true)
                default:
                    return nil
                }
            }
        case "rate_limit_event":
            let info = json["rate_limit_info"] as? [String: Any]
            return info?["status"] as? String == "rejected" ? ["✕ limite di utilizzo di Claude raggiunto"] : []
        case "result":
            guard json["is_error"] as? Bool != true, let ms = json["duration_ms"] as? Double else { return [] }
            return [String(format: "✓ Claude · %d turni · %.1f s", json["num_turns"] as? Int ?? 0, ms / 1000)]
        default:
            return []
        }
    }
}

/// Uses Claude through Claude Code (`claude -p`), which signs in with the user's
/// subscription: no paid API. It keeps the session from one question
/// to the next, so Claude remembers the conversation.
final class ClaudeBridge {
    private(set) var sessionID: String?
    private var lastUse = Date.distantPast
    var model = "sonnet"
    /// Reasoning effort (low, medium, high…); nil = the default one.
    var effort: String?

    static func findBinary() -> String? {
        let home = NSHomeDirectory()
        return ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.local/bin/claude", "\(home)/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var isAvailable: Bool { Self.findBinary() != nil }

    func resetSession() { sessionID = nil }

    /// True if the next question will open a new session (after a 30-minute pause).
    var startsNewSession: Bool { sessionID == nil || Date().timeIntervalSince(lastUse) > 1800 }

    func ask(_ prompt: String, systemPrompt: String, mcpConfig: String) -> AsyncThrowingStream<ClaudeEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let binary = Self.findBinary() else {
                continuation.finish(throwing: ClaudeError.notInstalled)
                return
            }
            if startsNewSession { sessionID = nil }
            var arguments = [
                "-p", prompt,
                "--model", model,
                "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                "--append-system-prompt", systemPrompt,
                "--mcp-config", mcpConfig, "--strict-mcp-config",
                // Claude Code tools: web search and file reading, no terminal,
                // no edits and no free reading of web pages (WebFetch could send data out
                // to an address suggested by malicious content).
                "--tools", "WebSearch,Read,Glob,Grep",
                "--allowedTools", "mcp__jarvis", "WebSearch", "Read", "Glob", "Grep",
                "--setting-sources", "",
            ]
            if let effort { arguments += ["--effort", effort] }
            if let sessionID { arguments += ["--resume", sessionID] }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Projects")
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = env
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            // Without an explicit stdin Claude Code waits 3 seconds for input that will never come.
            process.standardInput = FileHandle.nullDevice

            var buffer = Data()
            var finished = false
            var activity = ClaudeActivity()
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                if chunk.isEmpty { return }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    for activityLine in activity.lines(from: json) { continuation.yield(.trace(activityLine)) }
                    switch json["type"] as? String {
                    case "stream_event":
                        let event = json["event"] as? [String: Any]
                        if event?["type"] as? String == "content_block_delta",
                           let delta = event?["delta"] as? [String: Any], let text = delta["text"] as? String {
                            continuation.yield(.text(text))
                        } else if event?["type"] as? String == "content_block_start",
                                  let block = event?["content_block"] as? [String: Any],
                                  block["type"] as? String == "tool_use", let name = block["name"] as? String {
                            continuation.yield(.tool(name))
                        }
                    case "result":
                        finished = true
                        self?.sessionID = json["session_id"] as? String
                        self?.lastUse = Date()
                        if json["is_error"] as? Bool == true {
                            let message = json["result"] as? String ?? "errore sconosciuto"
                            continuation.finish(throwing: message.lowercased().contains("auth")
                                                ? ClaudeError.notLoggedIn : ClaudeError.failed(message))
                        } else {
                            continuation.finish()
                        }
                    default:
                        break
                    }
                }
            }
            process.terminationHandler = { _ in
                // The last line of output may arrive shortly after the process closes.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    if !finished { continuation.finish(throwing: ClaudeError.failed("Claude Code si è chiuso senza risposta")) }
                }
            }
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

enum ClaudeError: LocalizedError {
    case notInstalled
    case notLoggedIn
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Claude Code non è installato"
        case .notLoggedIn: return "Claude Code non ha effettuato l'accesso (claude auth login)"
        case .failed(let m): return "Claude: \(m)"
        }
    }
}
