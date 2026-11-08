import Foundation
import Network

/// The Samsung TV at home, on the local network. The first time the TV asks on screen whether
/// to trust JARVIS; the key it returns lives in tv.json, readable only by the user.
@MainActor
final class TVControl {
    private struct Saved: Codable {
        var host = "Samsung.local"
        var mac: String?
        var token: String?
    }

    private static let file = JarvisConfig.directory.appendingPathComponent("tv.json")
    private var saved: Saved = {
        guard let data = try? Data(contentsOf: TVControl.file), let value = try? JSONDecoder().decode(Saved.self, from: data) else { return Saved() }
        return value
    }()

    private func save() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: Self.file, options: .atomic)
        Security.protect(Self.file)
    }

    private static let keys = [
        "volume_up": "KEY_VOLUP", "volume_down": "KEY_VOLDOWN", "mute": "KEY_MUTE", "channel_up": "KEY_CHUP", "channel_down": "KEY_CHDOWN",
        "home": "KEY_HOME", "back": "KEY_RETURN", "up": "KEY_UP", "down": "KEY_DOWN", "left": "KEY_LEFT", "right": "KEY_RIGHT",
        "enter": "KEY_ENTER", "play": "KEY_PLAY", "pause": "KEY_PAUSE", "stop": "KEY_STOP", "source": "KEY_SOURCE", "hdmi": "KEY_HDMI",
    ]

    /// App identifiers on Samsung TVs, newest first.
    private static let apps = [
        "netflix": ["3201907018807", "11101200001"], "youtube": ["111299001912"], "prime": ["3201910019365", "3201512006785"],
        "disney": ["3201901017640"],
    ]

    func run(action: String, value: String?) async -> String {
        switch action {
        case "status":
            return await info() == nil ? "La TV non risponde: è spenta o non è in rete." : "La TV è accesa."
        case "on":
            return await turnOn()
        case "off":
            guard await info() != nil else { return "La TV è già spenta o non risponde." }
            return await send("KEY_POWER", done: "TV spenta.")
        case "app":
            return await open(app: value ?? "")
        default:
            guard let key = Self.keys[action] else { return "Comando TV sconosciuto: \(action)" }
            guard await info() != nil else { return "La TV è spenta o non è in rete." }
            // "Alza di cinque": the same key several times, but with a limit.
            let times = max(1, min(20, Int(value ?? "") ?? 1))
            return await send(key, times: times, done: "Fatto.")
        }
    }

    private func info() async -> [String: Any]? {
        guard let url = URL(string: "http://\(saved.host):8001/api/v2/") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = root["device"] as? [String: Any] else { return nil }
        // The physical address is needed to turn it on when it is off.
        if let mac = device["wifiMac"] as? String, mac != saved.mac {
            saved.mac = mac
            save()
        }
        return device
    }

    private func turnOn() async -> String {
        if await info() != nil { return "La TV è già accesa." }
        guard let mac = saved.mac, let packet = Self.magicPacket(mac) else {
            return "Non posso accenderla la prima volta: serve averla vista accesa almeno una volta."
        }
        for _ in 0..<3 {
            Self.broadcast(packet)
            for _ in 0..<5 {
                try? await Task.sleep(for: .seconds(1))
                if await info() != nil { return "TV accesa." }
            }
        }
        return "Ho mandato il segnale, ma la TV non risponde. Controlla sulla TV: Generale, Rete, Impostazioni esperto, Accensione con dispositivo mobile."
    }

    private func open(app name: String) async -> String {
        guard await info() != nil else { return "La TV è spenta o non è in rete." }
        guard let entry = Self.apps.first(where: { name.lowercased().contains($0.key) }) else {
            return "Sulla TV so aprire Netflix, YouTube, Prime Video e Disney+."
        }
        for id in entry.value {
            guard let url = URL(string: "http://\(saved.host):8001/api/v2/applications/\(id)") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 5
            if let (_, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 {
                return "Aperta \(entry.key) sulla TV."
            }
        }
        return "La TV non ha aperto \(entry.key): forse l'app non è installata."
    }

    // MARK: Remote control

    private func send(_ key: String, times: Int = 1, done: String) async -> String {
        var parts = URLComponents()
        parts.scheme = "wss"
        parts.host = saved.host
        parts.port = 8002
        parts.path = "/api/v2/channels/samsung.remote.control"
        parts.queryItems = [.init(name: "name", value: Data("JARVIS".utf8).base64EncodedString())]
        if let token = saved.token { parts.queryItems?.append(.init(name: "token", value: token)) }
        guard let url = parts.url else { return "Indirizzo della TV non valido." }
        let channel = TVChannel(url: url)
        defer { channel.close() }
        // The first time the answer arrives only after "Consenti" on the TV.
        guard let welcome = await channel.nextMessage(seconds: saved.token == nil ? 40 : 6) else {
            return saved.token == nil ? "La TV non ha risposto. Se sullo schermo è comparsa la richiesta, scegli Consenti e riprova." : "La TV non ha risposto."
        }
        guard welcome["event"] as? String == "ms.channel.connect" else {
            return "La TV ha rifiutato il collegamento: va consentito JARVIS in Generale, Gestione dispositivi esterni, Gestione connessione dispositivi."
        }
        if let data = welcome["data"] as? [String: Any], let token = data["token"] as? String, token != saved.token {
            saved.token = token
            save()
        }
        let command: [String: Any] = ["method": "ms.remote.control", "params": ["Cmd": "Click", "DataOfCmd": key, "Option": "false", "TypeOfRemote": "SendRemoteKey"]]
        guard let data = try? JSONSerialization.data(withJSONObject: command) else { return "Comando non valido." }
        for _ in 0..<times {
            guard await channel.send(data) else { return "Collegamento con la TV caduto." }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return done
    }

    // MARK: Power on

    /// Six bytes of 255 and sixteen times the physical address.
    nonisolated static func magicPacket(_ mac: String) -> Data? {
        let bytes = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return nil }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        return packet
    }

    nonisolated private static func broadcast(_ packet: Data) {
        let connection = NWConnection(host: "255.255.255.255", port: 9, using: .udp)
        connection.start(queue: .global())
        connection.send(content: packet, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// The remote control channel. The TV's certificate is self-made and URLSession does not accept it:
/// with Network.framework it is accepted only for this connection, which carries keys and no data.
private final class TVChannel: @unchecked Sendable {
    private let connection: NWConnection

    init(url: URL) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .global())
        let parameters = NWParameters(tls: tls)
        let socket = NWProtocolWebSocket.Options()
        socket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(socket, at: 0)
        connection = NWConnection(to: .url(url), using: parameters)
        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state { Diagnostics.log("tv        collegamento non riuscito: \(error)") }
            if case .waiting(let error) = state { Diagnostics.log("tv        in attesa: \(error)") }
        }
        connection.start(queue: .global())
    }

    func close() { connection.cancel() }

    func nextMessage(seconds: Double) async -> [String: Any]? {
        let timeout = Task { [connection] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { connection.cancel() }
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { continuation in
            connection.receiveMessage { data, _, _, error in
                if let error { Diagnostics.log("tv        risposta non ricevuta: \(error)") }
                continuation.resume(returning: data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] })
            }
        }
    }

    func send(_ data: Data) async -> Bool {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "tasto", metadata: [metadata])
        return await withCheckedContinuation { continuation in
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }
}
