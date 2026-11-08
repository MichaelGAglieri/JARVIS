import Foundation

/// Local technical log (`diagnostica.log`): what the wake word check
/// heard and how long each phase of the answer takes. It helps to
/// understand why "Jarvis" is not recognised or why an answer is slow.
/// It stays on the Mac, is readable only by the user and keeps the last 400 lines.
enum Diagnostics {
    private static let queue = DispatchQueue(label: "jarvis.diagnostics", qos: .utility)
    private static let url = JarvisConfig.directory.appendingPathComponent("diagnostica.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Start of the current request (end of the user's phrase).
    @MainActor static var requestStart: Date?

    /// Only in silent tests: what JARVIS would say, so it can be checked.
    nonisolated(unsafe) static var logsSpeech = false

    static func log(_ line: String) {
        write(line, to: url, keep: 400, stamp: formatter.string(from: Date()))
    }

    /// Voiceprint scores: they are needed for days, so they live apart (`voce.log`).
    static func logVoice(_ line: String) {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd HH:mm:ss"
        write(line, to: JarvisConfig.directory.appendingPathComponent("voce.log"), keep: 3000, stamp: day.string(from: Date()))
    }

    private static func write(_ line: String, to url: URL, keep: Int, stamp: String) {
        queue.async {
            var lines = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
            lines.append("\(stamp)  \(line)")
            if lines.count > keep { lines.removeFirst(lines.count - keep) }
            try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            Security.protect(url)
        }
    }

    /// Seconds elapsed since `start`, with one decimal.
    static func since(_ start: Date) -> String {
        String(format: "%.2f s", Date().timeIntervalSince(start))
    }
}
