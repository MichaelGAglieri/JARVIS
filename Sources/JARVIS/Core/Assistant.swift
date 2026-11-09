import AppKit
import AVFoundation
import Carbon
import Combine
import Network

/// The app's brain: holds the state, connects microphone, Whisper,
/// language model and voice, and decides what to do on every event.
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
            case .booting: return ("AVVIO SISTEMI", "BOOTING")
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

    /// Who is answering right now: the HUD lights LOCALE or CLAUDE accordingly,
    /// also when Claude answers instead of the local model (memory full,
    /// "chiedi a Claude…", local model unavailable).
    @Published private(set) var answering: Brain?
    /// Chosen Claude model (haiku, sonnet, opus).
    var claudeModel: String { config.claudeModel }

    @Published private(set) var state: State = .booting("Inizializzazione") {
        didSet {
            guard state != oldValue else { return }
            pipeline.bargeIn = (state == .speaking || state == .acting) && config.bargeIn && !answeringPhone
            if state == .idle {
                answering = nil
                // Once the phone's answer is over, the Mac's alerts go back to the speakers.
                endPhoneRequest()
                // Outside didSet: an alert changes the state again.
                DispatchQueue.main.async { [weak self] in self?.initiative.becameIdle() }
            }
            deepIdleTask?.cancel()
            if deepIdle { deepIdle = false }
            guard state == .idle else { return }
            deepIdleTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, self?.state == .idle else { return }
                self?.deepIdle = true
            }
        }
    }
    /// True after a minute of waiting: the HUD slows its animation to save power.
    @Published private(set) var deepIdle = false
    private var deepIdleTask: Task<Void, Never>?
    /// One exchange of the conversation shown in the HUD's history.
    struct Exchange: Identifiable {
        let id = UUID()
        var user: String
        var reply: String
    }

    /// History shown in the CANALE VOCALE panel (the last 200 characters).
    @Published private(set) var conversation: [Exchange] = []
    /// Last phrase heard: each new phrase opens an exchange in the history.
    @Published private(set) var heard = "" {
        didSet {
            guard !heard.isEmpty else { return }
            conversation.append(Exchange(user: heard, reply: ""))
            if conversation.count > 200 { conversation.removeFirst(conversation.count - 200) }
        }
    }
    /// Answer in progress: updates the latest exchange while it is written.
    @Published private(set) var reply = "" {
        didSet {
            guard !reply.isEmpty else { return }
            if conversation.isEmpty { conversation.append(Exchange(user: "", reply: "")) }
            conversation[conversation.count - 1].reply = reply
        }
    }
    @Published private(set) var language: Language = .italian
    @Published private(set) var wakeStatus = "—"
    @Published private(set) var sttStatus = "—"
    @Published private(set) var brainStatus = "—"
    @Published private(set) var voiceStatus = "—"
    @Published private(set) var brain: Brain = .local
    @Published private(set) var claudeStatus = "—"
    @Published private(set) var log: [String] = []
    /// False when the HUD is hidden or covered: the animation stops.
    @Published var hudVisible = true
    /// True when the compact reactor is visible.
    @Published var compactVisible = false

    let levels = AudioLevels()
    let phoneBridge = PhoneBridge()
    @Published private(set) var config = JarvisConfig.load()

    private let pipeline = VoicePipeline()
    private let transcriber = Transcriber()
    private let speech = SpeechEngine()
    let voicePrint = VoicePrint()
    let voiceEnrollment = VoiceEnrollment()
    private lazy var ollama: OllamaClient = {
        let client = OllamaClient(baseURL: config.ollamaURL, model: config.localModel)
        client.keepAlive = config.modelKeepAlive
        return client
    }()
    private var preloading = false

    /// Recent conversation: each turn holds the question, any tool calls
    /// with their results, and the final answer.
    private var turns: [[ChatMessage]] = []
    let memory = MemoryStore()
    let activity = ActivityTracker()
    private lazy var tools = ToolBox(memory: memory, activity: activity)
    private let claude = ClaudeBridge()
    private let mcp = MCPServer()
    /// Action waiting for a spoken "yes" (e.g. sending an email).
    private var pending: PendingAction? {
        didSet { pendingFromPhone = pending != nil && tools.currentSource.contains("iphone") }
    }
    /// Whoever asked for the action confirms it: a "yes" from the other side must not count by mistake.
    private var pendingFromPhone = false
    private var responseTask: Task<Void, Never>?
    private var currentReplyMentionsName = false
    private var generating = false
    private var hotKey: HotKey?
    private var privacyKey: HotKey?
    /// Privacy mode: microphone off, no camera and no screen.
    /// You leave it only from the keyboard (⌃⌥P) or the menu, never by voice.
    @Published private(set) var privacyMode = false

    // MARK: Start-up

    func boot() {
        Security.protectDataDirectory()
        speech.rate = config.speechRate
        configureNeuralVoice(config)
        speech.englishVoiceName = config.englishVoice
        speech.italianVoiceName = config.italianVoice
        speech.onLevel = { [weak self] in self?.levels.voice = $0 }
        speech.onFinished = { [weak self] in
            self?.lastSpeechEnd = Date()
            self?.speechFinished()
        }
        voiceStatus = "IT \(speech.voiceDescription(for: .italian)) / EN \(speech.voiceDescription(for: .english))"

        pipeline.onLevel = { [weak self] in self?.levels.mic = $0 }
        pipeline.onWake = { [weak self] in self?.wakeDetected() }
        pipeline.onUtterance = { [weak self] samples, check, final in
            self?.utteranceCaptured(samples, needsWakeCheck: check, pauseFinal: final)
        }
        pipeline.onPause = { [weak self] samples in self?.transcribeEarly(samples) }
        pipeline.onNothingHeard = { [weak self] in self?.nothingHeard() }
        pipeline.onSpeechSegment = { [weak self] samples in self?.speechSegment(samples) }

        hotKey = HotKey { [weak self] in self?.pushToTalk() }
        privacyKey = HotKey(keyCode: kVK_ANSI_P) { [weak self] in self?.togglePrivacy() }
        tools.onTimer = { [weak self] label, lang in self?.timerFired(label, language: lang) }
        tools.robotConsole.onEvent = { [weak self] text in self?.robotEvent(text) }
        installDebugHooks()
        setUpClaude()
        watchConnection()
        setUpInitiative()
        memoryGuard.start(threshold: { [weak self] in self?.config.memoryUnloadBelow ?? 20 }) { [weak self] reason in
            self?.memoryLow(reason)
        }

        Task { await bootSequence() }
    }

    private func bootSequence() async {
        // The neural voice starts in parallel with the rest (a few seconds).
        let neuralVoice = Task { await startNeuralVoice() }
        state = .booting("Microfono")
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            state = .error("Accesso al microfono negato: abilitalo in Impostazioni > Privacy > Microfono")
            return
        }
        // At login the microphone may not be ready yet: try again.
        let micReady = await retrying("Microfono") { [self] in
            pipeline.wantsEchoCancellation = config.echoCancellation
            let wakeError = try pipeline.start(accessKey: config.picovoiceAccessKey, sensitivity: config.wakeSensitivity)
            updateWakeStatus(error: wakeError)
        }
        guard micReady else { return scheduleRecovery() }

        state = .booting("Cervello locale")
        await ensureOllama()

        sttStatus = "CARICAMENTO…"
        let whisperReady = await retrying("Riconoscimento vocale") { [self] in
            if await transcriber.isReady { return }
            await transcriber.setVocabulary(config.vocabulary)
            try await transcriber.load(model: config.whisperModel) { p in
                Task { @MainActor [weak self] in
                    self?.state = .booting(p < 1 ? "Download Whisper \(Int(p * 100))%" : "Ottimizzazione per il Neural Engine")
                }
            }
        }
        guard whisperReady else {
            sttStatus = "ERRORE"
            return scheduleRecovery()
        }
        sttStatus = "WHISPER TURBO · ANE"

        await setUpWhisperWake()
        await neuralVoice.value
        state = .idle
        note("Sistemi operativi")
        // After an update made at night the app reopens without speaking.
        if config.greetOnLaunch, !CommandLine.arguments.contains("--no-greeting") { greet() }
    }

    /// Runs a start-up step, retrying up to 6 times, every 10 seconds.
    /// At login network, microphone and Neural Engine can arrive a few seconds
    /// late: instead of staying in error, JARVIS waits and retries.
    private func retrying(_ step: String, _ work: () async throws -> Void) async -> Bool {
        for attempt in 1...6 {
            state = .booting(attempt == 1 ? step : "\(step): tentativo \(attempt) di 6")
            do {
                try await work()
                return true
            } catch {
                note("\(step): \(error.localizedDescription)")
                if attempt == 6 {
                    state = .error("\(step): \(error.localizedDescription)")
                    return false
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
        return false
    }

    /// After a start-up error, start over every minute until it works.
    private func scheduleRecovery() {
        note("Nuovo tentativo di avvio tra un minuto")
        Task {
            try? await Task.sleep(for: .seconds(60))
            guard state.isError else { return }
            pipeline.stop()
            await bootSequence()
        }
    }

    private func ensureOllama() async {
        if !(await ollama.isReachable()) {
            // Ollama installed with Homebrew does not start by itself: we start it.
            for path in ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"] where FileManager.default.fileExists(atPath: path) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = ["serve"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                break
            }
            for _ in 0..<20 where !(await ollama.isReachable()) {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        guard await ollama.isReachable() else {
            brainStatus = "OLLAMA OFFLINE"
            return
        }
        guard await ollama.hasModel() else {
            brainStatus = "MODELLO \(config.localModel.uppercased()) MANCANTE"
            return
        }
        brainStatus = "LOCALE · \(config.localModel.uppercased())"
        // With Claude as the brain, Gemma stays out of RAM even if the network is not
        // ready at start-up: if it is really missing, it loads on the first call.
        guard brain == .local else { return }
        brainStatus = "PRERISCALDAMENTO…"
        // In parallel with loading Whisper: start-up does not wait for the model.
        Task {
            await ollama.warmUp(system: Persona.systemPrompt(config: config, memory: ""), tools: tools.localDefinitions)
            brainStatus = "LOCALE · \(config.localModel.uppercased())"
        }
    }

    private func updateWakeStatus(error: String?) {
        if pipeline.wakeWordReady {
            wakeStatus = "\"JARVIS\" ATTIVA"
        } else if pipeline.listensForSpeech {
            wakeStatus = "\"JARVIS\" ATTIVA · WHISPER"
        } else if config.picovoiceAccessKey.isEmpty {
            wakeStatus = "CHIAVE MANCANTE · ⌃⌥SPAZIO"
        } else {
            wakeStatus = "ERRORE · ⌃⌥SPAZIO"
            if let error { note(error) }
        }
    }

    /// For messages JARVIS says on its own initiative (greeting, timers).
    private func startStandaloneExchange() {
        conversation.append(Exchange(user: "", reply: ""))
    }

    private func greet() {
        startStandaloneExchange()
        let hour = Calendar.current.component(.hour, from: Date())
        let salute = (5..<13).contains(hour) ? "Buongiorno" : (13..<18).contains(hour) ? "Buon pomeriggio" : "Buonasera"
        let text = "\(salute), signore. Tutti i sistemi sono operativi."
        reply = text
        state = .speaking
        speech.speak(text, language: .italian)
    }

    // MARK: Voice events

    private func wakeDetected() {
        guard !privacyMode else { return }
        switch state {
        case .idle:
            startListening(afterWake: true)
        case .speaking where !currentReplyMentionsName, .thinking:
            // "Jarvis" while it is answering: interrupt it and listen.
            interrupt()
            startListening(afterWake: true)
        default:
            break
        }
    }

    // MARK: Privacy

    func togglePrivacy() { setPrivacy(!privacyMode) }

    func setPrivacy(_ on: Bool) {
        guard on != privacyMode else { return }
        privacyMode = on
        tools.privacyMode = on
        if on { phoneBridge.stopWatching(reason: "Sul Mac è attiva la modalità privacy: lo schermo non si vede.") }
        // Claude remembers refusals: without this note it would not try again.
        notesForClaude.append(on ? "Privacy mode is now on." : "Privacy mode is now off: tools blocked by it work again.")
        Security.audit(on ? "privacy attivata" : "privacy disattivata", tool: "privacy", source: "tastiera o voce")
        if on {
            interrupt()
            pipeline.stop()          // microphone really off (the macOS indicator disappears)
            state = .idle
            note("Modalità privacy: microfono, fotocamera e schermo disattivati")
        } else {
            do {
                _ = try pipeline.start(accessKey: config.picovoiceAccessKey, sensitivity: config.wakeSensitivity)
                note("Modalità privacy terminata: microfono riattivato")
                speech.playChime()
            } catch {
                note("Microfono non riattivato: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Continuous listening with Whisper

    private var checkingWake = false
    private var waitingSegment: [Float]?
    /// When JARVIS finished speaking: phrases heard while it spoke are
    /// its own voice picked up by the microphone, not commands.
    private var lastSpeechEnd = Date.distantPast
    private var firstSentencePending = false
    private var lastAcknowledgment: String?
    /// The acknowledgment was already said: if the model repeats it, it is not read twice.
    private var skipRepeatedAcknowledgment = false
    private var stillWorkingReminder: Task<Void, Never>?

    /// Without Porcupine "Jarvis" is recognised by a small Whisper: it is free
    /// and reacts only to the real word, not to similar sounds.
    private func setUpWhisperWake() async {
        guard config.whisperWake, !pipeline.wakeWordReady else {
            pipeline.listensForSpeech = false
            updateWakeStatus(error: nil)
            return
        }
        state = .booting("Ascolto di \"Jarvis\"")
        do {
            if !(await transcriber.wakeReady) { try await transcriber.loadWakeModel() }
            pipeline.listensForSpeech = true
        } catch {
            note("Ascolto continuo non disponibile: \(error.localizedDescription)")
        }
        updateWakeStatus(error: nil)
    }

    /// The last short, loud phrase in which "Jarvis" was not heard: if the next one
    /// arrives right after, the two are listened to again together.
    private var rejectedSegment: (samples: [Float], end: Date)?
    private var waitingSegmentEnd: Date?
    /// How the first pass understood the phrase: sometimes it is right exactly where
    /// the full transcription is wrong ("avrei whatsapp" versus "avrighozzotto").
    private var alternativeTranscript: String?
    /// The whole phrase when "Jarvis" was in the middle of it: perhaps he was talking about JARVIS to someone else.
    private var namedMidPhrase: String?
    /// This answer may be just `silentReply`: JARVIS then says nothing.
    private var silenceAllowed = false
    private static let silentReply = "SILENZIO"

    /// Someone who pauses after "Jarvis" is split into two phrases, and a lone "Jarvis"
    /// can come out of Whisper empty: the command was lost and had to be repeated.
    private func joinedWithRejected(_ samples: [Float], peak: Float, end: Date) -> [Float]? {
        let previous = rejectedSegment
        // Only voice close to the microphone: the TV stays below this level and costs nothing.
        let loud = peak >= 0.056
        rejectedSegment = loud && samples.count <= 40_000 ? (samples, end) : nil
        guard loud, let previous else { return nil }
        let start = end.addingTimeInterval(-Double(samples.count) / 16_000)
        guard start.timeIntervalSince(previous.end) <= 1.2 else { return nil }
        rejectedSegment = nil
        return previous.samples + samples
    }

    /// A phrase said near the Mac while JARVIS is waiting: does it contain "Jarvis"?
    private func speechSegment(_ original: [Float], end: Date = Date()) {
        var samples = original
        // Even while it works silently: "basta" must stop a sequence of actions.
        if isBusy {
            bargeInCheck(samples)
            return
        }
        guard state == .idle, !privacyMode else { return }
        // The phrase started before JARVIS finished speaking (plus 0.6 s of
        // final silence and a margin): it contains its voice, ignore it.
        let segmentStart = Date().addingTimeInterval(-Double(samples.count) / 16_000 - 0.3)
        guard testInjection || segmentStart > lastSpeechEnd else {
            Diagnostics.log("wake --   frase sovrapposta alla voce di JARVIS, ignorata")
            return
        }
        // If a check is still running the phrase is not thrown away: keep
        // the latest one and check it right after (before, "Jarvis" got lost).
        guard !checkingWake else {
            waitingSegment = samples
            waitingSegmentEnd = end
            return
        }
        checkingWake = true
        let start = Date()
        Task {
            defer {
                checkingWake = false
                if let next = waitingSegment {
                    waitingSegment = nil
                    speechSegment(next, end: waitingSegmentEnd ?? Date())
                }
            }
            let seconds = String(format: "%.1f s", Double(samples.count) / 16_000)
            guard var text = await transcriber.wakeTranscript(samples) else { return }
            if voiceEnrollment.isActive {
                await enroll(samples, heard: text)
                return
            }
            if state == .idle, WakeVerifier.command(from: text) == nil, WakeVerifier.isSoundalike(text), samples.count <= 40_000,
               await soundalikeAccepted(samples, heard: text), state == .idle {
                Diagnostics.log("wake OK   [\(seconds), \(Diagnostics.since(start))] somiglia e la voce è sua: \"\(text)\"")
                waitingSegment = nil
                startListening(afterWake: false, lookback: Date().timeIntervalSince(start), checkVoice: true)
                return
            }
            if state == .idle, WakeVerifier.command(from: text) == nil {
                // The level tells a muted microphone from Whisper not understanding.
                let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
                Diagnostics.log("wake NO   [\(seconds), \(Diagnostics.since(start)), picco \(String(format: "%.0f", 20 * log10(max(peak, 1e-7)))) dB] \"\(text)\"")
                guard let joined = joinedWithRejected(samples, peak: peak, end: end),
                      let joinedText = await transcriber.wakeTranscript(joined),
                      WakeVerifier.command(from: joinedText) != nil else { return }
                Diagnostics.log("wake unite [due frasi di seguito] \"\(joinedText)\"")
                samples = joined
                text = joinedText
            }
            guard state == .idle else { return }
            rejectedSegment = nil
            Diagnostics.log("wake OK   [\(seconds), \(Diagnostics.since(start))] \"\(text)\"")
            guard await voiceAccepted(samples, heard: text), state == .idle else {
                Diagnostics.log("wake --   voce non riconosciuta, ignorata")
                return
            }
            waitingSegment = nil
            // Just "Jarvis": beep and listen at once, without transcribing again or speaking.
            if WakeVerifier.command(from: text)?.isEmpty == true {
                Diagnostics.log("ascolto   subito dopo il beep")
                startListening(afterWake: false, lookback: Date().timeIntervalSince(start), checkVoice: true)
                return
            }
            Diagnostics.requestStart = Date()
            initiative.activated()
            NotificationCenter.default.post(name: .jarvisActivated, object: nil)
            speech.playChime()
            state = .listening
            // The local model reloads while the large Whisper transcribes.
            preloadModelIfNeeded()
            alternativeTranscript = text
            // The large Whisper transcribes the whole phrase again and extracts the command
            // (or answers "Sì, signore?" and listens).
            utteranceCaptured(samples, needsWakeCheck: true, wakeConfirmed: true)
        }
    }

    // MARK: Voiceprint

    /// Compares the voice of whoever said "Jarvis" with the enrolled one. In trial
    /// ("observe") it only measures. If the check fails JARVIS answers
    /// anyway: a fault must not make it deaf.
    /// `strict`: only similarity counts, even when the check is observe-only.
    private func voiceAccepted(_ samples: [Float], heard: String, isCommand: Bool = false, isAnswer: Bool = false, strict: Bool = false) async -> Bool {
        guard config.voiceCheck != "off", voicePrint.isEnrolled else { return true }
        do {
            var score = voicePrint.score(try await speech.kokoro.embedding(samples))
            let whole = score
            // With TV or music the window is mostly them: look for the second most similar
            // to the user's voice. Not in silence: a whole phrase is already a better check.
            let noise = Self.noiseFloor(samples)
            // A long window in which Whisper finds only "Jarvis" is full of something else: TV or music,
            // even if there was a pause at the start and the measured noise looks low.
            // Not for commands: there a few words followed by a pause are normal.
            let longAndEmpty = !isCommand && samples.count >= 48_000 && heard.split(separator: " ").count <= 3
            let noisy = noise > Self.noisyFloor || longAndEmpty
            // Noise lowers the scores of every voice. Long windows and commands need more
            // similarity, because the windows also give other voices more chances.
            let noisyLimit = samples.count <= 40_000 && !isCommand ? Self.noisyThreshold : Self.noisyLongThreshold
            // An answer to one of its questions is short and comes a few seconds later: "Un minuto" scored 0.39 and 0.41.
            let threshold = isAnswer ? min(config.voiceThreshold, Self.answerThreshold)
                : noisy ? min(config.voiceThreshold, noisyLimit) : config.voiceThreshold
            if noisy, samples.count > Self.window {
                for start in stride(from: 0, through: samples.count - Self.window, by: Self.window / 3) where score < threshold {
                    let piece = Array(samples[start..<start + Self.window])
                    score = max(score, voicePrint.score(try await speech.kokoro.embedding(piece)))
                }
            }
            let passed = score >= threshold
            Diagnostics.logVoice(String(format: "%.3f %@ %@ [%.1f s] intera %.3f rumore %.0f dB soglia %.2f ",
                                        score, passed ? "sì" : "no", config.voiceCheck, Double(samples.count) / 16_000,
                                        whole, noise, threshold) + (isAnswer ? "risposta " : isCommand ? "comando " : "") + "\"\(heard)\"")
            return passed || (!strict && config.voiceCheck != "on")
        } catch {
            Diagnostics.log("impronta vocale non disponibile: \(error)")
            return true
        }
    }

    /// Above this background noise (TV, music) the lower thresholds apply, to be calibrated with voce.log.
    private static let noisyFloor: Float = -45
    private static let noisyThreshold: Float = 0.33
    private static let noisyLongThreshold: Float = 0.40
    private static let answerThreshold: Float = 0.33
    /// Window of the check in noise: about the length of "Jarvis" plus a margin (0.9 s).
    private static let window = 14_400

    /// Background noise: the typical level before someone starts speaking (the first 0.4 s).
    /// Not measured on the rest: a long phrase said in silence is not noise.
    private static func noiseFloor(_ samples: [Float]) -> Float {
        let frames = stride(from: 0, to: min(samples.count, 6_400) - 319, by: 320).map { start -> Float in
            let energy = samples[start..<start + 320].reduce(Float(0)) { $0 + $1 * $1 } / 320
            return 10 * log10(max(energy, 1e-12))
        }.sorted()
        return frames.isEmpty ? -100 : frames[frames.count / 2]
    }

    /// "Già l'ho visto" wakes JARVIS only if the user says it: it needs the voiceprint, and the
    /// threshold does not go below 0.45 (the other voices measured stay below 0.33).
    private func soundalikeAccepted(_ samples: [Float], heard: String) async -> Bool {
        guard config.voiceCheck != "off", voicePrint.isEnrolled,
              let embedding = try? await speech.kokoro.embedding(samples) else { return false }
        let score = voicePrint.score(embedding)
        let passed = score >= max(0.45, config.voiceCheck == "on" ? config.voiceThreshold : 0)
        Diagnostics.logVoice(String(format: "%.3f %@ somiglia [%.1f s] ", score, passed ? "sì" : "no",
                                    Double(samples.count) / 16_000) + "\"\(heard)\"")
        return passed
    }

    func startVoiceEnrollment(adding: Bool = false, commands: Bool = false) {
        voiceEnrollment.start(adding: adding, commands: commands)
        if !config.whisperWake {
            voiceEnrollment.stop("Serve l'ascolto continuo di \"Jarvis\": attivalo in Attivazione e riprova.")
        } else if privacyMode {
            voiceEnrollment.stop("JARVIS è in modalità privacy: il microfono è spento.")
        }
    }

    func deleteVoicePrint() {
        voicePrint.delete()
        try? FileManager.default.removeItem(at: JarvisConfig.directory.appendingPathComponent("voce.log"))
    }

    /// An enrolment phrase: kept only if it really contains "Jarvis" or the command read.
    private func enroll(_ samples: [Float], heard: String) async {
        Diagnostics.log("registrazione voce: frase \(voiceEnrollment.step + 1), sentito \"\(heard)\"")
        guard voiceEnrollment.accepts(heard) else {
            Diagnostics.log("registrazione voce: frase rifiutata")
            voiceEnrollment.refused()
            if voiceEnrollment.isFinished { finishEnrollment() }
            return
        }
        guard let embedding = try? await speech.kokoro.embedding(samples) else {
            voiceEnrollment.stop("Il modello dell'impronta vocale non è disponibile: esegui scripts/setup_tts.sh.")
            return
        }
        guard voiceEnrollment.isActive else { return }
        Diagnostics.log("registrazione voce: frase tenuta")
        voiceEnrollment.accept(embedding)
        speech.playChime()
        if voiceEnrollment.isFinished { finishEnrollment() }
    }

    private func finishEnrollment() {
        guard !voiceEnrollment.embeddings.isEmpty else {
            voiceEnrollment.stop("Non ho capito nessuna frase: l'impronta non è cambiata.")
            return
        }
        voicePrint.save(voiceEnrollment.embeddings, adding: voiceEnrollment.adding)
        voiceEnrollment.stop("Fatto: ora ci sono \(voicePrint.samples.count) frasi registrate.")
        let scores = voicePrint.selfScores().sorted()
        Diagnostics.logVoice(String(format: "registrazione: %d frasi in tutto, somiglianza tra loro min %.3f mediana %.3f",
                                    scores.count, scores.first ?? 0, scores[scores.count / 2]))
    }

    // MARK: Voice interruption (phase 4)

    private var isBusy: Bool { state == .speaking || state == .acting || state == .thinking || speech.isSpeaking }

    private var checkingBargeIn = false

    /// While JARVIS speaks, each chunk of audio (2 s) is quickly transcribed:
    /// "(Jarvis,) basta", "stop", "fermati", "zitto" interrupt it. Its own
    /// voice does not stop it: if the words heard are in the sentence it is saying,
    /// they are the speakers' echo.
    private func bargeInCheck(_ samples: [Float]) {
        guard config.bargeIn, !privacyMode, !checkingBargeIn else { return }
        checkingBargeIn = true
        let start = Date()
        Task {
            defer { checkingBargeIn = false }
            guard let text = await transcriber.quickTranscript(samples) else { return }
            let heard = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            let words = heard.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
            let stopWords = ["basta", "stop", "fermati", "zitto", "silenzio", "smettila", "enough"]
            let spoken = reply.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            let saidStop = words.contains { stopWords.contains($0) && !spoken.contains($0) }
            // Over its voice, "Jarvis" is often lost: the stop word alone is enough,
            // if it is not among the words JARVIS is saying (that would be its echo).
            guard saidStop, isBusy else {
                if !words.isEmpty { Diagnostics.log("basta? no [\(Diagnostics.since(start))] \"\(text)\"") }
                return
            }
            Diagnostics.log("basta OK  [\(Diagnostics.since(start))] \"\(text)\"")
            note("Interrotto a voce")
            pending = nil
            interrupt()
            state = .idle
            speech.playChime(rising: false)
            // Also stops connected robots, like "basta" said while waiting.
            let stopped = await emergencyStop()
            if !stopped.isEmpty { note(stopped.joined(separator: " · ")) }
        }
    }

    /// Early transcription at the phrase's first pause.
    private var earlyTranscript: Task<(text: String, language: Language), Error>?

    private func transcribeEarly(_ samples: [Float]) {
        guard state == .listening else { return }
        earlyTranscript = Task { try await transcriber.transcribe(samples) }
    }

    /// ⌃⌥Space shortcut: speak without the wake word, or interrupt.
    func pushToTalk() {
        guard !privacyMode else { return }
        switch state {
        case .idle:
            startListening(afterWake: false)
        case .listening:
            pipeline.cancelCapture()
            state = .idle
        case .speaking, .thinking, .transcribing:
            interrupt()
            state = .idle
        default:
            break
        }
    }

    /// `checkVoice`: the phrase after the beep must also be the user's (with the TV on
    /// it would otherwise become a command). Not for the shortcut, which is always the user's.
    private func startListening(afterWake: Bool, followUp: Bool = false, lookback: Double = 0, checkVoice: Bool = false, isAnswer: Bool = false, startTimeout: Double? = nil) {
        // Someone is speaking to the Mac: the answer is for the Mac too.
        endPhoneRequest()
        commandNeedsVoice = checkVoice
        commandIsAnswer = isAnswer
        state = .listening
        if !followUp {
            initiative.activated()
            speech.playChime()
        }
        NotificationCenter.default.post(name: .jarvisActivated, object: nil)
        pipeline.beginCapture(afterWake: afterWake, strict: followUp, timeout: startTimeout ?? (followUp ? 4 : 6), lookback: lookback)
        preloadModelIfNeeded()
    }

    // MARK: Initiative

    private let initiative = Initiative()
    let printer = BambuPrinter()
    private lazy var notesIndex = NotesIndexRunner { [weak self] in self?.config.notesFolders ?? [] }
    private lazy var printerControl = BambuStudioControl(printer: printer, appControl: tools.appControl)
    private var commandNeedsVoice = false
    private var commandIsAnswer = false

    /// "Scarica Gemma dalla memoria": the model stays on disk and reloads when needed.
    private func unloadLocalModel() async -> String {
        guard await ollama.isLoaded() else { return "Gemma non è in memoria, signore." }
        await ollama.unload()
        note("Gemma scaricato dalla memoria")
        Diagnostics.log("memoria   Gemma scaricato su richiesta")
        return "Fatto, signore: Gemma è fuori dalla memoria."
    }

    /// Whisper also writes "Gemma" as "Gennaro" or "Gemma 412B".
    private static func isUnloadModelCommand(_ text: String) -> Bool {
        let t = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        guard t.split(separator: " ").count <= 10 else { return false }
        let verb = #"\b(scarica|togli|libera|rimuovi|leva|unload)\b"#
        let named = t.range(of: verb + #".*\b(gemma|gennaro)\b"#, options: .regularExpression) != nil
        let model = t.range(of: verb + #".*\b(modello|nucleo)( locale)?\b.*\b(memoria|ram)\b"#, options: .regularExpression) != nil
        return named || model
    }

    private func setUpInitiative() {
        initiative.config = { [weak self] in self?.config ?? JarvisConfig() }
        initiative.canSpeak = { [weak self] in
            guard let self else { return false }
            return state == .idle && !privacyMode && pending == nil && !generating && !checkingWake && !voiceEnrollment.isActive
        }
        initiative.announce = { [weak self] text in self?.announce(text) }
        printer.onHostFound = { [weak self] host in
            guard let self else { return }
            self.config.bambuHost = host
            self.config.save()
            self.note("Stampante ritrovata al nuovo indirizzo \(host)")
        }
        printer.onAlert = { [weak self] id, italian, english in
            guard let self else { return }
            self.initiative.alert(id: id, text: self.language == .italian ? italian : english)
        }
        tools.printerStatus = { [weak self] italian in
            guard let self else { return "" }
            await self.printer.reachNow()
            return self.printer.spokenStatus(italian: italian)
        }
        printer.maySearch = { [weak self] in
            guard let self else { return false }
            return !self.privacyMode && !self.initiative.isQuietTime
        }
        printerControl.onFinished = { [weak self] id, italian, english in
            guard let self else { return }
            self.initiative.alert(id: id, text: self.language == .italian ? italian : english)
        }
        tools.printerFilament = { [weak self] load in await self?.printerControl.filament(load: load) ?? "Non disponibile." }
        tools.printerPrint = { [weak self] model in await self?.printerControl.preparePrint(model: model) ?? .result("Non disponibile.") }
        initiative.startBriefing = { [weak self] in self?.startMorningBriefing() }
        initiative.prepareBriefing = { [weak self] in self?.tools.prepareBriefing() }
        initiative.studySession = { [weak self] in self?.activity.current }
        tools.onBriefing = { [weak self] in self?.initiative.briefingDone() }
        tools.onUnloadModel = { [weak self] in await self?.unloadLocalModel() ?? "Non disponibile." }
        tools.appControlEnabled = config.appControl
        initiative.start()
        notesIndex.start()
        setUpPhoneBridge()
    }

    /// JARVIS speaks first: appointment, reminder, study break, battery.
    private func announce(_ text: String) {
        startStandaloneExchange()
        note("Avviso: \(text)")
        NotificationCenter.default.post(name: .jarvisActivated, object: nil)
        speech.playChime(rising: false)
        language = .italian
        say(text, language: .italian)
    }

    private func startMorningBriefing() {
        note("Briefing del mattino")
        tools.currentSource = "iniziativa"
        startStandaloneExchange()
        state = .thinking
        responseTask = Task { await respond(to: "Fammi il briefing del mattino.", language: .italian) }
    }

    // MARK: Connection

    /// With internet Claude answers (the chosen brain); without, Gemma locally.
    @Published private(set) var online = true
    private let pathMonitor = NWPathMonitor()

    private func watchConnection() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.online != up else { return }
                self.online = up
                self.note(up ? "Connessione tornata: risponde Claude" : "Niente internet: risponde il nucleo locale")
                Diagnostics.log("rete      \(up ? "connesso" : "offline")")
                // Gemma does not load because the network dropped: it happens even with the Mac closed,
                // when moving. It loads when you call "Jarvis" without internet.
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "jarvis.network"))
    }

    // MARK: Memory

    private let memoryGuard = MemoryGuard()
    private var unloadingForMemory = false

    /// RAM almost full: the local model leaves memory (never in the middle of an answer).
    private func memoryLow(_ reason: String) {
        guard !generating, !preloading, !unloadingForMemory else { return }
        unloadingForMemory = true
        Task {
            defer { unloadingForMemory = false }
            guard await ollama.isLoaded() else { return }
            await ollama.unload()
            note("Memoria quasi piena: nucleo locale scaricato")
            Diagnostics.log("memoria   \(reason): modello scaricato")
        }
    }

    /// The model reloads only if at least the unload threshold stays free
    /// afterwards: otherwise the Mac would slow down and it would be removed at once.
    private var memoryTooLowForModel: Bool {
        MemoryGuard.freePercent < config.memoryUnloadBelow + MemoryGuard.modelPercent
    }

    /// After a pause the model is no longer in RAM: reload it while
    /// the user is still speaking, so the answer comes sooner.
    private func preloadModelIfNeeded() {
        guard brain == .local || !online, !preloading else { return }
        preloading = true
        Task {
            if !(await ollama.isLoaded()) {
                guard !memoryTooLowForModel else {
                    preloading = false
                    return
                }
                note("Ricarico il nucleo locale…")
                let start = Date()
                await ollama.warmUp(system: Persona.systemPrompt(config: config, memory: ""), tools: tools.localDefinitions)
                Diagnostics.log("modello   [\(Diagnostics.since(start))] ricaricato in memoria")
            }
            preloading = false
        }
    }

    private func nothingHeard() {
        if state == .listening { state = .idle }
    }

    /// It already asked to repeat the answer: the second time it is empty it does not insist.
    private var answerRepeatAsked = false

    private func utteranceCaptured(_ samples: [Float], needsWakeCheck: Bool, wakeConfirmed: Bool = false, pauseFinal: Bool = false) {
        guard state == .listening else { return }
        if pendingFromPhone { dropPendingFromOtherSide() }
        let checkVoice = commandNeedsVoice
        let isAnswer = commandIsAnswer
        commandNeedsVoice = false
        commandIsAnswer = false
        tools.currentSource = testInjection ? "test" : "voce"
        testInjection = false
        state = .transcribing
        if !wakeConfirmed { Diagnostics.requestStart = Date() }
        firstSentencePending = true
        let start = Date()
        responseTask = Task {
            do {
                // If nobody spoke after the first pause, the transcription already
                // started 0.4 s earlier: use that one.
                let early = pauseFinal ? earlyTranscript : nil
                earlyTranscript = nil
                let (text, lang): (text: String, language: Language)
                // If it is empty, redo it on the whole phrase: at the first pause Whisper may
                // have understood nothing, and the command was lost without a word.
                if let early, let value = try? await early.value, !value.text.isEmpty {
                    (text, lang) = value
                } else {
                    (text, lang) = try await transcriber.transcribe(samples, lenient: isAnswer)
                }
                guard !Task.isCancelled else { return }
                Diagnostics.log("frase     [\(Diagnostics.since(start))\(early != nil ? ", anticipata" : "")] \"\(text)\" (\(lang == .italian ? "it" : "en"))")
                var command = text
                namedMidPhrase = nil
                if needsWakeCheck {
                    if let extracted = WakeVerifier.command(from: text) {
                        command = extracted
                        if WakeVerifier.isNamedMidPhrase(text) { namedMidPhrase = text }
                    } else if wakeConfirmed, let extracted = WakeVerifier.command(from: text, loose: true) {
                        // The small Whisper already heard "Jarvis": if the large one
                        // spells it oddly ("Charvis", "Jervis") it still counts.
                        command = extracted
                    } else {
                        note("Falsa attivazione ignorata: \"\(text)\"")
                        Diagnostics.log("scartata: il controllo grande non ha trovato Jarvis")
                        state = .idle
                        return
                    }
                } else if Transcriber.isCourtesyOnly(text) {
                    state = .idle
                    return
                } else if WakeVerifier.command(from: text)?.isEmpty == true {
                    // "Jarvis" repeated while a conversation is open: just the beep, then speak.
                    startListening(afterWake: false, checkVoice: checkVoice)
                    return
                } else if checkVoice, pending == nil, !text.isEmpty {
                    // The "yes" to a confirmation stays out: a single word is too little to judge.
                    let accepted = await voiceAccepted(samples, heard: text, isCommand: true, isAnswer: isAnswer)
                    guard !Task.isCancelled else { return }
                    guard accepted else {
                        Diagnostics.log("comando   voce non riconosciuta, ignorato: \"\(text.prefix(60))\"")
                        state = .idle
                        return
                    }
                }
                // An empty transcription does not tell which language is spoken: without this
                // check, noise taken for English left JARVIS in English.
                if !text.isEmpty { language = lang }
                // Answering one of its questions (a quiz) the user spoke for more than a
                // second but nothing was understood: it says so instead of staying silent, once.
                // Only if it is the user's voice: a video in the background must not make it speak.
                if command.isEmpty, isAnswer, !needsWakeCheck, !answerRepeatAsked, samples.count > 16_000,
                   await voiceAccepted(samples, heard: "", isAnswer: true, strict: true), !Task.isCancelled {
                    answerRepeatAsked = true
                    Diagnostics.log("risposta  vuota: chiede di ripetere")
                    say(language == .italian ? "Non ho capito bene, signore. Può ripetere?" : "I didn't catch that, sir. Could you repeat?", language: language)
                    return
                }
                if !command.isEmpty { answerRepeatAsked = false }
                guard !command.isEmpty else {
                    if needsWakeCheck {
                        // Just "Jarvis": beep and keep listening.
                        heard = text
                        startListening(afterWake: false)
                    } else {
                        state = .idle
                    }
                    return
                }
                heard = command
                await respond(to: command, language: lang)
            } catch {
                note("Trascrizione: \(error.localizedDescription)")
                state = .idle
            }
        }
    }

    // MARK: Answer

    private func respond(to command: String, language lang: Language) async {
        // A new request reopens app control, unless it is a "basta".
        if Self.isStopCommand(command) || Self.isRobotStop(command) { tools.appControl.halt() } else { tools.appControl.resume() }
        if Self.isUnloadModelCommand(command) {
            say(await unloadLocalModel(), language: lang)
            return
        }
        if Self.isPrivacyCommand(command) {
            say(lang == .italian ? "Modalità privacy, signore. Per riattivarmi usi Control Opzione P."
                                 : "Privacy mode, sir. Press Control Option P to bring me back.", language: lang)
            // The microphone turns off when it has finished speaking.
            try? await Task.sleep(for: .seconds(4))
            setPrivacy(true)
            return
        }
        // STOP: also stops connected robots at once, without going through the model.
        if Self.isStopCommand(command) || Self.isRobotStop(command) {
            pending = nil
            let stopped = await emergencyStop()
            if stopped.isEmpty {
                state = .idle
            } else {
                note(stopped.joined(separator: " · "))
                say(lang == .italian ? "Fermato, signore." : "Stopped, sir.", language: lang)
            }
            return
        }
        if let action = pending {
            pending = nil
            switch Self.confirmation(command) {
            case .yes:
                state = .acting
                Security.audit("confermato", tool: "conferma", source: tools.currentSource, detail: action.summary)
                if action.secure && config.ownerCheck {
                    speech.speak(lang == .italian ? "Appoggi il dito sul Touch ID, signore." : "Touch ID please, sir.", language: lang)
                    // While waiting for the finger, the end of this sentence must not reopen listening.
                    generating = true
                    let verified = await OwnerCheck.verify(reason: String(action.summary.prefix(120)))
                    generating = false
                    Security.audit(verified ? "Touch ID riuscito" : "Touch ID non riuscito", tool: "conferma", source: tools.currentSource, detail: action.summary)
                    guard verified else {
                        notesForClaude.append("Touch ID failed for \"\(action.summary)\"; it was not executed.")
                        note("Touch ID non riuscito: azione annullata")
                        say(lang == .italian ? "Niente Touch ID: azione annullata, signore." : "No Touch ID: cancelled, sir.", language: lang)
                        return
                    }
                }
                let result = await action.run()
                note(result)
                let failed = ["Errore", "errore", "fallit", "rifiutat", "non riuscit", "occupata", "non ha iniziato", "Non trovo", "non ho premuto", "Non riesco", "non clicco"].contains { result.contains($0) }
                let text = failed ? (lang == .italian ? "Non ci sono riuscito, signore. \(result)" : "I'm afraid it failed, sir. \(result)")
                                  : (lang == .italian ? "Fatto, signore. \(result)" : "Done, sir. \(result)")
                turns.append([["role": "user", "content": Persona.turnContext(language: lang) + "\n" + command],
                              ["role": "assistant", "content": text]])
                // The "yes" does not go through Claude: it is told on the next request,
                // otherwise it keeps asking to confirm an action already done.
                notesForClaude.append("The user confirmed \"\(action.summary)\" and JARVIS executed it: \(result)")
                say(text, language: lang)
                return
            case .no:
                notesForClaude.append("The user cancelled \"\(action.summary)\"; it was not executed.")
                Security.audit("annullato", tool: "conferma", source: tools.currentSource, detail: action.summary)
                action.onCancel?()
                say(lang == .italian ? "Annullato, signore." : "Cancelled, sir.", language: lang)
                return
            case .unclear:
                break
            }
        }

        // "Ricordati che…" always goes to memory: the model is not relied upon.
        if let fact = Self.explicitMemory(command) {
            let result = memory.remember("L'utente ha detto: \(fact)")
            note(result)
            let text = result.hasPrefix("Lo sapevo")
                ? (lang == .italian ? "Lo sapevo già, signore." : "I already knew that, sir.")
                : (lang == .italian ? "Memorizzato, signore." : "Noted, sir. I'll remember that.")
            turns.append([["role": "user", "content": Persona.turnContext(language: lang) + "\n" + command],
                          ["role": "assistant", "content": text]])
            say(text, language: lang)
            return
        }
        // "chiedi a Claude…", "usa Sonnet per…": a single request to Claude
        // (with the given model), without changing the chosen brain.
        if let (question, model) = Self.claudeOneShot(command) {
            acknowledge(question, language: lang, forClaude: true)
            await respondWithClaude(question, language: lang, model: model)
            return
        }
        if let model = Self.claudeModelSwitch(command) {
            // "usa Opus": changes model and switches to Claude.
            await switchClaudeModel(to: model, language: lang, announce: false)
            await switchBrain(to: .claude, language: lang, announce: false)
            say(lang == .italian ? "Claude \(model.capitalized) pronto, signore." : "Claude \(model.capitalized) ready, sir.", language: lang)
            return
        }
        if let target = Self.brainSwitch(command) {
            await switchBrain(to: target, language: lang)
            return
        }
        let alternative = alternativeTranscript.flatMap { WakeVerifier.command(from: $0) }
        alternativeTranscript = nil
        if await runProtocol(command, language: lang) { return }
        if await runInstantCommand(command, language: lang) { return }
        if let alternative, alternative != command, await runInstantCommand(alternative, language: lang) { return }
        // "Mi sa che Jarvis ti ha dato ragione": said about JARVIS, to someone else. No acknowledgment:
        // the model reads the whole phrase and, if it is not addressed to it, answers only with silence.
        var asked = command
        if let whole = namedMidPhrase {
            asked = "[\"Jarvis\" was in the middle of what he said: \"\(whole)\". If he is talking about you to someone else, "
                + "not to you, reply with exactly \(Self.silentReply) and nothing else. If he is speaking to you, answer normally.]\n" + command
            silenceAllowed = true
        } else {
            acknowledge(command, language: lang, forClaude: brain == .claude && online)
        }
        defer { silenceAllowed = false; namedMidPhrase = nil }
        let brief = Acknowledgment.kind(of: command) == .action
        if brain == .claude && online {
            await respondWithClaude(asked, language: lang, brief: brief)
            return
        }
        // Memory almost full and model not loaded: Claude answers, if connected.
        if memoryTooLowForModel, claudeStatus.hasSuffix("COLLEGATO"), !(await ollama.isLoaded()) {
            note("Memoria quasi piena: rispondo con Claude")
            Diagnostics.log("memoria   libera al \(MemoryGuard.freePercent)%: risposta con Claude invece di ricaricare il modello")
            await respondWithClaude(asked, language: lang, brief: brief)
            return
        }
        let failedBefore = tools.failedLookups
        await respondLocally(asked, language: lang, brief: brief)
        await checkUnderstanding(command, failed: tools.failedLookups > failedBefore, language: lang)
    }

    /// Says "Subito, signore" at once while the model works; if it is slow, warns once.
    private func acknowledge(_ command: String, language lang: Language, forClaude: Bool) {
        guard let kind = Acknowledgment.kind(of: command) else { return }
        let italian = lang == .italian
        let text = Acknowledgment.phrase(kind, italian: italian, avoiding: lastAcknowledgment)
        lastAcknowledgment = text
        Diagnostics.log("conferma  [\(Diagnostics.since(Diagnostics.requestStart ?? Date())) dalla fine della frase] \"\(text)\" \(speech.hasClip(text, language: lang) ? "pronta" : "da sintetizzare")")
        skipRepeatedAcknowledgment = kind == .action
        if forClaude {
            notesForClaude.append("You have already said aloud \"\(text)\": start directly with the result, with no acknowledgment.")
        }
        speech.speak(text, language: lang)
        stillWorkingReminder?.cancel()
        stillWorkingReminder = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.generating, !self.speech.isSpeaking else { return }
            Diagnostics.log("conferma  ci mette più del previsto, avvisa")
            self.speech.speak(Acknowledgment.stillWorking(italian: italian), language: lang)
        }
    }

    /// How sure an app name must be: here no model checks the sentence again.
    private static let instantCertainty = 0.75

    /// Apps, volume and timers without the model. Goes through the same tools, so log and confirmations
    /// stay the same. If the sentence is not clear it returns false and the model decides.
    private func runProtocol(_ command: String, language lang: Language) async -> Bool {
        guard let (item, rest) = Protocols.match(command) else { return false }
        Diagnostics.log("protocollo \(item.name)")
        tools.currentLanguage = lang
        let name = rest.isEmpty ? "Studio" : rest.capitalized
        func run(_ steps: [JarvisProtocol.Step]) async -> [String] {
            var results: [String] = []
            for step in steps {
                let arguments = step.arguments.mapValues { value -> Any in
                    (value as? String)?.replacingOccurrences(of: "{resto}", with: name) ?? value
                }
                if case .result(let result) = await tools.run(ToolCall(name: step.tool, arguments: arguments)) { results.append(result) }
            }
            return results
        }
        let results = await run(item.before)
        // In "chiedi" {resto} is the rest of the phrase as said: "esegui la sequenza allineamento" → "allineamento".
        if let ask = item.ask?.replacingOccurrences(of: "{resto}", with: rest) {
            // A sequence of actions: "Procedo, signore" at once, then silence until the end.
            if item.brief { acknowledge(command, language: lang, forClaude: brain == .claude && online) }
            if brain == .claude && online { await respondWithClaude(ask, language: lang, brief: item.brief) } else { await respondLocally(ask, language: lang, brief: item.brief) }
        } else {
            say((item.reply ?? "Fatto, signore.").replacingOccurrences(of: "{esito}", with: results.first ?? "Fatto, signore."), language: lang)
        }
        // The screen turns off after the last word, but it does not wait forever.
        if !item.after.isEmpty {
            Task { [weak self] in
                for _ in 0..<360 {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self else { return }
                    if self.state == .idle, !self.speech.isSpeaking { break }
                }
                _ = await run(item.after)
            }
        }
        return true
    }

    private func runInstantCommand(_ command: String, language lang: Language) async -> Bool {
        guard let instant = InstantCommand.parse(command) else { return false }
        let italian = lang == .italian
        let sir = italian ? "signore" : "sir"
        tools.currentLanguage = lang
        func run(_ tool: String, _ arguments: [String: Any]) async -> ToolOutcome {
            await tools.run(ToolCall(name: tool, arguments: arguments))
        }
        let text: String
        // An answer with data must be said in full, even if it is not ready yet.
        var mustSayText = false
        switch instant {
        case .time:
            text = "\(InstantCommand.spokenTime(Date(), italian: italian)), \(sir)."
            mustSayText = true
        case .printerStatus:
            guard printer.isConfigured else { return false }
            await printer.reachNow()
            text = printer.spokenStatus(italian: italian)
            mustSayText = true
        case .filament(let load):
            guard printer.isConfigured, case .result(let result) = await run("printer_filament", ["action": load ? "load" : "unload"]) else { return false }
            if result.hasPrefix("Comando") {
                text = load ? (italian ? "Carico il filamento, \(sir). Lo inserisca quando il display lo chiede." : "Loading the filament, \(sir). Insert it when the display asks.")
                            : (italian ? "Scarico il filamento, \(sir). Le dico io quando sfilarlo." : "Unloading the filament, \(sir). I'll tell you when to pull it out.")
            } else {
                text = result
            }
            mustSayText = true
        case .open(let name):
            guard let url = MacActions.lookUpApp(name, sure: Self.instantCertainty).url else { return false }
            let file = url.deletingPathExtension().lastPathComponent
            guard case .result(let result) = await run("open_app", ["name": file]), result.hasPrefix("Aperta") else { return false }
            let shown = MacActions.spokenName(of: url, italian: italian)
            text = italian ? "Apro \(shown), \(sir)." : "Opening \(shown), \(sir)."
        case .close(let name):
            // First among open apps; then among all of them, because the spoken name is Italian ("calcolatrice")
            // and the open one may have an English name ("Calculator").
            let installed = MacActions.lookUpApp(name, sure: Self.instantCertainty).url?.deletingPathExtension().lastPathComponent
            guard let app = MacActions.runningApp(named: name, sure: Self.instantCertainty)
                    ?? installed.flatMap({ MacActions.runningApp(named: $0, sure: Self.instantCertainty) }) else { return false }
            switch await run("quit_app", ["name": app]) {
            case .result(let result):
                guard result.hasPrefix("Chiuse") else { return false }
                // The same name as when opening: "Calcolatrice", not "Calculator".
                let shown = MacActions.lookUpApp(app, sure: Self.instantCertainty).url.map { MacActions.spokenName(of: $0, italian: italian) } ?? app
                text = italian ? "Chiudo \(shown), \(sir)." : "Closing \(shown), \(sir)."
            case .needsConfirmation(let action):
                pending = action
                text = italian ? "\(app) ha modifiche non salvate. La chiudo, \(sir)?" : "\(app) has unsaved changes. Shall I close it, \(sir)?"
            case .image:
                return false
            }
        case .tv(let on):
            guard case .result(let result) = await run("tv", ["action": on ? "on" : "off"]) else { return false }
            text = result
            mustSayText = true
        case .music(let action):
            // With Music closed these sentences mean something else, or the model explains them.
            guard MacActions.musicIsRunning, case .result(let result) = await run("music", ["action": action.rawValue]),
                  !result.hasPrefix("Errore") else { return false }
            switch action {
            case .pause: text = italian ? "Musica in pausa, \(sir)." : "Music paused, \(sir)."
            case .play, .next, .previous, .status:
                // "(2001 Remastered Version)" in the title: not needed when spoken.
                let now = result.replacingOccurrences(of: "In riproduzione: ", with: "")
                    .replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: " — ", with: italian ? " di " : " by ")
                text = result.hasPrefix("In riproduzione") ? "\(now), \(sir)." : (italian ? "La musica è in pausa, \(sir)." : "The music is paused, \(sir).")
                mustSayText = true
            }
        case .setVolume(let level):
            guard case .result = await run("set_volume", ["level": Double(level)]) else { return false }
            text = italian ? "Volume al \(level) per cento, \(sir)." : "Volume at \(level) percent, \(sir)."
        case .changeVolume(let change):
            guard let current = await MacActions.currentVolume() else { return false }
            let level = max(0, min(100, current + change))
            guard case .result = await run("set_volume", ["level": Double(level)]) else { return false }
            text = italian ? "Volume al \(level) per cento, \(sir)." : "Volume at \(level) percent, \(sir)."
        case .mute(let on):
            guard case .result = await run("set_volume", ["mute": on]) else { return false }
            text = on ? (italian ? "Audio silenziato, \(sir)." : "Muted, \(sir).") : (italian ? "Audio riattivato, \(sir)." : "Sound back on, \(sir).")
        case .timer(let seconds, let label):
            var arguments: [String: Any] = ["seconds": Double(seconds)]
            if let label { arguments["label"] = label }
            guard case .result = await run("set_timer", arguments) else { return false }
            let duration = InstantCommand.spoken(seconds: seconds, italian: italian)
            text = italian ? "Timer di \(duration) avviato, \(sir)." : "Timer set for \(duration), \(sir)."
        }
        firstSentencePending = false
        // Answers while the action happens: if the sentence with the name is not ready yet,
        // this time it says a ready-made acknowledgment and prepares the other for next time.
        var spoken = text
        var prepared = true
        if pending == nil, !mustSayText, !(await speech.readyToSay(text, language: lang)) {
            prepared = false
            spoken = Acknowledgment.phrase(.action, italian: italian, avoiding: nil)
            Task { await speech.prepareClips([(text, italian)]) }
        }
        Diagnostics.log("istantaneo [\(Diagnostics.since(Diagnostics.requestStart ?? Date())) dalla fine della frase\(prepared ? "" : ", frase da preparare")] \"\(command)\"")
        turns.append([["role": "user", "content": Persona.turnContext(language: lang) + "\n" + command],
                      ["role": "assistant", "content": text]])
        // Claude did not see this action: it is told on the next request.
        notesForClaude.append("JARVIS already handled \"\(command)\" directly and answered: \(text)")
        say(spoken, language: lang)
        return true
    }

    /// Answer with the local model (Ollama) and JARVIS's tools.
    private func respondLocally(_ command: String, language lang: Language, brief: Bool = false) async {
        answering = .local
        state = .thinking
        reply = ""
        currentReplyMentionsName = false
        generating = true
        defer { generating = false }

        // Memory goes in a separate message, after instructions and tools:
        // so when it changes, Ollama still reuses the cache of the fixed part.
        var base: [ChatMessage] = [["role": "system", "content": Persona.systemPrompt(config: config, memory: "")]]
        if !memory.promptBlock.isEmpty { base.append(["role": "system", "content": memory.promptBlock]) }
        base += turns.suffix(config.historyTurns).flatMap { $0 }
        var turn: [ChatMessage] = [["role": "user", "content": Persona.turnContext(language: lang) + "\n" + command]]
        tools.currentCommand = command
        tools.currentLanguage = lang
        var spoken = ""
        var acting = brief
        var held: [String] = []
        func say(_ sentence: String) {
            if acting { held.append(sentence) } else { speakSentence(sentence, lang) }
        }

        do {
            // The model can ask for several tools in a row (e.g. find the
            // project, then open it): at most 6 steps per request.
            for _ in 0..<6 {
                var splitter = SentenceSplitter()
                var text = ""
                var calls: [ToolCall] = []
                var rawCalls: [[String: Any]] = []
                for try await event in ollama.chat(base + turn, tools: tools.localDefinitions) {
                    if Task.isCancelled { return }
                    switch event {
                    case .text(let chunk):
                        text += chunk
                        reply = Self.visible(spoken + " " + text)
                        for sentence in splitter.push(chunk) { say(sentence) }
                    case .toolCalls(let parsed, let raw):
                        calls += parsed
                        rawCalls += raw
                    }
                }
                if let rest = splitter.flush() { say(rest) }
                if calls.isEmpty, spoken.isEmpty, stayedSilent(text) { return }
                if calls.contains(where: { Self.acts($0.name) }) { acting = true }
                if acting, !calls.isEmpty, !held.isEmpty {
                    Diagnostics.log("breve     \(held.count) frasi di cronaca non dette")
                    held.removeAll()
                }
                if calls.isEmpty { for sentence in held { speakSentence(sentence, lang) } }
                spoken += " " + text

                var message: ChatMessage = ["role": "assistant", "content": Self.visible(text)]
                if !rawCalls.isEmpty { message["tool_calls"] = rawCalls }
                turn.append(message)
                if calls.isEmpty { break }

                for call in calls {
                    note("▸ \(call.name) \(Self.describe(call.arguments))")
                    if !speech.isSpeaking { state = .acting }
                    switch await tools.run(call) {
                    case .result(let result):
                        turn.append(["role": "tool", "tool_name": call.name, "content": result])
                    case .needsConfirmation(let action):
                        pending = action
                        turn.append(["role": "tool", "tool_name": call.name,
                                     "content": "Prepared, NOT done yet. Ask the user to confirm in one sentence: \(action.summary)"])
                    case .image(let jpeg, let note):
                        // Ollama accepts images in user messages: the image
                        // joins the same conversation, without losing the cache.
                        turn.append(["role": "tool", "tool_name": call.name, "content": note])
                        turn.append(["role": "user", "content": "[immagine]", "images": [jpeg.base64EncodedString()]])
                    }
                    if Task.isCancelled { return }
                }
            }
        } catch {
            if Task.isCancelled { return }
            let message = lang == .italian
                ? "Mi scusi, signore, il mio nucleo locale non risponde."
                : "Apologies, sir, my local core is not responding."
            reply = message
            note(error.localizedDescription)
            speakSentence(message, lang)
        }
        // In the history images remain only as placeholders: sending them again on
        // every request would cost thousands of tokens.
        turns.append(turn.map { message in
            guard message["images"] != nil else { return message }
            var text = message
            text["images"] = nil
            text["content"] = "[immagine già esaminata]"
            return text
        })
        if turns.count > 40 { turns.removeFirst(turns.count - 40) }
        generating = false
        if !speech.isSpeaking { speechFinished() }
    }

    // MARK: Claude

    enum Brain: String { case local, claude }

    private func setUpClaude() {
        brain = Brain(rawValue: config.brain) ?? .local
        claude.model = config.claudeModel
        let definitions = tools.definitions.compactMap { tool -> [String: Any]? in
            guard let fn = tool["function"] as? [String: Any] else { return nil }
            return ["name": fn["name"] ?? "", "description": fn["description"] ?? "", "inputSchema": fn["parameters"] ?? [:]]
        }
        mcp.tools = { definitions }
        mcp.call = { [weak self] name, arguments in
            await self?.runToolForClaude(name, arguments) ?? [["type": "text", "text": "JARVIS non disponibile"]]
        }
        do { try mcp.start() } catch { note("Server strumenti per Claude: \(error.localizedDescription)") }
        Task { await refreshClaudeStatus() }
    }

    private func refreshClaudeStatus() async {
        guard let binary = ClaudeBridge.findBinary() else {
            claudeStatus = "NON INSTALLATO"
            return
        }
        let result = await Shell.run(binary, ["auth", "status"], timeout: 10)
        let loggedIn = result.out.contains("\"loggedIn\": true")
        claudeStatus = loggedIn ? "\(config.claudeModel.uppercased()) · COLLEGATO" : "LOGIN NECESSARIO"
    }

    /// A tool result in the MCP content format (text or image).
    private func runToolForClaude(_ name: String, _ arguments: [String: Any]) async -> [[String: Any]] {
        let previous = tools.currentSource
        tools.currentSource = "claude (\(previous))"
        defer { tools.currentSource = previous }
        switch await tools.run(ToolCall(name: name, arguments: arguments)) {
        case .result(let result):
            return [["type": "text", "text": result]]
        case .needsConfirmation(let action):
            pending = action
            return [["type": "text", "text": "Prepared, NOT done yet. Ask the user to confirm in one sentence: \(action.summary)"]]
        case .image(let jpeg, let note):
            return [["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"], ["type": "text", "text": note]]
        }
    }

    /// Changes brain from the HUD or the menu.
    // MARK: Vocabulary learning

    private var misunderstandings = 0
    /// Confirmations and cancellations handled by JARVIS, to report to Claude.
    private var notesForClaude: [String] = []
    /// The next phrase comes from a test channel, not from the microphone.
    private var testInjection = false
    private var failedAttempts: [String] = []
    private static let vocabularyMarker = "VOCABOLARIO:"

    /// After `learnAfterFailures` misunderstood requests in a row (empty searches or
    /// "non hai capito", "ho detto…") the request goes to Claude Opus: it understands what
    /// you meant, runs it with JARVIS's tools and teaches Whisper the right
    /// words, which end up in the personal vocabulary.
    private func checkUnderstanding(_ command: String, failed: Bool, language lang: Language) async {
        guard failed || Self.isCorrection(command) else {
            misunderstandings = 0
            failedAttempts = []
            return
        }
        misunderstandings += 1
        failedAttempts.append(command)
        Diagnostics.log("capito?   no (\(misunderstandings)/\(config.learnAfterFailures)): \"\(command)\"")
        guard misunderstandings >= config.learnAfterFailures, claudeStatus.hasSuffix("COLLEGATO") else { return }
        let attempts = failedAttempts
        misunderstandings = 0
        failedAttempts = []
        note("Non capisco: chiedo a Claude Opus")
        pipeline.cancelCapture()   // no follow-up listening while Opus works
        speakSentence(lang == .italian ? "Non ci riesco, signore. Chiedo aiuto a Claude Opus."
                                       : "I can't manage it, sir. Asking Claude Opus for help.", lang)
        let history = recentConversation(turns: 8).map { "Recent conversation (it may reveal what was meant):\n\($0)\n\n" } ?? ""
        let request = history + """
            The user tried \(attempts.count) times and the local assistant did not understand. These are \
            speech-to-text transcriptions and may contain recognition errors (misheard names, acronyms, surnames, \
            Italian words written in English):
            \(attempts.enumerated().map { "\($0.offset + 1). \"\($0.element)\"" }.joined(separator: "\n"))
            Work out what the user really meant and do it now with your tools (for files, try search_files with \
            several spellings and partial words). Answer briefly, in the user's language.
            If you are not sure, ask the user one short question instead of guessing.
            Then, as the very last line, write \(Self.vocabularyMarker) followed by at most 3 correctly spelled words \
            or names that the speech recognizer actually misheard (e.g. Arduino heard as "Ardoino"), comma-separated. \
            Only words you are confident about from the user's own request — never related topics. \
            If none, write "\(Self.vocabularyMarker) nessuna". That line is not spoken.
            """
        await respondWithClaude(request, language: lang, model: "opus", effort: "medium", learning: true)
    }

    private static func isCorrection(_ text: String) -> Bool {
        let t = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        return ["non hai capito", "ho detto", "non e quello", "intendevo", "hai capito male", "non quello",
                "you didn't understand", "i said", "that's not what", "i meant"].contains { t.contains($0) }
    }

    /// Adds the words given by Claude to Whisper's vocabulary (at most 60 entries).
    private func learnVocabulary(from text: String) async {
        guard let line = text.components(separatedBy: "\n").last(where: { $0.contains(Self.vocabularyMarker) }) else { return }
        let words = line.components(separatedBy: Self.vocabularyMarker).last?
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            .filter { !$0.isEmpty && $0.lowercased() != "nessuna" && $0.count <= 40 }
            .prefix(3) ?? []
        var entries = config.vocabulary.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            .components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let new = words.filter { w in !entries.contains { $0.caseInsensitiveCompare(w) == .orderedSame } }
        guard !new.isEmpty else { return }
        entries += new
        if entries.count > 60 { entries.removeFirst(entries.count - 60) }
        config.vocabulary = entries.joined(separator: ", ") + "."
        config.save()
        await transcriber.setVocabulary(config.vocabulary)
        note("Vocabolario: imparato \(new.joined(separator: ", "))")
        Diagnostics.log("impara    nuove parole per Whisper: \(new.joined(separator: ", "))")
    }

    private static func withoutVocabulary(_ text: String) -> String {
        guard let range = text.range(of: vocabularyMarker) else { return text }
        return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Claude models available with the subscription (Claude Code aliases).
    static let claudeModels = ["haiku", "sonnet", "opus"]

    func setClaudeModel(_ model: String) {
        Task { await switchClaudeModel(to: model, language: language, announce: state == .idle) }
    }

    private func switchClaudeModel(to model: String, language lang: Language, announce: Bool = true) async {
        config.claudeModel = model
        config.save()
        claude.model = model
        note("Modello di Claude: \(model.capitalized)")
        await refreshClaudeStatus()
        guard announce else { return }
        say(lang == .italian ? "Claude \(model.capitalized) pronto, signore." : "Claude \(model.capitalized) ready, sir.", language: lang)
    }

    func setBrain(_ target: Brain) {
        Task { await switchBrain(to: target, language: language, announce: state == .idle) }
    }

    private func switchBrain(to target: Brain, language lang: Language, announce: Bool = true) async {
        brain = target
        config.brain = target.rawValue
        config.save()
        note(target == .claude ? "Cervello: Claude" : "Cervello: locale")
        if target == .claude { await refreshClaudeStatus() }
        guard announce else { return }
        let text: String
        switch (target, lang) {
        case (.claude, .italian): text = "Collegato a Claude, signore."
        case (.claude, .english): text = "Connected to Claude, sir."
        case (.local, .italian): text = "Torno al nucleo locale, signore."
        case (.local, .english): text = "Back to the local core, sir."
        }
        say(text, language: lang)
    }

    /// Answer with Claude through Claude Code. If Claude cannot be reached
    /// (expired login, no network…) the local model answers.
    /// Tools that only read: what they find is told. app_read and app_look serve the actions.
    /// Every other tool acts: while it acts JARVIS does not narrate, the voice would arrive after the action.
    private static let readingTools: Set<String> = [
        "list_running_apps", "system_status", "review_flashcards", "flashcards_summary", "search_files", "list_projects", "list_shortcuts",
        "list_events", "list_reminders", "list_unread_emails", "search_emails", "read_email", "web_search", "read_webpage", "get_weather",
        "list_memories", "activity_report", "project_info", "recent_project_activity", "daily_briefing", "ros_graph", "ros_echo", "lab_status",
        "robot_status", "look_at_screen", "look_at_camera", "arduino_boards", "serial_read", "printer_status", "search_notes", "list_timers",
        "WebSearch", "Read", "Grep", "Glob", "LS", "app_read", "app_look", "app_scroll",
    ]

    private static func acts(_ tool: String) -> Bool {
        !readingTools.contains(tool.replacingOccurrences(of: "mcp__jarvis__", with: ""))
    }

    /// Brief: an action. The sentences said between one step and the next are dropped (they would describe
    /// something already done); only the last one is said, usually "Fatto, signore.".
    private func respondWithClaude(_ command: String, language lang: Language, model: String? = nil,
                                   effort: String? = nil, learning: Bool = false, brief: Bool = false) async {
        answering = .claude
        if let model {
            claude.model = model
            note("Domanda a Claude \(model.capitalized)")
        }
        claude.effort = effort
        defer {
            claude.model = config.claudeModel
            claude.effort = nil
        }
        state = .thinking
        reply = ""
        currentReplyMentionsName = false
        generating = true
        defer { generating = false }
        tools.currentCommand = command
        tools.currentLanguage = lang

        var prompt = Persona.turnContext(language: lang) + "\n" + (MacActions.frontAppContext().map { $0 + "\n" } ?? "") + command
        if !notesForClaude.isEmpty {
            prompt = "[Since your last reply: " + notesForClaude.joined(separator: " ") + "]\n" + prompt
            notesForClaude = []
        }
        if claude.startsNewSession, let recap = recentConversation() {
            prompt = "Recent conversation with the local assistant, for context only:\n\(recap)\n\n" + prompt
        }
        var splitter = SentenceSplitter()
        var full = ""
        var acting = brief
        var held: [String] = []
        func say(_ sentence: String) {
            if acting { held.append(sentence) } else { speakSentence(sentence, lang) }
        }
        do {
            for try await event in claude.ask(prompt, systemPrompt: Persona.claudePrompt(config: config, memory: memory.promptBlock), mcpConfig: mcp.claudeConfig) {
                if Task.isCancelled { return }
                switch event {
                case .text(let chunk):
                    full += chunk
                    reply = Self.visible(Self.withoutVocabulary(full))
                    // The final "VOCABOLARIO: …" line is for JARVIS, it is not read aloud.
                    for sentence in splitter.push(chunk) where !full.contains(Self.vocabularyMarker) { say(sentence) }
                case .tool(let name):
                    // Text before and after a tool are separate sentences.
                    full += "\n"
                    for sentence in splitter.push("\n") { say(sentence) }
                    if Self.acts(name) { acting = true }
                    if acting, !held.isEmpty {
                        Diagnostics.log("breve     \(held.count) frasi di cronaca non dette")
                        held.removeAll()
                    }
                    note("☁︎ \(name.replacingOccurrences(of: "mcp__jarvis__", with: ""))")
                    if !speech.isSpeaking { state = .acting }
                }
            }
            if let rest = splitter.flush(), !full.contains(Self.vocabularyMarker) { say(rest) }
            if stayedSilent(full) { return }
            for sentence in held { speakSentence(sentence, lang) }
            if learning { await learnVocabulary(from: full) }
            full = Self.withoutVocabulary(full)
            turns.append([["role": "user", "content": Persona.turnContext(language: lang) + "\n" + command],
                          ["role": "assistant", "content": Self.visible(full)]])
        } catch {
            if Task.isCancelled { return }
            note(error.localizedDescription)
            if case ClaudeError.notLoggedIn = error { claudeStatus = "LOGIN NECESSARIO" }
            let notice: String
            if case ClaudeError.notLoggedIn = error {
                notice = lang == .italian ? "Claude non è collegato, signore. Rispondo con il nucleo locale."
                                          : "Claude isn't signed in, sir. Answering with the local core."
            } else {
                notice = lang == .italian ? "Claude non risponde, signore. Rispondo con il nucleo locale."
                                          : "Claude isn't responding, sir. Answering with the local core."
            }
            speakSentence(notice, lang)
            generating = false
            await respondLocally(command, language: lang)
            return
        }
        generating = false
        if !speech.isSpeaking { speechFinished() }
    }

    /// Last exchanges of the conversation, to give context to a new Claude session.
    private func recentConversation(turns count: Int = 3) -> String? {
        let lines = turns.suffix(count).flatMap { $0 }.compactMap { message -> String? in
            guard let role = message["role"] as? String, role == "user" || role == "assistant",
                  let content = message["content"] as? String, !content.isEmpty else { return nil }
            let text = content.replacingOccurrences(of: #"\[context:[^\]]*\]\n"#, with: "", options: .regularExpression)
            return "\(role == "user" ? "User" : "JARVIS"): \(text.prefix(400))"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func timerFired(_ label: String, language lang: Language) {
        startStandaloneExchange()
        note("Timer scaduto: \(label)")
        NotificationCenter.default.post(name: .jarvisActivated, object: nil)
        speech.playChime(rising: false)
        let text = lang == .italian ? "Signore, il timer \(label) è scaduto." : "Sir, your \(label) timer is done."
        if state == .idle {
            say(text, language: lang)
        } else {
            speech.speak(text, language: lang)
        }
    }

    private func isSilentReply(_ text: String) -> Bool {
        silenceAllowed && Self.visible(text).trimmingCharacters(in: CharacterSet.letters.inverted) == Self.silentReply
    }

    /// The model judged the phrase was not for JARVIS: nothing is said and listening does not reopen.
    private func stayedSilent(_ text: String) -> Bool {
        guard isSilentReply(text) else { return false }
        Diagnostics.log("silenzio  parlava di Jarvis a qualcun altro: \"\(namedMidPhrase?.prefix(80) ?? "")\"")
        note("Parlava di me, non a me: resto in silenzio")
        reply = ""
        generating = false
        state = .idle
        return true
    }

    private func speakSentence(_ sentence: String, _ lang: Language) {
        if isSilentReply(sentence) { return }
        stillWorkingReminder?.cancel()
        defer { skipRepeatedAcknowledgment = false }
        if skipRepeatedAcknowledgment, Acknowledgment.isBare(sentence) { return }
        if sentence.lowercased().contains("jarvis") { currentReplyMentionsName = true }
        logFirstSentence()
        state = .speaking
        speech.speak(sentence, language: lang)
    }

    /// Time from the end of the user's phrase to JARVIS's first sentence.
    private func logFirstSentence() {
        guard firstSentencePending else { return }
        firstSentencePending = false
        if let start = Diagnostics.requestStart {
            Diagnostics.log("risposta  [\(Diagnostics.since(start)) dalla fine della frase] cervello: \(brain == .local ? "locale" : "Claude")")
        }
    }

    private func say(_ text: String, language lang: Language) {
        stillWorkingReminder?.cancel()
        skipRepeatedAcknowledgment = false
        logFirstSentence()
        reply = text
        state = .speaking
        speech.speak(text, language: lang)
    }

    private func speechFinished() {
        // The voice can finish a sentence before the model has written the next one.
        guard !generating, state == .speaking || state == .thinking || state == .acting else { return }
        currentReplyMentionsName = false
        // On the phone you answer by pressing again: the Mac's microphone stays out.
        if answeringPhone {
            state = .idle
            return
        }
        // After each answer it goes back to waiting: it keeps listening only if it waits for a "yes" or "no",
        // or if it asked a question. The answer to the question must also have the user's voice.
        let askedQuestion = reply.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
        if config.followUpConversation || pending != nil || askedQuestion, responseTask != nil {
            if askedQuestion { Diagnostics.log("ascolto   ha fatto una domanda, aspetta la risposta") }
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                if state == .speaking || state == .thinking || state == .acting { startListening(afterWake: false, followUp: true, checkVoice: true, isAnswer: askedQuestion, startTimeout: askedQuestion ? 8 : nil) }
            }
        } else {
            state = .idle
        }
    }

    private func interrupt() {
        stillWorkingReminder?.cancel()
        tools.appControl.halt()
        responseTask?.cancel()
        responseTask = nil
        speech.stop()
        pipeline.cancelCapture()
    }

    // MARK: iPhone

    /// The answer in progress is for the phone: the voice goes there and the Mac does not reopen the microphone.
    private var answeringPhone = false
    private var phoneNoteSent = false

    private func setUpPhoneBridge() {
        phoneBridge.follow(state: $state.eraseToAnyPublisher(), heard: $heard.eraseToAnyPublisher(), reply: $reply.eraseToAnyPublisher()) { [weak self] in
            (self?.state.wireName ?? "idle", self?.heard ?? "", self?.reply ?? "")
        }
        phoneBridge.onText = { [weak self] text in self?.phoneCommand(text) }
        phoneBridge.onAudio = { [weak self] samples in self?.phoneSpoke(samples) }
        phoneBridge.onStop = { [weak self] in self?.phoneInterrupted() }
        phoneBridge.onGone = { [weak self] in
            guard let self else { return }
            self.phoneNoteSent = false
            // The work goes on and the result stays written for when the phone comes back: you can ask
            // something in the car, on 4G, and then lose the line. Only the voice is skipped, since nobody hears it.
            if self.answeringPhone { self.speech.phoneAway = true }
        }
        phoneBridge.onBack = { [weak self] in self?.speech.phoneAway = false }
        phoneBridge.screenAllowed = { [weak self] in self?.privacyMode == false }
        updatePhoneBridge()
    }

    /// In test mode the link is turned on from the arguments, without touching the settings.
    private func updatePhoneBridge() {
        let arguments = CommandLine.arguments
        if config.developerMode, let flag = arguments.firstIndex(of: "--iphone-test-code"), flag + 1 < arguments.count {
            phoneBridge.start(testCode: arguments[flag + 1])
        } else if config.phoneBridge {
            phoneBridge.start()
        } else {
            phoneBridge.stop()
        }
    }

    /// A new command from the phone: it is the latest request, so it wins over the one in progress.
    private func beginPhoneRequest() -> Bool {
        if case .booting = state {
            phoneBridge.send(PhoneMessage(.notice, text: "JARVIS si sta ancora avviando sul Mac."))
            return false
        }
        // In privacy mode the Mac neither listens nor looks: the phone cannot get around it.
        guard !privacyMode else {
            phoneBridge.send(PhoneMessage(.notice, text: "Sul Mac è attiva la modalità privacy: JARVIS si riattiva da lì."))
            return false
        }
        if state != .idle {
            interrupt()
            phoneBridge.stopAudio()
        }
        pipeline.cancelCapture()
        if pending != nil, !pendingFromPhone { dropPendingFromOtherSide() }
        answeringPhone = true
        pipeline.bargeIn = false
        speech.phoneRoute = { [weak self] buffer, done in
            MainActor.assumeIsolated {
                guard let self else { return done() }
                self.phoneBridge.play(buffer, done: done)
            }
        }
        tools.currentSource = "iphone"
        tools.phoneOutside = phoneBridge.phoneOutside
        // Claude and the local model must know the user is not in front of the Mac.
        if !phoneNoteSent {
            phoneNoteSent = true
            notesForClaude.append("The user is talking from the iPhone app and may not see the Mac's screen: say results aloud instead of pointing at the screen.")
        }
        firstSentencePending = true
        Diagnostics.requestStart = Date()
        return true
    }

    private func dropPendingFromOtherSide() {
        guard let action = pending else { return }
        pending = nil
        action.onCancel?()
        Security.audit("annullato", tool: "conferma", source: "iphone", detail: "Conferma chiesta da un altro lato: \(action.summary)")
        notesForClaude.append("The user cancelled \"\(action.summary)\"; it was not executed.")
    }

    private func endPhoneRequest() {
        guard answeringPhone else { return }
        answeringPhone = false
        speech.phoneRoute = nil
        speech.phoneAway = false
    }

    private func phoneCommand(_ text: String) {
        guard beginPhoneRequest() else { return }
        heard = text
        let lang = SpeechEngine.detectLanguage(text, hint: language)
        language = lang
        state = .thinking
        responseTask = Task { await respond(to: text, language: lang) }
    }

    private func phoneSpoke(_ samples: [Float]) {
        guard beginPhoneRequest() else { return }
        state = .transcribing
        responseTask = Task {
            guard let (text, lang) = try? await transcriber.transcribe(samples), !Task.isCancelled else { return }
            Diagnostics.log("iphone    frase \"\(text)\" (\(lang == .italian ? "it" : "en"))")
            guard !text.isEmpty, !Transcriber.isCourtesyOnly(text) else {
                phoneBridge.send(PhoneMessage(.notice, text: "Non ho sentito nulla."))
                state = .idle
                return
            }
            heard = text
            language = lang
            state = .thinking
            await respond(to: text, language: lang)
        }
    }

    /// Stop from the phone: the answer stops and does not go to the speakers.
    private func phoneInterrupted() {
        guard answeringPhone else { return }
        interrupt()
        phoneBridge.stopAudio()
        generating = false
        state = .idle
    }

    // MARK: Test

    /// Test channels for development, without a microphone:
    ///   debug.audio (object = path of an audio file) simulates a phrase heard after "Jarvis";
    ///   debug.text  (object = text) simulates an already transcribed command.
    /// Test mode (development only, turned off by config "developerMode").
    /// Every message must start with the key in ~/Library/Application Support/JARVIS/dev_token,
    /// readable only by the user: sandboxed apps and web pages cannot give JARVIS orders.
    private func installDebugHooks() {
        guard config.developerMode else { return }
        // Tests without sound: beeps and answers stay only in the logs.
        if CommandLine.arguments.contains("--muted") {
            AudioHub.muted = true
            Diagnostics.logsSpeech = true
        }
        let center = DistributedNotificationCenter.default()
        // A tool without going through the model: "name {json arguments}". The outcome goes to diagnostics.
        center.addObserver(forName: .init(jarvisBundleID + ".debug.tool"), object: nil, queue: .main) { [weak self] note in
            guard let text = Security.unwrapDeveloperMessage(note.object) else { return }
            let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
            let arguments = parts.count > 1 ? (try? JSONSerialization.jsonObject(with: Data(parts[1].utf8))) as? [String: Any] : [:]
            guard let name = parts.first, let arguments else { return }
            Task { @MainActor in
                guard let self else { return }
                switch await self.tools.run(ToolCall(name: name, arguments: arguments)) {
                case .result(let result): Diagnostics.log("prova     \(name): \(result)")
                case .needsConfirmation(let action): Diagnostics.log("prova     \(name): conferma per \(action.summary)")
                case .image(_, let note): Diagnostics.log("prova     \(name): immagine \(note)")
                }
            }
        }
        center.addObserver(forName: .init(jarvisBundleID + ".debug.mic"), object: nil, queue: .main) { [weak self] note in
            guard let how = Security.unwrapDeveloperMessage(note.object) else { return }
            Task { @MainActor in self?.pipeline.debugBreak(how) }
        }
        center.addObserver(forName: .init(jarvisBundleID + ".debug.audio"), object: nil, queue: .main) { [weak self] note in
            guard let path = Security.unwrapDeveloperMessage(note.object) else { return }
            Task { @MainActor in
                guard let self, let samples = Self.loadAudio(path) else { return }
                self.testInjection = true
                self.state = .listening
                self.utteranceCaptured(samples, needsWakeCheck: true)
            }
        }
        // Like an answer to one of JARVIS's questions.
        center.addObserver(forName: .init(jarvisBundleID + ".debug.answer"), object: nil, queue: .main) { [weak self] note in
            guard let path = Security.unwrapDeveloperMessage(note.object) else { return }
            Task { @MainActor in
                guard let self, let samples = Self.loadAudio(path) else { return }
                self.testInjection = true
                self.state = .listening
                self.commandNeedsVoice = true
                self.commandIsAnswer = true
                self.utteranceCaptured(samples, needsWakeCheck: false)
            }
        }
        // A whole test in a single message.
        // Each line of the file: "enroll", "wake <audio>" or "command <audio>".
        center.addObserver(forName: .init(jarvisBundleID + ".debug.batch"), object: nil, queue: .main) { [weak self] note in
            guard let path = Security.unwrapDeveloperMessage(note.object),
                  let script = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            Task { @MainActor in await self?.runTestBatch(script) }
        }
        // Like a phrase said after the beep: goes through the voice check.
        center.addObserver(forName: .init(jarvisBundleID + ".debug.command"), object: nil, queue: .main) { [weak self] note in
            guard let path = Security.unwrapDeveloperMessage(note.object) else { return }
            Task { @MainActor in
                guard let self, let samples = Self.loadAudio(path) else { return }
                self.testInjection = true
                self.state = .listening
                self.commandNeedsVoice = true
                self.utteranceCaptured(samples, needsWakeCheck: false)
            }
        }
        // Like a phrase heard while waiting: goes through the wake word check.
        center.addObserver(forName: .init(jarvisBundleID + ".debug.wake"), object: nil, queue: .main) { [weak self] note in
            guard let path = Security.unwrapDeveloperMessage(note.object) else { return }
            Task { @MainActor in
                guard let self, let samples = Self.loadAudio(path) else { return }
                self.testInjection = true
                self.speechSegment(samples)
            }
        }
        center.addObserver(forName: .init(jarvisBundleID + ".debug.enroll"), object: nil, queue: .main) { [weak self] note in
            guard let what = Security.unwrapDeveloperMessage(note.object) else { return }
            Task { @MainActor in self?.startVoiceEnrollment(adding: what != "start", commands: what == "commands") }
        }
        center.addObserver(forName: .init(jarvisBundleID + ".debug.text"), object: nil, queue: .main) { [weak self] note in
            guard let text = Security.unwrapDeveloperMessage(note.object) else { return }
            Task { @MainActor in
                guard let self else { return }
                self.tools.currentSource = "test"
                // With "Jarvis" in it, like a phrase heard while waiting: the same extraction as the voice.
                var command = text
                self.namedMidPhrase = nil
                if let extracted = WakeVerifier.command(from: text), !extracted.isEmpty {
                    command = extracted
                    if WakeVerifier.isNamedMidPhrase(text) { self.namedMidPhrase = text }
                }
                self.heard = command
                let lang = SpeechEngine.detectLanguage(text, hint: .italian)
                self.language = lang
                self.responseTask = Task { await self.respond(to: command, language: lang) }
            }
        }
        note("Modalità test attiva (chiave in dev_token)")
    }

    private func runTestBatch(_ script: String) async {
        func settled() async {
            for _ in 0..<400 where state != .idle || checkingWake { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .seconds(1))
        }
        for line in script.split(separator: "\n").map(String.init) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            Diagnostics.log("test      \(parts[0]) \((parts.last ?? "").split(separator: "/").last ?? "")")
            await settled()
            if parts[0] == "enroll" {
                startVoiceEnrollment(adding: true, commands: true)
            } else if let samples = Self.loadAudio(parts[1]) {
                testInjection = true
                if parts[0] == "wake" {
                    speechSegment(samples)
                } else {
                    state = .listening
                    commandNeedsVoice = true
                    utteranceCaptured(samples, needsWakeCheck: false)
                }
            }
            await settled()
        }
        Diagnostics.log("test      finito, stato \(state), impronta \(voicePrint.samples.count) frasi, registrazione attiva \(voiceEnrollment.isActive)")
    }

    private static func loadAudio(_ path: String) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil,
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 1024)
        else { return nil }
        var consumed = false
        converter.convert(to: output, error: nil) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    // MARK: Settings

    private func configureNeuralVoice(_ config: JarvisConfig) {
        speech.useKokoro = config.neuralVoice
        speech.kokoroEnglishVoice = config.kokoroEnglishVoice
        speech.kokoroItalianVoice = config.kokoroItalianVoice
        speech.kokoroSpeed = config.kokoroSpeed
        speech.kokoroItalianSpeed = config.kokoroItalianSpeed
        speech.kokoroItalianPitch = config.kokoroItalianPitch
        speech.kokoroEnglishPitch = config.kokoroEnglishPitch
        speech.supertonicItalianVoice = config.supertonicItalianVoice
        speech.supertonicItalianSpeed = config.supertonicItalianSpeed
        speech.qwenItalian = config.qwenItalian
        speech.qwenItalianSpeed = config.qwenItalianSpeed
        printer.configure(host: config.bambuHost, serial: config.bambuSerial, code: config.bambuCode)
    }

    private func startNeuralVoice() async {
        MacActions.watchFrontApp()
        guard config.neuralVoice, !speech.kokoro.isReady else { return }
        if await speech.kokoro.start() {
            note("Voce neurale pronta")
            Task { await speech.prepareClips(Acknowledgment.allPhrases) }
        } else if KokoroTTS.isInstalled {
            note("Voce neurale non avviata: uso le voci Apple")
        } else {
            note("Voce neurale non installata (scripts/setup_tts.sh): uso le voci Apple")
        }
        voiceStatus = "IT \(speech.voiceDescription(for: .italian)) / EN \(speech.voiceDescription(for: .english))"
        Diagnostics.log("voce      \(voiceStatus)")
    }

    func shutdown() {
        speech.kokoro.stop()
        tools.ros.stop()
    }

    /// Stops Robot Console and the ROS lab, if active. Returns what it stopped.
    private func emergencyStop() async -> [String] {
        var stopped: [String] = []
        if tools.robotConsole.isConnected { stopped.append(await tools.robotConsole.stop()) }
        if tools.ros.isRunning { stopped.append("Laboratorio: " + (await tools.ros.lab("stop", wait: 3)).prefix(120)) }
        return stopped
    }

    /// Spontaneous robot notices (plan approved, completed, stopped).
    private func robotEvent(_ text: String) {
        note("Robot: \(text)")
        if state == .idle {
            startStandaloneExchange()
            say(text, language: language)
        } else {
            speech.speak(text, language: language)
        }
    }

    func apply(_ newConfig: JarvisConfig) {
        let old = config
        config = newConfig
        newConfig.save()
        tools.appControlEnabled = newConfig.appControl
        if old.phoneBridge != newConfig.phoneBridge { updatePhoneBridge() }
        speech.rate = newConfig.speechRate
        speech.englishVoiceName = newConfig.englishVoice
        speech.italianVoiceName = newConfig.italianVoice
        configureNeuralVoice(newConfig)
        if newConfig.neuralVoice {
            Task {
                await startNeuralVoice()
                await speech.prepareClips(Acknowledgment.allPhrases)
            }
        }
        voiceStatus = "IT \(speech.voiceDescription(for: .italian)) / EN \(speech.voiceDescription(for: .english))"
        if old.picovoiceAccessKey != newConfig.picovoiceAccessKey || old.wakeSensitivity != newConfig.wakeSensitivity {
            let error = pipeline.reloadWakeWord(accessKey: newConfig.picovoiceAccessKey, sensitivity: newConfig.wakeSensitivity)
            updateWakeStatus(error: error)
        }
        if old.whisperWake != newConfig.whisperWake || old.picovoiceAccessKey != newConfig.picovoiceAccessKey {
            Task {
                let previous = state
                await setUpWhisperWake()
                state = previous
            }
        }
        if old.localModel != newConfig.localModel || old.ollamaURL != newConfig.ollamaURL {
            ollama = OllamaClient(baseURL: newConfig.ollamaURL, model: newConfig.localModel)
            ollama.keepAlive = newConfig.modelKeepAlive
            Task { await ensureOllama() }
        }
    }

    func resetConversation() {
        turns.removeAll()
        claude.resetSession()
        pending = nil
        heard = ""
        reply = ""
        conversation.removeAll()
    }

    // MARK: Utilities

    private func note(_ message: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        log.append("\(time)  \(message)")
        if log.count > 50 { log.removeFirst(log.count - 50) }
    }

    private static func visible(_ text: String) -> String {
        text.replacingOccurrences(of: #"<think>[\s\S]*?(</think>|$)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "privacy", "modalità privacy", "smetti di ascoltare", "stop listening"…
    private static func isPrivacyCommand(_ text: String) -> Bool {
        let t = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        guard t.split(separator: " ").count <= 6 else { return false }
        return ["privacy", "smetti di ascoltare", "non ascoltare", "stop listening", "privacy mode", "spegni il microfono"]
            .contains { t.contains($0) }
    }

    /// "usa Claude", "passa a Claude", "torna al locale", "switch to Claude"…
    /// "usa Opus", "passa a Sonnet", "switch to Haiku" → the Claude model.
    private static func claudeModelSwitch(_ text: String) -> String? {
        let t = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        guard t.split(separator: " ").count <= 7 else { return nil }
        for model in claudeModels where t.range(of: #"\b(usa|passa a|attiva|metti|modello|use|switch to)\s+(il\s+)?(modello\s+)?(claude\s+)?"# + model + #"\b"#,
                                                     options: .regularExpression) != nil {
            return model
        }
        return nil
    }

    private static func brainSwitch(_ text: String) -> Brain? {
        let t = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        guard t.split(separator: " ").count <= 7 else { return nil }
        if t.range(of: #"\b(usa|passa a|attiva|collegati a|modalita|use|switch to|connect to)\s+(il\s+)?"# + claudeName + #"\b"#, options: .regularExpression) != nil {
            return .claude
        }
        if t.range(of: #"\b(torna|passa|usa|modalita|use|switch|go|back)\b.*\b(local[ei]?|offline)\b|\bdisattiva "# + claudeName + #"\b"#, options: .regularExpression) != nil {
            return .local
        }
        return nil
    }

    /// "ricordati che…", "tieni a mente che…", "remember that…" → the fact to store.
    /// ("ricordami di…" is a reminder instead, and the model handles it.)
    private static func explicitMemory(_ text: String) -> String? {
        let pattern = #"^\s*(?:jarvis[\s,]+)?(?:ricordati|ricorda|tieni a mente|memorizza|segnati|remember|don't forget|keep in mind)\s+(?:che|that)\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: " .!"))
    }

    /// "chiedi a Claude …" / "ask Claude …": a single question to Claude, without changing mode.
    /// How Whisper sometimes writes "Claude": Cloud, Claud, Clod, Clode…
    private static let claudeName = #"(?:claude|claud|cloud|clod|clode|cloude|clowd|klaud)"#

    /// "chiedi a Claude …", "usa Cloud per …", "usa Sonnet per …", "ask Opus …"
    /// → (question, model or nil for the chosen one).
    private static func claudeOneShot(_ text: String) -> (String, String?)? {
        let target = #"(?:il\s+|the\s+)?(?:modello\s+)?(?:\#(claudeName)\s+)?(\#(claudeName)|sonnet|opus|haiku)"#
        let patterns = [
            #"^\s*(?:chiedi\s+a|domanda\s+a|ask)\s+"# + target + #"[\s,:]+(.+)$"#,
            #"^\s*(?:usa|use|con|with)\s+"# + target + #"[\s,]+(?:per|to|e|and|a)\s+(.+)$"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let nameRange = Range(match.range(at: 1), in: text),
                  let questionRange = Range(match.range(at: 2), in: text) else { continue }
            let name = text[nameRange].lowercased()
            return (String(text[questionRange]), claudeModels.contains(name) ? name : nil)
        }
        return nil
    }

    private enum Confirmation { case yes, no, unclear }

    private static func confirmation(_ text: String) -> Confirmation {
        let words = Set(text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
        // An answer, not just any sentence: "assurdo è quando vede invia email", said to someone else,
        // counted as a yes because it contained "invia".
        let count = text.split(whereSeparator: { $0 == " " }).count
        if count <= 6, !words.isDisjoint(with: ["no", "non", "annulla", "cancel", "dont", "don", "aspetta", "wait"]) { return .no }
        if count <= 6, !words.isDisjoint(with: ["si", "confermo", "conferma", "invia", "procedi", "vai", "certo", "ok", "okay",
                                                "yes", "confirm", "send", "sure", "yeah", "go", "perfetto"]) { return .yes }
        return .unclear
    }

    private static func describe(_ args: [String: Any]) -> String {
        args.map { "\($0.key)=\(String(describing: $0.value).prefix(40))" }.sorted().joined(separator: " ")
    }

    /// "ferma il robot", "stop robot", "fermati", "emergenza"…
    private static func isRobotStop(_ text: String) -> Bool {
        let t = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        guard t.split(separator: " ").count <= 6 else { return false }
        // Whole words: "alt" inside "Rari d'Altacco" or "alto" stopped the robots and JARVIS went silent.
        return ["ferma il robot", "ferma tutto", "fermati", "ferma il braccio", "stop robot", "stop the robot",
                "emergency stop", "emergenza", "stop stop", "alt"]
            .contains { t.range(of: #"(?<![\p{L}'’])"# + NSRegularExpression.escapedPattern(for: $0) + #"(?![\p{L}'’])"#, options: .regularExpression) != nil }
            && !t.contains("non ")
    }

    private static func isStopCommand(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return ["stop", "basta", "annulla", "niente", "lascia stare", "cancel", "never mind", "nevermind", "nothing"].contains(t)
    }
}

/// Audio levels read by the HUD on every frame. Deliberately not @Published:
/// they change 50 times a second and must not redraw SwiftUI.
final class AudioLevels {
    var mic: Float = 0
    var voice: Float = 0
}

extension Notification.Name {
    static let jarvisActivated = Notification.Name("jarvisActivated")
}
