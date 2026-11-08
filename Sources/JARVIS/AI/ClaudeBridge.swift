import Foundation

enum ClaudeEvent {
    case text(String)
    case tool(String)
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
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                if chunk.isEmpty { return }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
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
