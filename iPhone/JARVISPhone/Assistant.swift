import AVFoundation
import Combine
import Foundation
import LocalAuthentication
import Network
import Security
import UIKit

/// The levels that move the reactor: outside @Published because they change constantly.
final class AudioLevels {
    var mic: Float = 0
    var voice: Float = 0
}

/// On the phone the assistant is only a remote: models and tools live on the Mac.
/// It has the same name as the Mac's because `ReactorView` is the same file.
@MainActor
final class Assistant: ObservableObject {
    enum State: Equatable {
        case booting(String)
        case idle
        case listening
        case transcribing
        case thinking
        case acting
        case speaking
        case error(String)

        var label: (it: String, en: String) {
            switch self {
            case .booting: return ("RICERCA DEL MAC", "SEARCHING")
            case .idle: return ("IN ATTESA", "STANDBY")
            case .listening: return ("IN ASCOLTO", "LISTENING")
            case .transcribing: return ("ELABORAZIONE", "PROCESSING")
            case .thinking: return ("ANALISI", "THINKING")
            case .acting: return ("ESECUZIONE", "EXECUTING")
            case .speaking: return ("RISPOSTA", "RESPONDING")
            case .error: return ("ANOMALIA", "FAULT")
            }
        }
    }

    enum Link: Equatable {
        case unpaired
        case searching
        case connected(String)
        case refused
        /// The Mac switched to another device: take it back by opening the app or with "Usa qui".
        case elsewhere
    }

    @Published private(set) var state: State = .booting("") {
        didSet {
            guard state != oldValue else { return }
            // While JARVIS works or speaks the screen stays on: locking would lose the voice.
            keepScreenAwake()
            updateEar()
            // As on the Mac: after a minute of waiting the reactor almost stops and uses little power.
            deepIdle = false
            idleTask?.cancel()
            guard state == .idle else { return }
            idleTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.deepIdle = true
            }
        }
    }
    @Published private(set) var deepIdle = false
    private var idleTask: Task<Void, Never>?
    @Published private(set) var link: Link = .unpaired
    @Published private(set) var heard = ""
    @Published private(set) var reply = ""
    @Published var notice = ""
    /// Locked at every opening: from afar the phone commands the Mac, so its owner is needed.
    @Published private(set) var locked = true
    private var unlocking = false
    /// The Mac screen view.
    @Published private(set) var watching = false {
        didSet { keepScreenAwake() }
    }
    @Published private(set) var screen: UIImage?
    /// The video of the Mac screen.
    private let decoder = ScreenDecoder()
    let screenSink = ScreenSink()

    /// Only the first image goes through SwiftUI: redrawing the whole view 25 times a second cost too much.
    private func show(screen image: UIImage) {
        if screen == nil || !screenSink.show(image) { screen = image }
    }
    @Published private(set) var talking = false
    /// Listening for the word "Jarvis".
    @Published private(set) var earOn = false
    @Published var earEnabled = UserDefaults.standard.object(forKey: "earEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(earEnabled, forKey: "earEnabled")
            updateEar()
        }
    }
    /// Siri or the Action button asked to listen as soon as connected.
    static var listenWhenReady = false
    private let ear = PhoneEar()
    private var speechAllowed = false
    private var askedSpeech = false
    private var gate: SilenceGate?
    private var heardWake = false
    private var listenObserver: NSObjectProtocol?
    // Only for the reactor, which is the same as the Mac's.
    let privacyMode = false
    let levels = AudioLevels()

    private let audio: PhoneAudio
    private var channel: PhoneChannel?
    private var browser: NWBrowser?
    private var found: NWEndpoint?
    private var remoteState: State = .idle
    private var active = false
    private var attempts = 0
    private var otherTurn = 0
    private var searchHint: DispatchWorkItem?
    private var retry: DispatchWorkItem?
    private var fallback: DispatchWorkItem?
    private let test = TestOptions()

    private(set) var code = Keychain.read("code") ?? ""
    private(set) var host = UserDefaults.standard.string(forKey: "host") ?? ""
    /// The Mac's Tailscale address, received the first time it connects: needed away from home.
    private var outsideHost = UserDefaults.standard.string(forKey: "outsideHost") ?? ""

    var isPaired: Bool { PhoneLink.isValid(code) }
    var isBusy: Bool { state != .idle && link != .unpaired && link != .searching && link != .elsewhere }
    var isConnected: Bool { if case .connected = link { return true } else { return false } }

    init() {
        audio = PhoneAudio(levels: levels, muted: test.muted)
        if let testCode = test.code {
            code = testCode
            host = test.host ?? host
        }
        link = isPaired ? .searching : .unpaired
        if test.code != nil { locked = false }
        audio.onBuffer = { [ear] buffer in ear.feed(buffer) }
        audio.onLevel = { [weak self] db, seconds in
            MainActor.assumeIsolated { self?.heardLevel(db, seconds) }
        }
        ear.onText = { [weak self] text in
            self?.test.log("sentito: \(text)")
            self?.earHeard(text)
        }
        ear.onEvent = { [weak self] event in self?.test.log(event) }
        ear.onUnavailable = { [weak self] in
            self?.notice = "Non riesco ad ascoltare \"Jarvis\": controlla che la Dettatura in italiano sia attiva, in Impostazioni › Generali › Tastiera."
        }
        listenObserver = NotificationCenter.default.addObserver(forName: .jarvisListen, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.listenIfAsked() }
        }
        if let days = Self.daysUntilExpiry(), days <= 2 {
            expiryNotice = days <= 0 ? "L'app scade oggi: reinstallala dal Mac." : "L'app scade tra \(days) giorni: reinstallala dal Mac."
        }
    }

    // MARK: Expiry

    /// With a free Apple account the signature lasts 7 days: better to know in advance.
    @Published private(set) var expiryNotice = ""

    private static func daysUntilExpiry() -> Int? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: Unicode.ASCII.self)
        guard let key = text.range(of: "<key>ExpirationDate</key>"),
              let open = text.range(of: "<date>", range: key.upperBound..<text.endIndex),
              let close = text.range(of: "</date>", range: open.upperBound..<text.endIndex),
              let date = ISO8601DateFormatter().date(from: String(text[open.upperBound..<close.lowerBound])) else { return nil }
        return Int(date.timeIntervalSinceNow / 86_400)
    }

    // MARK: Face ID

    func unlock() {
        guard locked, !unlocking else { return }
        let context = LAContext()
        var problem: NSError?
        // Without even a passcode on the phone there is nothing to ask.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            locked = false
            connect()
            return
        }
        unlocking = true
        Task {
            let passed = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Apri JARVIS")) ?? false
            unlocking = false
            guard passed else { return }
            locked = false
            connect()
        }
    }

    // MARK: Pairing

    func pair(code newCode: String, host newHost: String, outside: String = "") {
        if !outside.isEmpty {
            outsideHost = outside
            UserDefaults.standard.set(outside, forKey: "outsideHost")
        }
        code = PhoneLink.normalized(newCode)
        host = newHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = Keychain.save("code", code)
        UserDefaults.standard.set(host, forKey: "host")
        notice = saved ? "" : "Non riesco a salvare il codice: al prossimo avvio andrà riscritto."
        test.log(saved ? "codice salvato" : "codice NON salvato")
        disconnect()
        link = .searching
        connect()
    }

    func forget() {
        disconnect()
        code = ""
        host = ""
        outsideHost = ""
        Keychain.delete("code")
        UserDefaults.standard.removeObject(forKey: "host")
        UserDefaults.standard.removeObject(forKey: "outsideHost")
        heard = ""
        reply = ""
        link = .unpaired
    }

    // MARK: Connection

    func becameActive() {
        active = true
        if locked { unlock() } else { connect() }
    }

    func takeOver() {
        guard link == .elsewhere else { return }
        notice = ""
        connect()
    }

    func wentToBackground() {
        active = false
        if test.code == nil { locked = true }
        cancelTalking()
        updateEar()
        audio.stopPlaying()
        disconnect()
    }

    private func connect() {
        guard active, !locked, isPaired, channel == nil else { return }
        if link == .elsewhere { notice = "" }
        if link != .refused { link = .searching }
        if !isBusy { state = .booting("") }
        attempts += 1
        scheduleSearchHint()
        guard let port = NWEndpoint.Port(rawValue: PhoneLink.port) else { return }
        let manual = host.isEmpty ? nil : NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
        // Tests on the simulator stay inside the Mac, without searching the network.
        if test.host != nil, let manual {
            open(manual)
            return
        }
        startBrowsing()
        // Routes besides the local network search: Tailscale first, which also works on 4G.
        let outside = outsideHost.isEmpty ? nil : NWEndpoint.hostPort(host: NWEndpoint.Host(outsideHost), port: port)
        let others = [outside, manual].compactMap { $0 }
        // A failed attempt is followed by the other route, if there is one.
        if let found, others.isEmpty || attempts % 2 == 1 {
            open(found)
            return
        }
        // If the search finds nothing, the other addresses are tried in turn.
        guard !others.isEmpty else { return }
        let target = others[otherTurn % others.count]
        otherTurn += 1
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.channel == nil else { return }
                self.open(target)
            }
        }
        fallback?.cancel()
        fallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (test.host == nil ? 2 : 0.2), execute: work)
    }

    /// After a while it says why, instead of just "cerco il Mac".
    private func scheduleSearchHint() {
        guard searchHint == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.searchHint = nil
                guard !self.isConnected, self.link != .refused else { return }
                self.notice = self.outsideHost.isEmpty
                    ? "Manca l'indirizzo per uscire di casa: collegati una volta in Wi-Fi a casa, poi funziona anche in 4G."
                    : "Non raggiungo il Mac: può essere in stop, con il coperchio chiuso, o con Tailscale spento."
            }
        }
        searchHint = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    private func startBrowsing() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: PhoneLink.serviceType, domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.found = results.first?.endpoint
                if self.found != nil, self.channel == nil, self.active { self.connect() }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func open(_ endpoint: NWEndpoint) {
        guard channel == nil, active else { return }
        fallback?.cancel()
        let channel = PhoneChannel(NWConnection(to: endpoint, using: PhoneLink.parameters(code: code)))
        self.channel = channel
        test.log("collegamento verso \(endpoint)")
        // A connection can hang, for example stuck at a firewall: move on.
        var ready = false
        // From outside the first packet may go through a Tailscale relay and take longer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak channel] in
            if !ready { channel?.close() }
        }
        channel.onReady = { [weak self] in
            MainActor.assumeIsolated {
                ready = true
                self?.attempts = 0
                self?.searchHint?.cancel()
                self?.searchHint = nil
                channel.send(PhoneMessage(.hello, text: UIDevice.current.name, number: PhoneLink.version))
                self?.notice = ""
                self?.test.log("collegato")
            }
        }
        channel.onMessage = { [weak self] message in
            MainActor.assumeIsolated { self?.received(message) }
        }
        channel.onClip = { [weak self] clip in
            MainActor.assumeIsolated { self?.receivedClip(clip) }
        }
        channel.onScreen = { [weak self, weak channel] frame in
            MainActor.assumeIsolated {
                guard let self, self.watching else { return }
                if let image = UIImage(data: frame) { self.show(screen: image) }
                self.test.log("schermo: \(frame.count / 1024) KB")
                channel?.send(PhoneMessage(.frameShown))
            }
        }
        channel.onVideo = { [weak self, weak channel] packet in
            MainActor.assumeIsolated {
                guard let self, self.watching else { return }
                let usable = self.screenSink.receive(packet)
                // The first keyframe also becomes an image: it gives the view its size.
                if usable, packet.keyframe, self.screen == nil || self.screenSink.view == nil {
                    self.decoder.decode(packet) { [weak self] image in
                        guard let self, self.watching, let image, self.screen?.size != image.size else { return }
                        self.screen = image
                    }
                }
                self.test.log("video: \(packet.data.count / 1024) KB\(packet.keyframe ? " chiave" : "")\(usable ? "" : " NON usabile")")
                // The acknowledgment is sent anyway: a failed frame must not stop the view.
                channel?.send(PhoneMessage(.frameShown))
            }
        }
        channel.onClosed = { [weak self] error in
            MainActor.assumeIsolated { self?.closed(channel, error) }
        }
        channel.start()
    }

    private func disconnect() {
        retry?.cancel()
        fallback?.cancel()
        searchHint?.cancel()
        searchHint = nil
        browser?.cancel()
        browser = nil
        found = nil
        let old = channel
        channel = nil
        old?.close()
    }

    private func closed(_ old: PhoneChannel, _ error: NWError?) {
        guard channel === old else { return }
        channel = nil
        audio.stopPlaying()
        cancelTalking()
        test.log("scollegato: \(error.map { "\($0)" } ?? "nessun errore")")
        if case .tls = error {
            link = .refused
        } else if link != .refused, link != .elsewhere {
            link = .searching
        }
        state = .booting("")
        // The Mac may have changed address: start again by looking for it.
        browser?.cancel()
        browser = nil
        found = nil
        guard active, link != .elsewhere else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.connect() }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (link == .refused ? 10 : 2), execute: work)
    }

    // MARK: From the Mac

    private func received(_ message: PhoneMessage) {
        switch message.kind {
        case .welcome:
            link = .connected(message.text ?? "Mac")
            if let address = message.address, address != outsideHost {
                outsideHost = address
                UserDefaults.standard.set(address, forKey: "outsideHost")
            }
            if watching { channel?.send(PhoneMessage(.watch, number: 1)) }
            test.connected(self)
            updateEar()
            listenIfAsked()
        case .state:
            let new = Self.state(message.text)
            remoteState = new
            if !talking { state = new }
            test.log("stato \(message.text ?? "")")
            if new == .idle { test.becameIdle(self) } else { test.becameBusy() }
        case .heard:
            heard = message.text ?? ""
            test.log("capito: \(heard)")
        case .reply:
            reply = message.text ?? ""
            test.log("risposta: \(reply)")
        case .replaced:
            // Without stopping here the two devices would take the Mac from each other forever.
            link = .elsewhere
            searchHint?.cancel()
            searchHint = nil
            watching = false
            screen = nil
            notice = "JARVIS ora è in uso su un altro dispositivo."
            test.log("passato a un altro dispositivo")
        case .watchEnded:
            watching = false
            screen = nil
            notice = message.text ?? ""
        case .stopAudio:
            audio.stopPlaying()
            test.log("voce interrotta")
        case .notice:
            notice = message.text ?? ""
            test.log("avviso: \(notice)")
        default:
            break
        }
    }

    private func receivedClip(_ clip: PhoneClip) {
        test.savedClip(clip)
        // While the user speaks, JARVIS's voice does not overlap.
        guard !talking else {
            channel?.send(PhoneMessage(.played, number: Int(clip.id)))
            return
        }
        let channel = channel
        audio.play(clip) { channel?.send(PhoneMessage(.played, number: Int(clip.id))) }
    }

    private static func state(_ name: String?) -> State {
        switch name {
        case "idle": return .idle
        case "listening": return .listening
        case "transcribing": return .transcribing
        case "thinking": return .thinking
        case "acting": return .acting
        case "speaking": return .speaking
        case "error": return .error("")
        default: return .booting("")
        }
    }

    // MARK: Commands

    func startWatching() {
        guard isConnected, !watching else { return }
        notice = ""
        watching = true
        decoder.reset()
        screenSink.reset()
        channel?.send(PhoneMessage(.watch, number: 1))
    }

    /// A touch on the Mac screen: `x` and `y` from 0 to 1 on the image.
    func pointer(_ kind: String, x: Double, y: Double, amount: Int? = nil) {
        guard watching else { return }
        channel?.send(PhoneMessage(.pointer, text: kind, number: amount, x: x, y: y))
    }

    func typeOnMac(_ text: String) {
        guard watching, !text.isEmpty else { return }
        channel?.send(PhoneMessage(.typing, text: text))
    }

    func pressOnMac(_ key: String) {
        guard watching else { return }
        channel?.send(PhoneMessage(.key, text: key))
    }

    func stopWatching() {
        guard watching else { return }
        watching = false
        screen = nil
        channel?.send(PhoneMessage(.watch, number: 0))
    }

    func send(text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, isConnected else { return }
        notice = ""
        audio.stopPlaying()
        channel?.send(PhoneMessage(.command, text: clean))
    }

    func stop() {
        if talking { return cancelListening() }
        audio.stopPlaying()
        channel?.send(PhoneMessage(.stop))
    }

    // MARK: Speaking

    private var pressed = false
    private var pressStart = Date()
    private var pressWillEnd = false

    /// Tap: listens until you stop speaking, or until you tap again.
    /// Hold: listens until you release.
    func micPressed() {
        pressStart = Date()
        pressWillEnd = talking
        if !talking { startTalking() }
    }

    func micReleased() {
        pressed = false
        if pressWillEnd || Date().timeIntervalSince(pressStart) > 0.6 { finishTalking() }
    }

    func startTalking() {
        guard isConnected, !talking else { return }
        notice = ""
        pressed = true
        Task {
            guard await audio.askMicrophone() else {
                notice = "Serve il permesso del microfono, in Impostazioni di iOS."
                return
            }
            guard pressed || Date().timeIntervalSince(pressStart) < 0.6 else { return }
            audio.stopPlaying()
            do {
                try audio.startRecording()
                audio.playChime(loud: false)
                gate = SilenceGate(ignore: 0.45)
                heardWake = false
                talking = true
                state = .listening
            } catch {
                let code = (error as NSError).code
                print("microfono: \(error)")
                notice = "Il microfono non si avvia (errore \(code))."
            }
        }
    }

    func finishTalking() {
        guard talking else { return }
        talking = false
        let heard = gate?.heard ?? true
        gate = nil
        let samples = audio.finishRecording()
        updateEar()
        guard heard, samples.count >= 16_000 * 3 / 10 else {
            state = remoteState
            notice = "Non ho sentito nulla."
            test.log("nulla da mandare")
            return
        }
        state = .transcribing
        test.log("mando la frase: \(String(format: "%.1f", Double(samples.count) / 16_000)) s")
        channel?.send(PhoneClip(id: 0, sampleRate: 16_000, samples: samples))
    }

    /// Tap on the reactor while listening: it was not for JARVIS, nothing is sent.
    func cancelListening() {
        guard talking else { return }
        cancelTalking()
        state = remoteState
        notice = "Annullato."
        test.log("annullato")
    }

    private func cancelTalking() {
        guard talking else { return }
        talking = false
        gate = nil
        _ = audio.finishRecording()
        updateEar()
    }

    // MARK: Hands-free "Jarvis"

    private func keepScreenAwake() {
        // With listening on the screen does not turn off: with the phone locked iOS would close the microphone.
        UIApplication.shared.isIdleTimerDisabled = isBusy || watching || earOn
    }

    /// Listens only with the app in front, unlocked, connected and with JARVIS idle.
    private func updateEar() {
        let wanted = earEnabled && active && !locked && isConnected && !talking && state == .idle
        guard wanted else {
            // During the wake-up recognition is still needed, to hear "annulla".
            if !(talking && heardWake) {
                ear.stop()
                if earOn { earOn = false }
                if !talking { audio.stopMicrophone() }
            }
            return
        }
        guard speechAllowed else {
            guard !askedSpeech else { return }
            askedSpeech = true
            Task {
                let microphone = await audio.askMicrophone()
                let speech = await PhoneEar.askPermission()
                speechAllowed = microphone && speech
                test.log("permessi ascolto: \(speechAllowed)")
                updateEar()
            }
            return
        }
        guard ear.isAvailable else {
            test.log("riconoscimento sul telefono non disponibile")
            return
        }
        do {
            try audio.startMicrophone()
            if !ear.running { ear.start() }
            if !earOn { earOn = true }
            test.log("orecchio acceso")
            keepScreenAwake()
        } catch {
            test.log("microfono non avviato: \(error)")
        }
    }

    private func earHeard(_ text: String) {
        guard let tail = WakeWord.tail(text) else { return }
        if talking, heardWake {
            guard !tail.isEmpty else { return }
            if WakeWord.wantsCancel(tail) { cancelListening() } else { gate?.markSpeech() }
            return
        }
        guard !talking, state == .idle, isConnected else { return }
        test.log("sveglia: \(text)")
        wake(said: !tail.isEmpty)
    }

    private func wake(said: Bool) {
        do {
            // What was said before the name was noticed is kept: Whisper on the Mac rereads everything.
            try audio.startRecording(earlier: 2.5)
        } catch {
            notice = "Il microfono non si avvia."
            return
        }
        notice = ""
        audio.stopPlaying()
        audio.playChime(loud: true)
        gate = SilenceGate(ignore: 0.45)
        if said { gate?.markSpeech() }
        heardWake = true
        talking = true
        state = .listening
        ear.restart()
    }

    private func heardLevel(_ db: Float, _ seconds: Double) {
        guard talking, let outcome = gate?.feed(db: db, seconds: seconds) else { return }
        switch outcome {
        case .going: break
        case .ended: finishTalking()
        case .nothing: finishTalking()
        }
    }

    private func listenIfAsked() {
        guard Self.listenWhenReady, isConnected, !locked, !talking else { return }
        Self.listenWhenReady = false
        pressStart = Date()
        startTalking()
    }

    /// Only for simulator tests: there is no recogniser, so it says what it would have understood.
    func testEarHeard(_ text: String) {
        test.log("sentito: \(text)")
        earHeard(text)
    }

    /// Only for simulator tests.
    func testHearFile(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        audio.testFeed(buffer, converter: converter)
    }

    // MARK: Simulator tests only

    func sendTestAudio(_ samples: [Float]) {
        channel?.send(PhoneClip(id: 0, sampleRate: 16_000, samples: samples))
    }
}

/// The code lives in the phone's keychain and never leaves the device.
enum Keychain {
    private static func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "jarvis", kSecAttrAccount as String: name]
    }

    static func read(_ name: String) -> String? {
        var q = query(name)
        q[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ name: String, _ value: String) -> Bool {
        delete(name)
        var q = query(name)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ name: String) {
        SecItemDelete(query(name) as CFDictionary)
    }
}
