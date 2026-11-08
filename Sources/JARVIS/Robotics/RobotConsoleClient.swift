import AppKit
import Foundation

/// Client for Robot Console's local API (2.0.x).
///
/// The token is per session and stays only in memory: it is taken from the clipboard
/// after "Copia token di questa sessione" in the app; the port is found by itself.
/// On the real robot every execution waits for the operator's approval
/// in Robot Console: the API does not allow bypassing it.
@MainActor
final class RobotConsoleClient {
    private(set) var baseURL: URL?
    private var token = ""
    private var plan: [String: Any]?
    private var runTask: Task<Void, Never>?

    var isConnected: Bool { baseURL != nil }
    /// Notices to speak (execution approved, completed, stopped…).
    var onEvent: ((String) -> Void)?

    // MARK: Connection

    func connect() async -> String {
        guard let pasted = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              pasted.range(of: #"^[A-Za-z0-9_\-]{30,}$"#, options: .regularExpression) != nil else {
            return "Negli appunti non c'è un token di Robot Console. In Robot Console: Diagnostica e ROS2 › API Python › Avvia API locale, poi Copia token di questa sessione."
        }
        for port in await candidatePorts() {
            guard let url = URL(string: "http://127.0.0.1:\(port)") else { continue }
            var request = URLRequest(url: url.appendingPathComponent("v1/health"))
            request.timeoutInterval = 2
            request.setValue("Bearer \(pasted)", forHTTPHeaderField: "Authorization")
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                baseURL = url
                token = pasted
                return "Collegato a Robot Console sulla porta \(port). " + (await status())
            }
        }
        return "Non trovo l'API di Robot Console: controlla che sia avviata nell'app e che il token copiato sia quello della sessione attuale."
    }

    /// Ports listening on 127.0.0.1 belonging to Robot Console's processes.
    private func candidatePorts() async -> [Int] {
        let listing = await Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP@127.0.0.1", "-sTCP:LISTEN", "-Fpn"], timeout: 5)
        var ports: [Int: Int32] = [:]   // port -> pid
        var pid: Int32 = 0
        for line in listing.out.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) ?? 0 }
            if line.hasPrefix("n"), let port = line.split(separator: ":").last.flatMap({ Int($0) }) { ports[port] = pid }
        }
        var result: [Int] = []
        for (port, pid) in ports {
            let command = await Shell.run("/bin/ps", ["-o", "command=", "-p", String(pid)], timeout: 3)
            if command.out.contains("Robot Console") || command.out.contains("it.doc.regia") { result.append(port) }
        }
        return result.sorted()
    }

    func disconnect() {
        baseURL = nil
        token = ""
        plan = nil
    }

    // MARK: HTTP

    private func request(_ method: String, _ path: String, _ body: [String: Any]? = nil) async -> (Int, [String: Any]) {
        guard let baseURL else { return (0, ["error": "Robot Console non è collegato: di' \"collegati a Robot Console\"."]) }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return (0, ["error": "Robot Console non risponde (API fermata o app chiusa)."])
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 { disconnect() }
        return (status, (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    private static func compact(_ value: Any, limit: Int = 2500) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
        return String(String(decoding: data, as: UTF8.self).prefix(limit))
    }

    // MARK: Actions

    /// State with clear names: the API permissions concern what the script
    /// can do (plan, run in Preview), not whether the robot is moving.
    func status() async -> String {
        let (healthCode, health) = await request("GET", "v1/health")
        let (code, state) = await request("GET", "v1/state")
        guard code == 200, healthCode == 200 else { return state["error"] as? String ?? "Stato non disponibile (\(code))." }
        let studio = state["studio"] as? [String: Any] ?? [:]
        var summary: [String: Any] = [
            "api_puo_pianificare_programmi": health["motion_enabled"] ?? false,
            "api_puo_eseguire_in_anteprima": health["demo_execution"] ?? false,
            "richiesta_in_attesa_di_approvazione": health["pending"] is NSNull ? "nessuna" : health["pending"] ?? "nessuna",
            "programma_in_esecuzione": health["active"] is NSNull ? "nessuno" : health["active"] ?? "nessuno",
            "target_salvati": (studio["cartesian_targets"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? [],
        ]
        if let controller = state["controller"] as? [String: Any] {
            summary["assi_attivi_in_movimento"] = controller["active_axes"] ?? []
        }
        return "Stato Robot Console: " + Self.compact(summary)
    }

    func stop() async -> String {
        guard isConnected else { return "Robot Console non è collegato." }
        runTask?.cancel()
        let (code, body) = await request("POST", "v1/stop", [:])
        return code == 200 ? "STOP inviato a Robot Console." : "STOP non confermato: \(body["error"] ?? code)"
    }

    /// Prepares a program (planning only: the robot does not move).
    /// Note: Robot Console replaces the instructions of the active project in Studio.
    func planProgram(_ args: [String: Any]) async -> String {
        let (code, state) = await request("GET", "v1/state")
        guard code == 200 else { return state["error"] as? String ?? "Robot Console non disponibile." }
        let targets = ((state["studio"] as? [String: Any])?["cartesian_targets"] as? [[String: Any]] ?? [])
            .reduce(into: [String: Any]()) { result, t in if let n = t["name"] as? String { result[n.lowercased()] = t["id"] } }
        func target(_ name: String?) -> Any? { name.flatMap { targets[$0.lowercased()] } }

        let task = args.string("task") ?? "target"
        var blocks: [[String: Any]] = []
        switch task {
        case "pick_place":
            guard let piece = target(args.string("from")), let drop = target(args.string("to")) else {
                return "Target non trovati. Disponibili: " + targets.keys.sorted().joined(separator: ", ")
            }
            blocks = [
                ["kind": "movej", "name": "Sopra il pezzo", "to": "target", "target": piece, "offset": [0, 0, 60]],
                ["kind": "movel", "name": "Scendi", "to": "target", "target": piece, "speed": 50],
                ["kind": "grip", "name": "Chiudi", "command": "chiudi"],
                ["kind": "movel", "name": "Risali", "to": "target", "target": piece, "offset": [0, 0, 60], "speed": 50],
                ["kind": "movej", "name": "Sopra il deposito", "to": "target", "target": drop, "offset": [0, 0, 60]],
                ["kind": "movel", "name": "Appoggia", "to": "target", "target": drop, "speed": 50],
                ["kind": "grip", "name": "Apri", "command": "apri"],
                ["kind": "movel", "name": "Allontanati", "to": "target", "target": drop, "offset": [0, 0, 60]],
                ["kind": "movej", "name": "HOME", "to": "home"],
            ]
        case "home":
            blocks = [["kind": "movej", "name": "HOME", "to": "home"]]
        default:
            guard let goal = target(args.string("target")) else {
                return "Target non trovato. Disponibili: " + targets.keys.sorted().joined(separator: ", ")
            }
            blocks = [["kind": "movej", "name": "Verso \(args.string("target") ?? "")", "to": "target", "target": goal,
                       "speed": Int(args.number("speed") ?? 50)]]
        }
        let (planCode, planned) = await request("POST", "v1/program/plan", ["blocks": blocks, "scenario": [:]])
        guard planCode == 200 else {
            plan = nil
            return "Pianificazione rifiutata: \(planned["error"] ?? planCode) \(planned["problem"] ?? "")"
        }
        plan = planned
        let duration = (planned["duration"] as? Double).map { String(format: "%.1f", $0) } ?? "?"
        return "Piano pronto (\(blocks.count) istruzioni, circa \(duration) s), visibile in Robot Console. Il robot non si è mosso: per eseguirlo serve la conferma."
    }

    /// Runs the prepared plan. On the real robot it waits for approval
    /// in Robot Console; JARVIS keeps the required heartbeat and gives spoken notices.
    func executePlan() async -> String {
        guard let plan, let id = plan["id"], let fingerprint = plan["fingerprint"] else {
            return "Nessun piano da eseguire: prima va preparato."
        }
        let (code, run) = await request("POST", "v1/program/execute", ["id": id, "fingerprint": fingerprint, "name": "Da JARVIS", "step": false])
        guard code == 200 || code == 202, let runID = run["id"] else {
            return "Esecuzione rifiutata: \(run["error"] ?? code)"
        }
        self.plan = nil
        follow(run: "\(runID)")
        return (run["status"] as? String) == "awaiting_operator"
            ? "Richiesta inviata: approvala in Robot Console (Studio › Approva ed esegui) entro 60 secondi."
            : "Esecuzione avviata."
    }

    /// Heartbeat every 0.5 s (the API stops the program after 3 s without one) and spoken notices.
    private func follow(run id: String) {
        runTask?.cancel()
        runTask = Task { [weak self] in
            var lastStatus = ""
            while !Task.isCancelled, let self {
                _ = await self.request("POST", "v1/program/heartbeat", ["id": id])
                let (_, run) = await self.request("GET", "v1/runs/\(id)")
                let status = run["status"] as? String ?? ""
                if status != lastStatus {
                    lastStatus = status
                    switch status {
                    case "running": self.onEvent?("Esecuzione approvata, il robot è in movimento.")
                    case "completed": self.onEvent?("Programma completato."); return
                    case "stopped": self.onEvent?("Programma fermato."); return
                    case "failed": self.onEvent?("Programma interrotto per un errore: \(run["error"] ?? "")"); return
                    case "rejected": self.onEvent?("Richiesta rifiutata in Robot Console."); return
                    case "expired": self.onEvent?("Richiesta scaduta: nessuna approvazione entro 60 secondi."); return
                    default: break
                    }
                }
                if status.isEmpty { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}
