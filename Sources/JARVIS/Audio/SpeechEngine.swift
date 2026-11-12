import AVFoundation
import NaturalLanguage

/// Speech synthesis. By default it uses the Kokoro neural voice (Lewis in English, Nicola
/// in Italian), much more natural; if Kokoro is not available it uses the
/// macOS voices. With Kokoro the HUD follows the real level, with Apple voices the words.
final class SpeechEngine: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    let kokoro = KokoroTTS()
    /// Plays Kokoro's audio and the activation sound in the same engine
    /// as the microphone: this way echo cancellation recognises JARVIS's voice.
    private var engine: AVAudioEngine { AudioHub.engine }
    private let player = AVAudioPlayerNode()
    /// Raises or lowers the pitch without changing speed (Kokoro has no pitch control).
    private let pitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    private var queued = 0
    /// Language of the last sentence read: a hint for the following sentences of the same answer.
    private var lastLanguage: Language?
    private var level: Float = 0
    private var meter: Timer?
    /// Sentences waiting to be synthesised by Kokoro.
    private var kokoroQueue: [(text: String, language: Language)] = []
    private var synthesizing = false
    private var generation = 0
    private var kokoroPlaying = false
    /// Short sentences already synthesised, which start without waiting.
    private var clips: [String: AVAudioPCMBuffer] = [:]

    var useKokoro = true
    var kokoroEnglishVoice = "bm_lewis"
    var kokoroItalianVoice = "im_nicola"
    var kokoroSpeed = 1.0
    var kokoroItalianSpeed = 1.05
    /// Pitch in cents of a semitone (100 = one semitone higher).
    var kokoroEnglishPitch: Float = 0
    var kokoroItalianPitch: Float = 0
    /// Supertonic Italian voice ("M4:0.5+M3:0.5"); empty = Kokoro in Italian too.
    var supertonicItalianVoice = ""
    var supertonicItalianSpeed = 1.2
    /// Qwen3 Italian voice, chosen by the user; when off, Supertonic is used.
    var qwenItalian = true
    var qwenItalianSpeed = 1.0
    private var usesQwen: Bool { qwenItalian && KokoroTTS.hasQwen }
    private var usesSupertonic: Bool { !usesQwen && !supertonicItalianVoice.isEmpty && KokoroTTS.hasSupertonic }
    private var italianVoice: String {
        usesQwen ? "qwen3" : usesSupertonic ? "supertonic:\(supertonicItalianVoice)" : kokoroItalianVoice
    }
    private var italianSpeed: Double {
        usesQwen ? qwenItalianSpeed : usesSupertonic ? supertonicItalianSpeed : kokoroItalianSpeed
    }
    private var italianPitch: Float { usesQwen || usesSupertonic ? 0 : kokoroItalianPitch }
    var neuralActive: Bool { useKokoro && kokoro.isReady }

    var rate: Float = 0.5
    var englishVoiceName = "Jamie"
    var italianVoiceName = "Luca"

    /// If set, the answer is for the iPhone: sentences go there and the Mac's speakers stay quiet.
    /// The second function must be called when the phone has finished saying it.
    var phoneRoute: ((AVAudioPCMBuffer, @escaping () -> Void) -> Void)?
    /// The phone that asked has disconnected: no voice is prepared that nobody would hear.
    var phoneAway = false

    var onLevel: ((Float) -> Void)?
    /// Called when the whole queue has been spoken.
    var onFinished: (() -> Void)?
    var isSpeaking: Bool { queued > 0 }

    override init() {
        super.init()
        synthesizer.delegate = self
        connectToEngine()
        AudioHub.onReplaced = { [weak self] old in
            guard let self else { return }
            old.mainMixerNode.removeTap(onBus: 0)
            // The current sentence is lost; `stop` closes its completions, so the queue goes on.
            self.player.stop()
            old.detach(self.player)
            old.detach(self.pitch)
            self.connectToEngine()
        }
    }

    private func connectToEngine() {
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self, self.kokoroPlaying, let data = buffer.floatChannelData else { return }
            var sum: Float = 0
            let n = Int(buffer.frameLength)
            for i in 0..<n { sum += data[0][i] * data[0][i] }
            let db = 20 * log10(max(sqrt(sum / Float(max(n, 1))), 1e-7))
            let level = max(0, min(1, (db + 45) / 35))
            DispatchQueue.main.async { self.onLevel?(level) }
        }
    }

    // MARK: Voices

    /// Picks the best voice for the language: first the one set in the
    /// settings, then a male voice of the highest quality available.
    func voice(for language: Language) -> AVSpeechSynthesisVoice? {
        let code = language == .english ? "en-GB" : "it-IT"
        let preferred = language == .english ? englishVoiceName : italianVoiceName
        let fallbacks = language == .english ? ["Jamie", "Oliver", "Daniel", "Arthur", "Malcolm"] : ["Luca", "Emma", "Alice", "Federica"]
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == code }
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            var s = 0
            switch v.quality {
            case .premium: s += 300
            case .enhanced: s += 200
            default: s += 100
            }
            if v.gender == .male { s += 50 }
            return s
        }
        for name in [preferred] + fallbacks {
            let matches = voices.filter { $0.name.hasPrefix(name) }
            if let best = matches.max(by: { score($0) < score($1) }) { return best }
        }
        return voices.max(by: { score($0) < score($1) }) ?? AVSpeechSynthesisVoice(language: code)
    }

    func voiceDescription(for language: Language) -> String {
        if neuralActive {
            if language == .italian, usesQwen { return "Qwen3 · Neurale" }
            if language == .italian, usesSupertonic { return "Supertonic · Neurale" }
            let id = language == .english ? kokoroEnglishVoice : kokoroItalianVoice
            // "im_nicola:0.5+bm_fable:0.5" → "Nicola+Fable"
            let names = id.split(separator: "+").map { part in
                String(part.split(separator: ":").first ?? part).split(separator: "_").last.map { $0.capitalized } ?? String(part)
            }
            return names.joined(separator: "+") + " · Neurale"
        }
        guard let v = voice(for: language) else { return "—" }
        let quality = v.quality == .premium ? "Premium" : v.quality == .enhanced ? "Enhanced" : "Base"
        return "\(v.name.components(separatedBy: " (").first ?? v.name) · \(quality)"
    }

    // MARK: Playback

    /// Reads a sentence. `language` is the expected language (the one the user
    /// spoke), but the voice is chosen on the sentence's real language: if JARVIS
    /// answers in English to a question in Italian, Jamie speaks, not Luca.
    func speak(_ text: String, language: Language) {
        let spoken = Self.prepareForSpeech(text)
        guard !spoken.isEmpty else { return }
        let hint = isSpeaking ? (lastLanguage ?? language) : language
        let actual = Self.detectLanguage(spoken, hint: hint)
        lastLanguage = actual
        queued += 1
        if phoneAway {
            DispatchQueue.main.async { self.utteranceEnded() }
            return
        }
        if neuralActive {
            startEngine()
            if kokoroQueue.isEmpty, !synthesizing, let clip = clips[clipKey(spoken, actual)] {
                play(clip, language: actual, generation: generation)
            } else {
                kokoroQueue.append((spoken, actual))
                synthesizeNext()
            }
        } else {
            speakWithApple(spoken, language: actual)
        }
    }

    func hasClip(_ text: String, language: Language) -> Bool {
        clips[clipKey(Self.prepareForSpeech(text), language)] != nil
    }

    private func clipKey(_ text: String, _ language: Language) -> String {
        language == .italian ? "\(italianVoice)|\(italianSpeed)|\(text)" : "\(kokoroEnglishVoice)|\(kokoroSpeed)|\(text)"
    }

    /// Can this sentence start at once? With Qwen3 only if it is already ready: generating it now
    /// takes almost two seconds, and the app opened by the command would arrive much earlier.
    @MainActor
    func readyToSay(_ text: String, language: Language) async -> Bool {
        let spoken = Self.prepareForSpeech(text)
        let actual = Self.detectLanguage(spoken, hint: language)
        guard neuralActive, actual == .italian, usesQwen else { return true }
        let key = clipKey(spoken, actual)
        if clips[key] != nil { return true }
        guard let buffer = try? await kokoro.synthesize(spoken, voice: italianVoice, lang: "it", speed: italianSpeed, onlySaved: true) else { return false }
        clips[key] = buffer
        return true
    }

    /// Synthesises short sentences in advance, one at a time: whoever speaks meanwhile waits one sentence at most.
    @MainActor
    func prepareClips(_ phrases: [(text: String, italian: Bool)]) async {
        for phrase in phrases where neuralActive {
            let language: Language = phrase.italian ? .italian : .english
            let spoken = Self.prepareForSpeech(phrase.text)
            let key = clipKey(spoken, language)
            guard clips[key] == nil else { continue }
            let voice = phrase.italian ? italianVoice : kokoroEnglishVoice
            let speed = phrase.italian ? italianSpeed : kokoroSpeed
            if let buffer = try? await kokoro.synthesize(spoken, voice: voice, lang: phrase.italian ? "it" : "en-gb", speed: speed, fallback: kokoroItalianVoice, keep: phrase.italian) {
                clips[key] = buffer
            }
        }
    }

    private func play(_ buffer: AVAudioPCMBuffer, language: Language, generation gen: Int) {
        if let phoneRoute {
            phoneRoute(buffer) { [weak self] in
                guard let self, gen == self.generation else { return }
                self.utteranceEnded()
            }
            return
        }
        kokoroPlaying = true
        pitch.pitch = language == .italian ? italianPitch : kokoroEnglishPitch
        player.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.utteranceEnded()
            }
        }
        if !player.isPlaying { player.play() }
    }

    private func speakWithApple(_ text: String, language: Language) {
        // macOS voices cannot be sent to the phone: there the written text remains.
        if phoneRoute != nil {
            DispatchQueue.main.async { self.utteranceEnded() }
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice(for: language)
        utterance.rate = rate
        startMeter()
        synthesizer.speak(utterance)
    }

    /// Synthesises the next sentence as soon as possible: while one sentence is
    /// spoken the next is already being prepared, so there are no pauses.
    private var forceWhole = false

    /// The next sentence in one piece (when the pieces did not arrive): Qwen3 tries again, then the fallbacks.
    private func synthesizeWhole() {
        forceWhole = true
        synthesizing = false
        synthesizeNext()
    }

    private func synthesizeNext() {
        guard !synthesizing, !kokoroQueue.isEmpty else { return }
        synthesizing = true
        let item = kokoroQueue.removeFirst()
        let gen = generation
        let voice = item.language == .english ? kokoroEnglishVoice : italianVoice
        let fallback = kokoroItalianVoice
        let lang = item.language == .english ? "en-gb" : "it"
        let whole = forceWhole
        forceWhole = false
        if item.language == .italian, usesQwen, !whole {
            synthesizeInPieces(item.text, generation: gen)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let speed = item.language == .italian ? self.italianSpeed : self.kokoroSpeed
            let start = Date()
            let buffer = try? await self.kokoro.synthesize(item.text, voice: voice, lang: lang, speed: speed, fallback: fallback)
            Diagnostics.log("voce      [\(Diagnostics.since(start))] \(item.text.count) caratteri")
            if Diagnostics.logsSpeech { Diagnostics.log("voce testo \(item.text)") }
            await MainActor.run {
                guard gen == self.generation else { return }
                self.synthesizing = false
                if let buffer {
                    self.play(buffer, language: item.language, generation: gen)
                } else {
                    // Kokoro did not answer: the Apple voice reads this sentence.
                    self.speakWithApple(item.text, language: item.language)
                }
                self.synthesizeNext()
            }
        }
    }

    /// Italian with Qwen3: each piece plays as soon as it arrives (the first after about a third
    /// of a second), so JARVIS starts speaking without waiting for the whole sentence.
    /// If nothing arrives, the sentence goes the usual way (Supertonic, then Kokoro).
    private func synthesizeInPieces(_ text: String, generation gen: Int) {
        let speed = italianSpeed
        Task { [weak self] in
            guard let self else { return }
            let start = Date()
            var pieces = 0
            do {
                for try await piece in self.kokoro.synthesizeStream(text, speed: speed) {
                    let current = await MainActor.run { () -> Bool in
                        guard gen == self.generation else { return false }
                        if pieces == 0 {
                            Diagnostics.log("voce      [\(Diagnostics.since(start))] primo pezzo, \(text.count) caratteri")
                        }
                        self.deliver(piece)
                        return true
                    }
                    guard current else { return }
                    pieces += 1
                }
            } catch {
                Diagnostics.log("voce      a pezzi non riuscita dopo \(pieces) pezzi: \(error.localizedDescription)")
            }
            if Diagnostics.logsSpeech { Diagnostics.log("voce testo \(text)") }
            await MainActor.run {
                guard gen == self.generation else { return }
                Diagnostics.log("voce      [\(Diagnostics.since(start))] fine, \(pieces) pezzi")
                self.synthesizing = false
                if pieces > 0 {
                    self.finishPieces(generation: gen)
                } else {
                    self.kokoroQueue.insert((text, .italian), at: 0)
                    self.synthesizeWhole()
                    return
                }
                self.synthesizeNext()
            }
        }
    }

    /// On the iPhone each piece travels as its own clip, which the phone plays in a row. The last piece
    /// is held back until the sentence ends, so only its "played" closes the sentence.
    private var heldPiece: AVAudioPCMBuffer?

    private func deliver(_ piece: AVAudioPCMBuffer) {
        guard let phoneRoute else {
            schedule(piece, language: .italian, last: false)
            return
        }
        if let held = heldPiece { phoneRoute(held) {} }
        heldPiece = piece
    }

    private func finishPieces(generation gen: Int) {
        if let phoneRoute, let held = heldPiece {
            heldPiece = nil
            phoneRoute(held) { [weak self] in
                guard let self, gen == self.generation else { return }
                self.utteranceEnded()
            }
            return
        }
        // The phone left mid-sentence: its last piece plays here.
        if let held = heldPiece { schedule(held, language: .italian, last: false) }
        heldPiece = nil
        // An empty piece closes the sentence: its end arrives after the last real piece has played.
        schedule(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!, language: .italian, last: true, generation: gen)
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, language: Language, last: Bool, generation gen: Int = 0) {
        kokoroPlaying = true
        pitch.pitch = language == .italian ? italianPitch : kokoroEnglishPitch
        if last {
            player.scheduleBuffer(buffer) { [weak self] in
                DispatchQueue.main.async {
                    guard let self, gen == self.generation else { return }
                    self.utteranceEnded()
                }
            }
        } else {
            player.scheduleBuffer(buffer)
        }
        if !player.isPlaying { player.play() }
    }

    private func startEngine() {
        guard !engine.isRunning else { return }
        engine.prepare()
        try? engine.start()
    }

    func stop() {
        generation += 1
        heldPiece = nil
        queued = 0
        kokoroQueue.removeAll()
        synthesizing = false
        kokoroPlaying = false
        player.stop()
        synthesizer.stopSpeaking(at: .immediate)
        stopMeter()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.utteranceEnded() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.utteranceEnded() }
    }

    /// Every spoken word gives the animation a "kick", which then fades.
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        let length = Float(min(characterRange.length, 10))
        DispatchQueue.main.async { self.level = max(self.level, 0.45 + length * 0.05 + Float.random(in: 0...0.15)) }
    }

    private func utteranceEnded() {
        guard queued > 0 else { return }
        queued -= 1
        if queued == 0 {
            kokoroPlaying = false
            stopMeter()
            onFinished?()
            // Turns the audio output off when it stays silent: saves battery.
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, gen == self.generation, self.queued == 0 else { return }
                // The engine stays on: it is also the microphone's.
                self.player.stop()
            }
        }
    }

    private func startMeter() {
        guard meter == nil else { return }
        meter = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.level *= 0.86
            self.onLevel?(self.level)
        }
    }

    private func stopMeter() {
        meter?.invalidate()
        meter = nil
        level = 0
        onLevel?(0)
    }

    /// Short activation sound, generated on the fly: two rising tones.
    func playChime(rising: Bool = true) {
        startEngine()
        let sr = format.sampleRate
        let duration = 0.16
        let frames = AVAudioFrameCount(sr * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        let (f1, f2): (Double, Double) = rising ? (880, 1320) : (1100, 740)
        var phase = 0.0
        for i in 0..<Int(frames) {
            let t = Double(i) / sr
            let f = t < duration / 2 ? f1 : f2
            phase += 2 * .pi * f / sr
            data[i] = Float(sin(phase) * sin(.pi * t / duration) * 0.18)
        }
        player.scheduleBuffer(buffer) { [weak self] in
            // Turns the engine off right after, if JARVIS is not speaking.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let self, self.queued == 0 else { return }
                self.player.stop()
            }
        }
        if !player.isPlaying { player.play() }
    }

    /// Italian or English? Very short or uncertain sentences stay in the expected language.
    static func detectLanguage(_ text: String, hint: Language) -> Language {
        guard text.split(separator: " ").count >= 3 else { return hint }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.italian, .english]
        recognizer.languageHints = hint == .italian ? [.italian: 0.6, .english: 0.4] : [.english: 0.6, .italian: 0.4]
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        if (hypotheses[.english] ?? 0) > 0.7 { return .english }
        if (hypotheses[.italian] ?? 0) > 0.7 { return .italian }
        return hint
    }

    /// Cleans up the model's text: no markdown, emoji or symbols
    /// the voice would read oddly.
    static func prepareForSpeech(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"```[\s\S]*?```"#, with: "", options: .regularExpression)
        // Paths like ~/Projects/Robotica/MioRobot: only the final name is read.
        s = s.replacingOccurrences(of: #"(?<![\w])(?:~/|/)(?:[\w.\-]+/)*([\w.\-]+)/?"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[*`#>|~]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "_", with: " ")
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        s = String(s.unicodeScalars.filter { !($0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2100)) })
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
