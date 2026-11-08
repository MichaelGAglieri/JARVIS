import Foundation

/// A message in Ollama's API format (role, content, tool_calls, tool_name).
typealias ChatMessage = [String: Any]

struct ToolCall {
    let name: String
    let arguments: [String: Any]
}

enum ChatEvent {
    case text(String)
    case toolCalls([ToolCall], raw: [[String: Any]])
}

/// Minimal client for Ollama's chat API, with streaming answers.
final class OllamaClient {
    var baseURL: URL
    var model: String

    init(baseURL: String, model: String) {
        self.baseURL = URL(string: baseURL) ?? URL(string: "http://localhost:11434")!
        self.model = model
    }

    func isReachable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        return (try? await URLSession.shared.data(for: request)).map { ($0.1 as? HTTPURLResponse)?.statusCode == 200 } ?? false
    }

    func hasModel() async -> Bool {
        guard let (data, _) = try? await URLSession.shared.data(from: baseURL.appendingPathComponent("api/tags")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return false }
        return models.contains { ($0["name"] as? String) == model || ($0["model"] as? String) == model }
    }

    static let contextLength = 12288
    /// After how much idle time Ollama frees the model's RAM.
    var keepAlive = "5m"

    /// Removes the model from RAM at once (keep_alive 0).
    func unload() async {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": 0] as [String: Any])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// True if the model is already loaded in memory.
    func isLoaded() async -> Bool {
        guard let (data, _) = try? await URLSession.shared.data(from: baseURL.appendingPathComponent("api/ps")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return false }
        return models.contains { ($0["name"] as? String) == model || ($0["model"] as? String) == model }
    }

    /// Loads the model and pre-processes instructions and tools: Ollama keeps
    /// this start of the conversation cached, so every following request
    /// has to process only the new words.
    func warmUp(system: String, tools: [[String: Any]]) async {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": "ok"]],
            "tools": tools,
            "stream": false,
            "think": false,
            "keep_alive": keepAlive,
            "options": ["num_ctx": Self.contextLength, "num_predict": 1],
        ] as [String: Any])
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let load = (json["load_duration"] as? Double ?? 0) / 1e9
        let prefill = (json["prompt_eval_duration"] as? Double ?? 0) / 1e9
        let tokens = json["prompt_eval_count"] as? Int ?? 0
        Diagnostics.log(String(format: "modello   caricamento %.1f s, istruzioni %d token in %.1f s", load, tokens, prefill))
    }

    /// Returns the text as the model generates it, or the
    /// requests to use a tool (open an app, read the mail…).
    func chat(_ messages: [ChatMessage], tools: [[String: Any]]) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
                    request.httpMethod = "POST"
                    request.timeoutInterval = 180
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    var body: [String: Any] = [
                        "model": model,
                        "messages": messages,
                        "stream": true,
                        "think": false,
                        "keep_alive": keepAlive,
                        "options": ["temperature": 0.5, "num_ctx": Self.contextLength],
                    ]
                    if !tools.isEmpty { body["tools"] = tools }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var detail = ""
                        for try await line in bytes.lines { detail += line }
                        throw JarvisError.ollama("HTTP \(http.statusCode) \(detail.prefix(200))")
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let error = json["error"] as? String { throw JarvisError.ollama(error) }
                        if let message = json["message"] as? [String: Any] {
                            if let calls = message["tool_calls"] as? [[String: Any]], !calls.isEmpty {
                                let parsed = calls.compactMap { call -> ToolCall? in
                                    guard let fn = call["function"] as? [String: Any], let name = fn["name"] as? String else { return nil }
                                    var args = fn["arguments"] as? [String: Any] ?? [:]
                                    if args.isEmpty, let text = fn["arguments"] as? String,
                                       let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                                        args = obj
                                    }
                                    return ToolCall(name: name, arguments: args)
                                }
                                continuation.yield(.toolCalls(parsed, raw: calls))
                            }
                            if let content = message["content"] as? String, !content.isEmpty {
                                continuation.yield(.text(content))
                            }
                        }
                        if json["done"] as? Bool == true { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Splits the streaming text into complete sentences, to send to the voice at once.
struct SentenceSplitter {
    private var buffer = ""
    private var insideThink = false

    mutating func push(_ chunk: String) -> [String] {
        buffer += chunk
        stripThinking()
        if insideThink { return [] }
        var sentences: [String] = []
        var searchStart = buffer.startIndex
        // Looks for the first sentence end closing at least 12 characters: sentences
        // that are too short ("Sì.", "Ok.") stay joined to the next.
        while let range = buffer.range(of: #"[.!?;:…]+["»”')]?\s|\n+"#, options: .regularExpression,
                                       range: searchStart..<buffer.endIndex) {
            let sentence = buffer[..<range.upperBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.count < 12 {
                searchStart = range.upperBound
                continue
            }
            sentences.append(sentence)
            buffer.removeSubrange(..<range.upperBound)
            searchStart = buffer.startIndex
        }
        return sentences
    }

    mutating func flush() -> String? {
        stripThinking()
        if insideThink, let start = buffer.range(of: "<think>") { buffer.removeSubrange(start.lowerBound...) }
        insideThink = false
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }

    /// Qwen3 may still emit a <think>…</think> block: it must not be read aloud.
    private mutating func stripThinking() {
        while let start = buffer.range(of: "<think>") {
            guard let end = buffer.range(of: "</think>", range: start.upperBound..<buffer.endIndex) else {
                insideThink = true
                return
            }
            buffer.removeSubrange(start.lowerBound..<end.upperBound)
        }
        insideThink = false
    }
}
