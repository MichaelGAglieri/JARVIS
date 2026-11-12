import AppKit
import Darwin
import Foundation

/// Private operator channel, separate from the public program-planning API.
/// Unix permissions + same-UID peer, session/epoch and one-shot request IDs.
/// No retries of mutations, no clipboard token, no second serial controller.
@MainActor
final class RobotOperatorChannel {
    private static let application = URL(fileURLWithPath: "/Applications/Robot Console.app")
    static let socketPath = NSHomeDirectory() + "/Library/Application Support/DOC Regia/jarvis/control.sock"
    private var session: String?
    private(set) var inFlight = false
    var available: Bool { FileManager.default.fileExists(atPath: Self.socketPath) }

    private var running: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == Self.application.standardizedFileURL }
    }

    private func ready(open: Bool) async throws -> [String: Any] {
        if running == nil {
            guard open else { throw ChannelError("Robot Console non è aperta.") }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: Self.application, configuration: config)
        }
        let end = Date().addingTimeInterval(open ? 10 : 1)
        repeat {
            try Task.checkCancellation()
            if available {
                let reply = try await exchange(["op": "status"])
                guard reply["version"] as? Int == 1, let id = reply["session"] as? String else {
                    throw ChannelError("Versione del canale Robot Console non compatibile.")
                }
                session = id
                return reply
            }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < end
        throw ChannelError("Canale diretto non disponibile: avvia la versione aggiornata di Robot Console.")
    }

    func run(_ operation: String, arguments: [String: Any] = [:]) async -> String {
        if operation == "quit", running == nil { return "Robot Console è già chiusa, signore." }
        guard !inFlight else { return "Un comando robot è già in corso. Attendi oppure chiedi STOP." }
        inFlight = true
        defer { inFlight = false }
        return await withTaskCancellationHandler {
            do {
                let state = try await ready(open: operation == "enable")
                try Task.checkCancellation()
                var request = arguments
                request["op"] = operation
                request["session"] = state["session"]
                request["epoch"] = state["epoch"]
                request["id"] = UUID().uuidString
                // Enabling may reopen the USB once if the Mega stays silent: up to about 16 seconds.
                request["expires"] = Date().timeIntervalSince1970 + 28
                if operation == "enable" { request["home_confirmed"] = true }
                let reply = try await exchange(request)
                try Task.checkCancellation()
                guard reply["ok"] as? Bool == true else {
                    return "Robot: " + (reply["error"] as? String ?? "comando rifiutato.")
                }
                if operation == "quit" {
                    let deadline = Date().addingTimeInterval(6)
                    while running != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
                    guard running == nil else { return "STOP richiesto, ma la chiusura di Robot Console non è ancora confermata." }
                    session = nil
                    return "Robot Console chiusa con STOP, signore."
                }
                return reply["message"] as? String ?? "Comando accettato da Robot Console."
            } catch is CancellationError {
                return "Comando robot interrotto."
            } catch {
                // An interrupted transport may already have delivered the command.
                // Cancel pending work; never silently retry or fall back to GUI clicks.
                if session != nil { _ = await stop() }
                return "Robot: \(error.localizedDescription) Nessun tentativo automatico ripetuto."
            }
        } onCancel: {
            Task { @MainActor [weak self] in _ = await self?.stop() }
        }
    }

    func status() async -> String {
        do {
            let reply = try await ready(open: false)
            let summary: [String: Any] = ["stato": reply["state"] ?? [:], "pose_abilitate": reply["enabled_poses"] ?? []]
            let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
            return "Stato Robot Console (angoli calcolati dal controller): " + String(decoding: data, as: UTF8.self)
        } catch { return "Stato robot non disponibile: \(error.localizedDescription)" }
    }

    /// True while the controller moves (sequence, HOME, joint); nil when the channel does not answer.
    func isMoving() async -> Bool? {
        guard available, let reply = try? await exchange(["op": "status"]),
              let state = reply["state"] as? [String: Any] else { return nil }
        return state["busy"] as? Bool == true || state["playing"] as? Bool == true
    }

    func stop() async -> String {
        guard available else { return "Canale diretto Robot Console non disponibile." }
        do {
            let state = try await exchange(["op": "status"])
            let reply = try await exchange(["op": "stop", "session": state["session"] ?? "",
                                            "id": UUID().uuidString, "expires": Date().timeIntervalSince1970 + 5])
            return reply["message"] as? String ?? "STOP non confermato: \(reply["error"] ?? "errore del canale")."
        } catch { return "STOP non confermato: \(error.localizedDescription)" }
    }

    private func exchange(_ request: [String: Any]) async throws -> [String: Any] {
        let payload = try JSONSerialization.data(withJSONObject: request) + Data([10])
        let path = Self.socketPath
        let data = try await Task.detached(priority: .userInitiated) {
            try Self.exchange(path: path, payload: payload)
        }.value
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChannelError("Risposta del canale non valida.")
        }
        return reply
    }

    struct ChannelError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// Kept independent of AppKit for isolated socket tests.
    nonisolated static func exchange(path: String, payload: Data) throws -> Data {
        var info = stat()
        let directory = (path as NSString).deletingLastPathComponent
        guard lstat(directory, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & 0o077) == 0,
              lstat(path, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & S_IFMT) == S_IFSOCK, (info.st_mode & 0o077) == 0 else {
            throw ChannelError("Socket locale assente o permessi non validi.")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ChannelError("Impossibile aprire il canale locale.") }
        defer { Darwin.close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var timeout = timeval(tv_sec: 26, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ChannelError("Percorso socket troppo lungo.") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            bytes.withUnsafeBytes { buffer.copyBytes(from: $0) }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw ChannelError("Robot Console non risponde sul canale locale.") }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw ChannelError("Identità del processo locale non valida.") }
        try payload.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ChannelError("Invio al robot non confermato.") }
                offset += count
            }
        }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while result.count < 65536 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ChannelError("Risposta del robot interrotta o scaduta.") }
            result.append(contentsOf: buffer.prefix(count))
            if let newline = result.firstIndex(of: 10) { return Data(result[..<newline]) }
        }
        throw ChannelError("Risposta del canale troppo grande.")
    }
}
