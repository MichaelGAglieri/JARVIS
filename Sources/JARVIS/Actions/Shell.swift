import Foundation

/// Runs programs and AppleScript in the background, without blocking the HUD.
enum Shell {
    struct Output {
        let status: Int32
        let out: String
        let err: String
        var ok: Bool { status == 0 }
    }

    static func run(_ executable: String, _ arguments: [String], timeout: Double = 30) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Output(status: -1, out: "", err: error.localizedDescription))
                    return
                }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                // Read before waitUntilExit: with long output the pipe would fill up.
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: Output(
                    status: process.terminationStatus,
                    out: String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                    err: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    static func osascript(_ script: String, timeout: Double = 30) async -> Output {
        await run("/usr/bin/osascript", ["-e", script], timeout: timeout)
    }

    /// Makes a string safe to put between quotes in an AppleScript.
    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Parses the dates the model passes to tools (ISO format, local time).
enum DateArg {
    static func parse(_ value: Any?) -> Date? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let formats = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        let trimmed = text.replacingOccurrences(of: #"(Z|[+-]\d\d:?\d\d)$"#, with: "", options: .regularExpression)
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    static func spoken(_ date: Date, allDay: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.dateFormat = allDay ? "EEEE d MMMM" : "EEEE d MMMM HH:mm"
        return formatter.string(from: date)
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        if let s = self[key] as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = self[key] as? NSNumber { return n.stringValue }
        return nil
    }

    func number(_ key: String) -> Double? {
        if let n = self[key] as? NSNumber { return n.doubleValue }
        if let s = self[key] as? String { return Double(s.replacingOccurrences(of: ",", with: ".")) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if let b = self[key] as? Bool { return b }
        if let s = self[key] as? String { return ["true", "yes", "1", "on"].contains(s.lowercased()) }
        return nil
    }
}
