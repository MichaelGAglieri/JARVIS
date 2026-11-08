import ApplicationServices
import AVFoundation
import Combine
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import Network

/// The Mac side of the link with iPhone and iPad: accepts one paired device at a time, the last opened, passes
/// its requests to `Assistant` and sends back state, text and voice.
/// If the link is off in the settings, nothing listens on the network.
@MainActor
final class PhoneBridge: ObservableObject {
    /// Command typed or spoken on the iPhone.
    var onText: ((String) -> Void)?
    var onAudio: (([Float]) -> Void)?
    var onStop: (() -> Void)?
    /// The phone disconnected.
    var onGone: (() -> Void)?
    /// A phone connected.
    var onBack: (() -> Void)?

    @Published private(set) var phoneConnected = false
    @Published private(set) var problem = ""
    /// The connected phone comes through Tailscale: maybe it is away from home.
    private(set) var phoneOutside = false

    private var listener: NWListener?
    private var channel: PhoneChannel?
    private var observers: [AnyCancellable] = []
    private var waiting: [UInt32: (timeout: DispatchWorkItem, done: () -> Void)] = [:]
    private var nextClip: UInt32 = 1
    private var retry: DispatchWorkItem?
    private var activeCode = ""
    private let screen = ScreenShare()
    /// In privacy mode the Mac does not look: not even at the screen for the phone.
    var screenAllowed: (() -> Bool)?

    // MARK: Pairing code

    private static var codeFile: URL { JarvisConfig.directory.appendingPathComponent("iphone_code") }

    /// The saved code, created the first time. The file is readable only by the user.
    static var pairingCode: String {
        if let saved = try? String(contentsOf: codeFile, encoding: .utf8), PhoneLink.isValid(saved) {
            return saved.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return renewedCode()
    }

    @discardableResult
    private static func renewedCode() -> String {
        let code = PhoneLink.newCode()
        try? code.write(to: codeFile, atomically: true, encoding: .utf8)
        Security.protect(codeFile)
        return code
    }

    /// The QR content: the code and the Mac's name, in case automatic discovery does not find it.
    static var pairingLink: String {
        var parts = URLComponents()
        parts.scheme = "jarvis"
        parts.host = "pair"
        parts.queryItems = [.init(name: "code", value: pairingCode), .init(name: "host", value: ProcessInfo.processInfo.hostName)]
        if let outside = tailscaleAddress() { parts.queryItems?.append(.init(name: "outside", value: outside)) }
        return parts.string ?? ""
    }

    /// A new code: the previously paired phone can no longer get in.
    func renewCode() {
        Self.renewedCode()
        Security.audit("codice iPhone cambiato", tool: "iphone", source: "impostazioni")
        guard listener != nil else { return }
        stop()
        start()
    }

    // MARK: Listening

    /// The test code comes from the arguments and is never saved.
    func start(testCode: String? = nil) {
        guard listener == nil else { return }
        activeCode = testCode ?? Self.pairingCode
        do {
            let parameters = PhoneLink.parameters(code: activeCode)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: PhoneLink.port)!)
            listener.service = NWListener.Service(name: "JARVIS", type: PhoneLink.serviceType)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state) }
            }
            listener.start(queue: .main)
            self.listener = listener
            problem = ""
            stayAwake()
            Security.audit("collegamento iPhone acceso", tool: "iphone", source: "impostazioni")
        } catch {
            problem = "Non riesco ad aprire la porta \(PhoneLink.port)."
            Diagnostics.log("iphone    ascolto non avviato: \(error)")
        }
    }

    func stop() {
        retry?.cancel()
        retry = nil
        guard listener != nil else { return }
        listener?.cancel()
        listener = nil
        stopWatching(reason: nil)
        channel?.close()
        stayAwake()
        Security.audit("collegamento iPhone spento", tool: "iphone", source: "impostazioni")
    }

    // MARK: Reachable from outside

    /// This Mac's address on the Tailscale network, if it is on.
    private static func tailscaleAddress() -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }
        defer { freeifaddrs(first) }
        var current = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let raw = entry.pointee.ifa_addr, raw.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let bytes = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin_addr) { [UInt8]($0) }
            }
            if PhoneLink.isTailscale(bytes) { return bytes.map(String.init).joined(separator: ".") }
        }
        return nil
    }

    private var awake: NSObjectProtocol?
    private var awakeCheck: Timer?

    /// With the link on and on mains power the Mac does not sleep by itself, otherwise it cannot
    /// be reached from outside. On battery it sleeps as usual, and the screen turns off anyway.
    private func stayAwake() {
        let wanted: Bool = {
            guard listener != nil, let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
            return (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) != kIOPMBatteryPowerKey
        }()
        if wanted, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Collegamento con l'iPhone acceso")
        } else if !wanted, let current = awake {
            ProcessInfo.processInfo.endActivity(current)
            awake = nil
        }
        if listener == nil {
            awakeCheck?.invalidate()
            awakeCheck = nil
        } else if awakeCheck == nil {
            // Power can be unplugged at any moment.
            awakeCheck = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.stayAwake() }
            }
            awakeCheck?.tolerance = 20
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        guard case .failed(let error) = state else { return }
        Diagnostics.log("iphone    ascolto caduto: \(error)")
        problem = "Collegamento caduto, riprovo tra poco."
        listener?.cancel()
        listener = nil
        // For example the port is still taken by the previous launch.
        let again = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.start(testCode: self.activeCode == Self.pairingCode ? nil : self.activeCode)
            }
        }
        retry = again
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: again)
    }

    private func accept(_ connection: NWConnection) {
        guard PhoneLink.isLocal(connection.endpoint) else {
            Security.audit("collegamento rifiutato", tool: "iphone", source: "rete", detail: "indirizzo fuori dalla rete locale")
            connection.cancel()
            return
        }
        let candidate = PhoneChannel(connection)
        var accepted = false
        // Counts only after the handshake: an attempt without the code does not disconnect the connected phone.
        candidate.onReady = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                accepted = true
                if let previous = self.channel {
                    self.channel = nil
                    self.deviceLeft()
                    previous.sendAndClose(PhoneMessage(.replaced))
                }
                self.channel = candidate
                self.phoneConnected = true
                self.phoneOutside = PhoneLink.isOutside(connection.endpoint)
                candidate.send(PhoneMessage(.welcome, text: Host.current().localizedName ?? "Mac", number: PhoneLink.version,
                                            address: Self.tailscaleAddress()))
                self.onBack?()
                Security.audit("iPhone collegato", tool: "iphone", source: "iphone", detail: "\(connection.endpoint)")
                self.forward(currentState: true)
            }
        }
        candidate.onMessage = { [weak self] message in
            MainActor.assumeIsolated { self?.received(message, from: candidate) }
        }
        candidate.onClip = { [weak self] clip in
            MainActor.assumeIsolated {
                guard let self, self.channel === candidate else { return }
                self.onAudio?(clip.samples)
            }
        }
        candidate.onClosed = { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !accepted, let error {
                    Diagnostics.log("iphone    tentativo non riuscito: \(error)")
                    Security.audit("collegamento rifiutato", tool: "iphone", source: "rete", detail: "codice errato o errore di rete")
                }
                guard self.channel === candidate else { return }
                self.channel = nil
                self.deviceLeft()
            }
        }
        candidate.start()
        // Whoever opens the connection and does not complete the handshake is not left hanging.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak candidate] in
            if !accepted { candidate?.close() }
        }
    }

    private func deviceLeft() {
        phoneConnected = false
        phoneOutside = false
        stopWatching(reason: nil)
        finishAllClips()
        Security.audit("iPhone scollegato", tool: "iphone", source: "iphone")
        onGone?()
    }

    private func received(_ message: PhoneMessage, from sender: PhoneChannel) {
        guard channel === sender else { return }
        switch message.kind {
        case .hello:
            // An older app still works (the screen arrives as photos): warn only if it is newer.
            phoneVersion = message.number ?? 1
            if phoneVersion > PhoneLink.version {
                send(PhoneMessage(.notice, text: "App iPhone e JARVIS sul Mac hanno versioni diverse."))
            }
            Security.audit("dispositivo collegato", tool: "iphone", source: "iphone", detail: String((message.text ?? "").prefix(60)))
        case .command:
            if let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                onText?(String(text.prefix(4000)))
            }
        case .stop:
            onStop?()
        case .played:
            if let id = message.number { finishClip(UInt32(id)) }
        case .watch:
            if message.number == 1 { startWatching() } else { stopWatching(reason: nil) }
        case .frameShown:
            screen.frameShown()
        case .pointer, .typing, .key:
            control(message)
        default:
            break
        }
    }

    // MARK: Mac screen on the phone

    private func startWatching() {
        guard !screen.isActive else { return }
        guard screenAllowed?() ?? false else {
            send(PhoneMessage(.watchEnded, text: "Sul Mac è attiva la modalità privacy: lo schermo non si vede."))
            return
        }
        Security.audit("schermo mostrato al telefono", tool: "iphone", source: "iphone", detail: phoneOutside ? "da fuori casa" : "")
        // The Mac screen might be off: it turns on and stays on while the view is open.
        var woke: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Schermo mostrato al telefono" as CFString, kIOPMUserActiveLocal, &woke)
        displayAwake = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled], reason: "Schermo mostrato al telefono")
        screen.start(video: phoneVersion >= 2, send: { [weak self] frame in
            switch frame {
            case .photo(let data): self?.channel?.send(screen: data)
            case .video(let packet): self?.channel?.send(video: packet)
            }
        }, failed: { [weak self] reason in
            self?.send(PhoneMessage(.watchEnded, text: reason))
        })
    }

    /// With `reason` the phone closes the view and says why.
    func stopWatching(reason: String?) {
        if RemoteInput.pressed { RemoteInput.release(at: lastDragPoint) }
        guard screen.isActive else { return }
        screen.stop()
        if let displayAwake { ProcessInfo.processInfo.endActivity(displayAwake) }
        displayAwake = nil
        Security.audit("schermo non più mostrato", tool: "iphone", source: "iphone", detail: reason ?? "")
        if let reason { send(PhoneMessage(.watchEnded, text: reason)) }
    }

    private var displayAwake: NSObjectProtocol?
    /// Version of the connected app, from its hello.
    private var phoneVersion = 1
    private var lastScrollAudit = Date.distantPast

    /// Clicks and keys given by hand from the phone: the user makes them, seeing the screen, so they do not go through
    /// the rules meant for the model. No view or privacy mode, no commands. Text does not go to the log:
    /// it could be a password.
    private var dragRelease: DispatchWorkItem?
    private var lastDragPoint = CGPoint.zero

    /// A drag left halfway (link dropped) must not leave the mouse button pressed.
    private func releaseLater() {
        dragRelease?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, RemoteInput.pressed else { return }
            RemoteInput.release(at: self.lastDragPoint)
            Diagnostics.log("iphone    trascinamento rilasciato: nessun segnale dal telefono")
        }
        dragRelease = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func control(_ message: PhoneMessage) {
        guard screen.isActive, screenAllowed?() ?? false else { return }
        guard AXIsProcessTrusted() else {
            send(PhoneMessage(.notice, text: "Per cliccare dal telefono serve il permesso Accessibilità per JARVIS, sul Mac."))
            return
        }
        switch message.kind {
        case .pointer:
            guard let x = message.x, let y = message.y, (0...1).contains(x), (0...1).contains(y) else { return }
            let bounds = CGDisplayBounds(CGMainDisplayID())
            let point = CGPoint(x: bounds.minX + x * bounds.width, y: bounds.minY + y * bounds.height)
            switch message.text {
            case "scroll":
                RemoteInput.scroll(at: point, by: message.number ?? 0)
                if Date().timeIntervalSince(lastScrollAudit) > 20 {
                    lastScrollAudit = Date()
                    Security.audit("scorrimento dal telefono", tool: "iphone", source: "iphone")
                }
            case "down":
                RemoteInput.press(at: point)
                lastDragPoint = point
                releaseLater()
                Security.audit("trascinamento dal telefono", tool: "iphone", source: "iphone", detail: "\(Int(point.x)),\(Int(point.y))")
            case "drag":
                RemoteInput.drag(to: point)
                lastDragPoint = point
                releaseLater()
                return
            case "up":
                dragRelease?.cancel()
                RemoteInput.release(at: point)
            case "double":
                RemoteInput.click(at: point, count: 2)
                Security.audit("doppio clic dal telefono", tool: "iphone", source: "iphone", detail: "\(Int(point.x)),\(Int(point.y))")
            case "right":
                RemoteInput.rightClick(at: point)
                Security.audit("clic destro dal telefono", tool: "iphone", source: "iphone", detail: "\(Int(point.x)),\(Int(point.y))")
            default:
                RemoteInput.click(at: point, count: 1)
                Security.audit("clic dal telefono", tool: "iphone", source: "iphone", detail: "\(Int(point.x)),\(Int(point.y))")
            }
        case .typing:
            guard let text = message.text, !text.isEmpty else { return }
            AppControl.typeText(String(text.prefix(2000)))
            Security.audit("testo scritto dal telefono", tool: "iphone", source: "iphone", detail: "\(text.count) caratteri")
        case .key:
            guard let name = message.text, RemoteInput.press(name) else { return }
            Security.audit("tasto dal telefono", tool: "iphone", source: "iphone", detail: name)
        default:
            return
        }
        screen.hurry()
    }

    // MARK: Towards the phone

    private var stateProvider: (() -> (state: String, heard: String, reply: String))?

    /// Call once: keeps the phone in step with what the HUD shows.
    func follow(state: AnyPublisher<Assistant.State, Never>, heard: AnyPublisher<String, Never>, reply: AnyPublisher<String, Never>,
                current: @escaping () -> (state: String, heard: String, reply: String)) {
        stateProvider = current
        state.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] value in
            self?.send(PhoneMessage(.state, text: value.wireName))
        }.store(in: &observers)
        heard.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] value in
            self?.send(PhoneMessage(.heard, text: value))
        }.store(in: &observers)
        reply.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] value in
            self?.send(PhoneMessage(.reply, text: value))
        }.store(in: &observers)
    }

    private func forward(currentState: Bool) {
        guard let now = stateProvider?() else { return }
        send(PhoneMessage(.state, text: now.state))
        send(PhoneMessage(.heard, text: now.heard))
        send(PhoneMessage(.reply, text: now.reply))
    }

    func send(_ message: PhoneMessage) {
        channel?.send(message)
    }

    /// Sends a sentence to the phone; `done` comes when the phone has finished saying it,
    /// or shortly after its duration if the acknowledgment is lost: the answer must not hang.
    func play(_ buffer: AVAudioPCMBuffer, done: @escaping () -> Void) {
        guard let channel, let data = buffer.floatChannelData else {
            done()
            return
        }
        let clip = PhoneClip(id: nextClip, sampleRate: UInt32(buffer.format.sampleRate),
                             samples: Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))))
        nextClip &+= 1
        let id = clip.id
        // Sentences can pile up on the phone: what is left to say is counted too.
        let pendingSeconds = pendingDuration
        pendingDuration += clip.duration
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.finishClip(id) }
        }
        waiting[id] = (timeout, done)
        clipDurations[id] = clip.duration
        DispatchQueue.main.asyncAfter(deadline: .now() + pendingSeconds + clip.duration + 4, execute: timeout)
        channel.send(clip)
    }

    private var pendingDuration = 0.0
    private var clipDurations: [UInt32: Double] = [:]

    private func finishClip(_ id: UInt32) {
        pendingDuration = max(0, pendingDuration - (clipDurations.removeValue(forKey: id) ?? 0))
        guard let entry = waiting.removeValue(forKey: id) else { return }
        entry.timeout.cancel()
        entry.done()
    }

    /// Cuts the voice on the phone and releases whoever is waiting.
    func stopAudio() {
        send(PhoneMessage(.stopAudio))
        finishAllClips(notify: false)
    }

    private func finishAllClips(notify: Bool = true) {
        let entries = waiting.values
        waiting.removeAll()
        clipDurations.removeAll()
        pendingDuration = 0
        for entry in entries {
            entry.timeout.cancel()
            if notify { entry.done() }
        }
    }
}

extension Assistant.State {
    /// The name that travels to the phone.
    var wireName: String {
        switch self {
        case .booting: return "booting"
        case .idle: return "idle"
        case .listening: return "listening"
        case .transcribing: return "transcribing"
        case .thinking: return "thinking"
        case .acting: return "acting"
        case .speaking: return "speaking"
        case .error: return "error"
        }
    }
}
