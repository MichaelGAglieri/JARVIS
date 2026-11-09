import Foundation
import Network

/// Bambu printer on the home network. From here it is read only: the firmware rejects unsigned direct
/// commands, so commands go through Bambu Studio (`BambuStudioControl`).
/// It speaks MQTT over TLS (port 8883, user "bblp", password the access code).
final class BambuPrinter {
    struct Status {
        var state: String?
        var percent: Int?
        var remainingMinutes: Int?
        var layer: Int?
        var totalLayers: Int?
        var job: String?
        var errorCode = 0
        var problems: [String] = []
        var nozzleTarget = 0
        /// The filament sensor in the toolhead. nil until the printer reports it.
        var filamentPresent: Bool?
        var amsStatus = 0

        /// External spool: the printer waits for a hand (errors 07FF-xxxx). 3 = pull the filament out,
        /// 6 = insert it; the others, for example "check it comes out of the nozzle", the user decides.
        var manualStep: Int? { errorCode >> 16 == 0x07FF ? errorCode & 0xFFF : nil }
        var isPrinting: Bool { ["RUNNING", "PREPARE", "PAUSE", "SLICING"].contains(state ?? "") }
        /// The nozzle is being driven or the filament is moving (main state 1 = filament change).
        var isChangingFilament: Bool { !isPrinting && (nozzleTarget > 0 || amsStatus >> 8 == 1 || manualStep != nil) }
    }

    private(set) var status = Status()
    private(set) var connected = false
    private(set) var loginRefused = false
    var isConfigured: Bool { !host.isEmpty && !serial.isEmpty && !code.isEmpty }
    /// The router gave it another address and JARVIS found it again: it must be saved in the settings.
    var onHostFound: ((String) -> Void)?
    /// When it finishes or gets stuck: the sentence to say, in Italian and English.
    var onAlert: ((_ id: String, _ italian: String, _ english: String) -> Void)?

    private var host = ""
    /// The address in the settings; `host` changes while searching for the printer on the network.
    private var savedHost = ""
    /// The other network devices still to try.
    private var candidates: [String] = []
    private var failures = 0
    /// The network search costs 254 attempts: after the first one it comes back more and more rarely
    /// (4, 8, 16, then every 30 minutes) and never when `maySearch` says no (quiet hours, privacy).
    private var searchInterval: TimeInterval = 240
    private var nextSearch = Date.distantPast
    var maySearch: (() -> Bool)?
    private var attempt: DispatchWorkItem?
    private var serial = ""
    private var code = ""
    private var connection: NWConnection?
    private var buffer = Data()
    private var ping: Timer?
    private var retry: DispatchWorkItem?

    func configure(host: String, serial: String, code: String) {
        let host = host.trimmingCharacters(in: .whitespaces)
        let serial = serial.trimmingCharacters(in: .whitespaces)
        let code = code.trimmingCharacters(in: .whitespaces)
        guard host != self.host || serial != self.serial || code != self.code else { return }
        (self.host, self.serial, self.code) = (host, serial, code)
        savedHost = host
        candidates = []
        failures = 0
        resetSearch()
        status = Status()
        loginRefused = false
        disconnect()
        if isConfigured { connect() }
    }

    // MARK: Connection

    private func connect() {
        let tls = NWProtocolTLS.Options()
        // The printer has its own certificate, signed by no authority: it is accepted,
        // and the connection goes only to the address written in the settings.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .main)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 8883, using: NWParameters(tls: tls))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, connection === self.connection else { return }
            switch state {
            case .ready:
                self.send(Self.packet(0x10, Self.string("MQTT") + [4, 0xC2, 0, 60]
                                      + Self.string("jarvis-\(UInt16.random(in: 0...UInt16.max))") + Self.string("bblp") + Self.string(self.code)))
                self.receive()
            case .failed, .cancelled, .waiting:
                // "waiting": the address does not answer. Before, it stayed there forever, without retrying.
                self.lost()
            default:
                break
            }
        }
        connection.start(queue: .main)
        // An address that does not answer at all gives no error: stop waiting.
        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self, connection === self.connection, !self.connected else { return }
            self.lost()
        }
        attempt = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + (candidates.isEmpty && host == savedHost ? 10 : 3), execute: timeout)
    }

    private func disconnect() {
        retry?.cancel()
        attempt?.cancel()
        ping?.invalidate()
        let old = connection
        connection = nil
        connected = false
        buffer.removeAll()
        old?.cancel()
    }

    private func lost() {
        let was = connected
        disconnect()
        if was { Diagnostics.log("stampante collegamento perso") }
        guard isConfigured, !loginRefused else { return }
        if !candidates.isEmpty {
            host = candidates.removeFirst()
            connect()
            return
        }
        host = savedHost
        failures += 1
        // At the first missed answer, and then more and more rarely, look for it among the network's devices.
        if !was, Date() >= nextSearch, maySearch?() ?? true {
            nextSearch = Date().addingTimeInterval(searchInterval)
            searchInterval = min(searchInterval * 2, 1800)
            searchNetwork()
            return
        }
        retryLater()
    }

    /// The saved address is tried again every 30 seconds at first, then every 5 minutes.
    private func retryLater() {
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (failures < 10 ? 30 : 300), execute: work)
    }

    private func resetSearch() {
        searchInterval = 240
        nextSearch = .distantPast
    }

    /// The user asks about the printer: if it is not connected, look for it at once (network search included)
    /// and wait a few seconds for it, instead of waiting for the next scheduled attempt.
    func reachNow() async {
        guard isConfigured, !connected, !loginRefused else { return }
        if candidates.isEmpty {
            failures = 0
            resetSearch()
            disconnect()
            host = savedHost
            connect()
        }
        let end = Date().addingTimeInterval(5)
        while Date() < end, !connected || status.state == nil, !loginRefused {
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    /// Devices of the same network the Mac has seen recently (ARP table). Only the printer's
    /// port is tried, and the right printer is the one that accepts its access code.
    private func searchNetwork() {
        let saved = savedHost
        Task.detached { [weak self] in
            let found = await Self.neighbors(near: saved)
            await MainActor.run {
                guard let self, self.savedHost == saved, !self.connected else { return }
                Diagnostics.log("stampante non risponde a \(saved): provo \(found.count) dispositivi della rete")
                guard !found.isEmpty else { return self.retryLater() }
                self.candidates = Array(found.dropFirst())
                self.host = found[0]
                self.connect()
            }
        }
    }

    /// Network addresses with the printer's port open. macOS hides the list of
    /// devices (ARP table) from apps, so the port is tried on the whole network: a short attempt, 64 at a time.
    nonisolated private static func neighbors(near address: String) async -> [String] {
        let parts = address.split(separator: ".")
        guard parts.count == 4 else { return [] }
        let prefix = parts.prefix(3).joined(separator: ".") + "."
        let all = (1...254).map { prefix + String($0) }.filter { $0 != address }
        var found: [String] = []
        for chunk in stride(from: 0, to: all.count, by: 64).map({ Array(all[$0..<min($0 + 64, all.count)]) }) {
            await withTaskGroup(of: String?.self) { group in
                for ip in chunk { group.addTask { await portOpen(ip, 8883) ? ip : nil } }
                for await ip in group { if let ip { found.append(ip) } }
            }
        }
        Diagnostics.log("stampante porta aperta su \(found.count) dispositivi della rete")
        return found
    }

    nonisolated private static func portOpen(_ ip: String, _ port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let lock = NSLock()
            var done = false
            func finish(_ open: Bool) {
                let first = lock.withLock { () -> Bool in defer { done = true }; return !done }
                guard first else { return }
                connection.cancel()
                continuation.resume(returning: open)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { finish(false) }
        }
    }

    /// Asks for the full state: a read only.
    func refresh() {
        guard connected else { return }
        requestFullStatus()
    }

    private func requestFullStatus() {
        let request = #"{"pushing":{"sequence_id":"0","command":"pushall"}}"#
        send(Self.packet(0x30, Self.string("device/\(serial)/request") + Array(request.utf8)))
    }

    private func send(_ bytes: [UInt8]) {
        connection?.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data {
                self.buffer.append(data)
                self.readPackets()
            }
            if done || error != nil { self.lost() } else if self.connection != nil { self.receive() }
        }
    }

    // MARK: MQTT

    private static func string(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        return [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)] + bytes
    }

    private static func packet(_ type: UInt8, _ body: [UInt8]) -> [UInt8] {
        var length = body.count
        var head = [type]
        repeat {
            var byte = UInt8(length % 128)
            length /= 128
            if length > 0 { byte |= 0x80 }
            head.append(byte)
        } while length > 0
        return head + body
    }

    private func readPackets() {
        while let first = buffer.first {
            var length = 0, multiplier = 1, index = 1
            var complete = false
            while index < buffer.count, index <= 4 {
                let byte = Int(buffer[buffer.startIndex + index])
                length += (byte & 0x7F) * multiplier
                multiplier *= 128
                index += 1
                if byte & 0x80 == 0 { complete = true; break }
            }
            guard complete, buffer.count >= index + length else { return }
            let body = Array(buffer[(buffer.startIndex + index)..<(buffer.startIndex + index + length)])
            buffer.removeFirst(index + length)
            handle(type: first >> 4, body)
        }
    }

    private func handle(type: UInt8, _ body: [UInt8]) {
        switch type {
        case 2: // CONNACK
            guard body.count >= 2, body[1] == 0 else {
                // During the search a refusal only means "it is not the one": move to the next.
                if host != savedHost { return lost() }
                loginRefused = true
                Diagnostics.log("stampante ha rifiutato il codice di accesso")
                disconnect()
                return
            }
            connected = true
            attempt?.cancel()
            failures = 0
            resetSearch()
            candidates = []
            if host != savedHost {
                Diagnostics.log("stampante ritrovata a \(host) (era \(savedHost)): indirizzo aggiornato")
                savedHost = host
                onHostFound?(host)
            }
            Diagnostics.log("stampante collegata")
            send(Self.packet(0x82, [0, 1] + Self.string("device/\(serial)/report") + [0]))
            requestFullStatus()
            ping?.invalidate()
            ping = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.send([0xC0, 0]) }
        case 3: // PUBLISH
            guard body.count > 2 else { return }
            let skip = 2 + Int(body[0]) << 8 + Int(body[1])
            guard body.count > skip else { return }
            if let json = try? JSONSerialization.jsonObject(with: Data(body[skip...])) as? [String: Any],
               let report = json["print"] as? [String: Any] {
                update(report)
            }
        default:
            break
        }
    }

    // MARK: State

    /// Many printers send only what changed: the rest is updated as it is.
    private func update(_ report: [String: Any]) {
        let previous = status
        if let state = report["gcode_state"] as? String { status.state = state }
        if let value = Self.int(report["mc_percent"]) { status.percent = value }
        if let value = Self.int(report["mc_remaining_time"]) { status.remainingMinutes = value }
        if let value = Self.int(report["layer_num"]) { status.layer = value }
        if let value = Self.int(report["total_layer_num"]) { status.totalLayers = value }
        if let value = (report["subtask_name"] as? String) ?? (report["gcode_file"] as? String), !value.isEmpty { status.job = value }
        if let value = Self.int(report["print_error"]) { status.errorCode = value }
        if let list = report["hms"] as? [[String: Any]] {
            status.problems = list.map { "\(Self.int($0["attr"]) ?? 0)-\(Self.int($0["code"]) ?? 0)" }
        }
        if let value = Self.int(report["nozzle_target_temper"]) { status.nozzleTarget = value }
        if let value = Self.int(report["hw_switch_state"]) { status.filamentPresent = value == 1 }
        if let value = Self.int(report["ams_status"]) { status.amsStatus = value }
        alertIfNeeded(from: previous)
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private var jobName: String {
        guard let job = status.job else { return "" }
        return " di " + (job as NSString).deletingPathExtension.replacingOccurrences(of: ".gcode", with: "")
    }

    private func alertIfNeeded(from previous: Status) {
        guard let before = previous.state, let now = status.state else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        if before != now {
            Diagnostics.log("stampante \(before) → \(now)")
            switch now {
            case "FINISH":
                onAlert?("stampa-fine-\(stamp)", "La stampa\(jobName) è finita, signore.", "The print has finished, sir.")
            case "FAILED":
                onAlert?("stampa-errore-\(stamp)", "Signore, la stampa\(jobName) si è interrotta per un errore.", "Sir, the print has stopped with an error.")
            case "PAUSE":
                onAlert?("stampa-pausa-\(stamp)", "Signore, la stampa\(jobName) è in pausa: controlli la stampante.", "Sir, the print is paused: please check the printer.")
            default:
                break
            }
            return
        }
        // A new problem while printing, without it stopping.
        if now == "RUNNING", !Set(status.problems).subtracting(previous.problems).isEmpty {
            onAlert?("stampa-problema-\(stamp)", "Signore, la stampante segnala un problema: la controlli.", "Sir, the printer reports a problem: please check it.")
        }
    }

    /// The sentence for "a che punto è la stampa?".
    func spokenStatus(italian: Bool) -> String {
        let sir = italian ? "signore" : "sir"
        if loginRefused {
            return italian ? "La stampante ha rifiutato il codice di accesso, \(sir)." : "The printer refused the access code, \(sir)."
        }
        guard connected, let state = status.state else {
            return italian ? "Non riesco a collegarmi alla stampante, \(sir)." : "I can't reach the printer, \(sir)."
        }
        switch state {
        case "RUNNING", "PREPARE", "SLICING":
            var parts = [italian ? "Stampa al \(status.percent ?? 0) per cento" : "The print is at \(status.percent ?? 0) percent"]
            if let layer = status.layer, let total = status.totalLayers, total > 0 {
                parts.append(italian ? "strato \(layer) di \(total)" : "layer \(layer) of \(total)")
            }
            if let minutes = status.remainingMinutes {
                parts.append(italian ? "mancano \(Self.duration(minutes, italian: true))" : "\(Self.duration(minutes, italian: false)) left")
            }
            return parts.joined(separator: ", ") + ", \(sir)."
        case "PAUSE":
            return italian ? "La stampa è in pausa al \(status.percent ?? 0) per cento, \(sir)." : "The print is paused at \(status.percent ?? 0) percent, \(sir)."
        case "FINISH":
            return italian ? "L'ultima stampa è finita, \(sir)." : "The last print has finished, \(sir)."
        case "FAILED":
            return italian ? "L'ultima stampa si è interrotta per un errore, \(sir)." : "The last print stopped with an error, \(sir)."
        default:
            return italian ? "Nessuna stampa in corso, \(sir)." : "No print is running, \(sir)."
        }
    }

    private static func duration(_ minutes: Int, italian: Bool) -> String {
        let (hours, rest) = (minutes / 60, minutes % 60)
        if italian {
            let h = hours == 1 ? "un'ora" : "\(hours) ore"
            let m = rest == 1 ? "un minuto" : "\(rest) minuti"
            return hours == 0 ? m : rest == 0 ? h : "\(h) e \(m)"
        }
        let h = hours == 1 ? "1 hour" : "\(hours) hours"
        let m = rest == 1 ? "1 minute" : "\(rest) minutes"
        return hours == 0 ? m : rest == 0 ? h : "\(h) and \(m)"
    }

    /// For the MODULES panel.
    var hudStatus: String {
        guard isConfigured else { return "NON CONFIGURATA" }
        if loginRefused { return "CODICE RIFIUTATO" }
        guard connected else { return "NON RAGGIUNGIBILE" }
        guard let state = status.state else { return "COLLEGATA" }
        return state == "RUNNING" ? "IN STAMPA \(status.percent ?? 0)%" : state
    }
}
