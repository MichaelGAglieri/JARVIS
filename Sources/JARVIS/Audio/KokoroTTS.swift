import AVFoundation

/// Kokoro neural voice: a small local Python service (Resources/tts_server.py)
/// that turns text into audio. The app starts it and it quits with the app.
/// It is installed with scripts/setup_tts.sh.
final class KokoroTTS {
    static let directory = JarvisConfig.directory.appendingPathComponent("tts", isDirectory: true)
    static let sampleRate: Double = 24_000

    private var process: Process?
    private(set) var port: Int?
    private let token = UUID().uuidString
    var isReady: Bool { port != nil }

    static var isInstalled: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: directory.appendingPathComponent(".venv/bin/python").path)
            && fm.fileExists(atPath: directory.appendingPathComponent("kokoro-v1.0.onnx").path)
            && fm.fileExists(atPath: directory.appendingPathComponent("voices-v1.0.bin").path)
    }

    /// The Qwen3 Italian voice is optional: without it, Italian goes to Supertonic.
    static var hasQwen: Bool {
        ["qwen3-0.6b", "qwen3"].contains {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("\($0)/config.json").path)
        }
    }

    /// The Supertonic Italian voice is optional: without it, Italian stays with Kokoro.
    static var hasSupertonic: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("supertonic/onnx/vocoder.onnx").path)
    }

    /// Starts the service and waits for it to say which port it listens on.
    func start() async -> Bool {
        guard Self.isInstalled, let script = Bundle.main.url(forResource: "tts_server", withExtension: "py") else { return false }
        let process = Process()
        process.executableURL = Self.directory.appendingPathComponent(".venv/bin/python")
        process.arguments = ["-I", script.path]
        process.currentDirectoryURL = Self.directory
        var env = ProcessInfo.processInfo.environment
        env["JARVIS_TTS_TOKEN"] = token
        process.environment = env
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        self.process = process

        let port: Int? = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                // The first line is "PORT 12345"; if the process dies, EOF arrives.
                var line = Data()
                while true {
                    let byte = stdout.fileHandleForReading.readData(ofLength: 1)
                    if byte.isEmpty || byte == Data([0x0A]) { break }
                    line.append(byte)
                }
                let text = String(decoding: line, as: UTF8.self)
                continuation.resume(returning: text.hasPrefix("PORT ") ? Int(text.dropFirst(5)) : nil)
            }
        }
        self.port = port
        return port != nil
    }

    func stop() {
        process?.terminate()
        process = nil
        port = nil
    }

    /// The voiceprint of a piece of 16 kHz audio (the audio is not saved).
    func embedding(_ samples: [Float]) async throws -> [Float] {
        // With the neural voice off the service may not have started yet.
        if port == nil { _ = await start() }
        guard let port, let url = URL(string: "http://127.0.0.1:\(port)/embed") else { throw KokoroError.notRunning }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            throw KokoroError.failed(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Synthesises a sentence and returns the audio ready to play.
    func synthesize(_ text: String, voice: String, lang: String, speed: Double, fallback: String? = nil, keep: Bool = false, onlySaved: Bool = false) async throws -> AVAudioPCMBuffer {
        guard let port, let url = URL(string: "http://127.0.0.1:\(port)/synth") else { throw KokoroError.notRunning }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // At start-up Qwen3 is still loading: the first sentence may wait for it.
        request.timeoutInterval = 90
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["text": text, "voice": voice, "lang": lang, "speed": speed]
        if let fallback { body["fallback"] = fallback }
        if keep { body["keep"] = true }
        if onlySaved { body["onlySaved"] = true }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            throw KokoroError.failed(String(decoding: data.prefix(200), as: UTF8.self))
        }
        let frames = data.count / MemoryLayout<Float>.size
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw KokoroError.failed("buffer")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            buffer.floatChannelData![0].update(from: raw.bindMemory(to: Float.self).baseAddress!, count: frames)
        }
        return buffer
    }
}

extension KokoroTTS {
    /// A Qwen3 sentence in pieces of about 0.3 s, handed over as soon as they arrive: the first
    /// words play while the rest is still being generated. Cancelling the task stops the generation too.
    func synthesizeStream(_ text: String, speed: Double) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let port, let url = URL(string: "http://127.0.0.1:\(port)/synth") else { throw KokoroError.notRunning }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 90
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "text": text, "voice": "qwen3", "lang": "it", "speed": speed, "stream": true])
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw KokoroError.failed("stream") }
                    let piece = Int(Self.sampleRate * 0.3) * MemoryLayout<Float>.size
                    var pending = Data()
                    pending.reserveCapacity(piece)
                    for try await byte in bytes {
                        pending.append(byte)
                        if pending.count >= piece {
                            continuation.yield(try Self.buffer(from: pending))
                            pending.removeAll(keepingCapacity: true)
                        }
                    }
                    let whole = pending.count - pending.count % MemoryLayout<Float>.size
                    if whole > 0 { continuation.yield(try Self.buffer(from: pending.prefix(whole))) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func buffer(from data: Data) throws -> AVAudioPCMBuffer {
        let frames = data.count / MemoryLayout<Float>.size
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1))) else {
            throw KokoroError.failed("buffer")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            buffer.floatChannelData![0].update(from: raw.bindMemory(to: Float.self).baseAddress!, count: frames)
        }
        return buffer
    }
}

enum KokoroError: Error {
    case notRunning
    case failed(String)
}
