import Foundation
import WhisperKit

/// Local transcription with WhisperKit (Neural Engine).
/// Detects whether Italian or English is spoken and transcribes in that language.
actor Transcriber {
    private var whisper: WhisperKit?

    /// Small Whisper used only to recognise "Jarvis" during continuous listening.
    private var wakeWhisper: WhisperKit?

    /// Personal vocabulary already converted to tokens for Whisper's prompt.
    private var vocabulary = ""
    private var vocabularyTokens: [Int]?

    func setVocabulary(_ text: String) {
        vocabulary = text
        vocabularyTokens = nil
    }

    var isReady: Bool { whisper != nil }
    var wakeReady: Bool { wakeWhisper != nil }

    /// Folder for JARVIS's models and tokenizers (nothing in ~/Documents,
    /// which macOS protects with a separate permission).
    static let modelsBase = JarvisConfig.directory.appendingPathComponent("models", isDirectory: true)

    /// The model from disk if it is already there, otherwise it downloads it. Without this
    /// check WhisperKit always goes online, and at login (Wi-Fi not yet
    /// connected) start-up fails.
    static func modelFolder(_ variant: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let local = modelsBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)")
        let required = ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"]
        if required.allSatisfy({ FileManager.default.fileExists(atPath: local.appendingPathComponent($0).path) }) {
            progress?(1)
            return local
        }
        return try await WhisperKit.download(variant: variant, downloadBase: modelsBase) { p in
            progress?(p.fractionCompleted)
        }
    }

    func loadWakeModel(_ model: String = "openai_whisper-base") async throws {
        let folder = try await Self.modelFolder(model)
        wakeWhisper = try await WhisperKit(WhisperKitConfig(
            modelFolder: folder.path, tokenizerFolder: Self.modelsBase,
            computeOptions: ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine),
            verbose: false, logLevel: .error, prewarm: true, load: true, download: false))
    }

    /// Quick, approximate transcription, only to look for the word "Jarvis".
    func wakeTranscript(_ samples: [Float]) async -> String? {
        // The large Whisper (turbo) is already in memory for phrases: using it for
        // "Jarvis" too costs no RAM and errs much less than the small one, which wrote
        // "giardis", "darvi" or even "جاربيس". The small one remains only for start-up.
        guard let model = whisper ?? wakeWhisper else { return nil }
        var audio = samples
        if audio.count < 16_000 { audio += [Float](repeating: 0, count: 16_000 - audio.count) }
        // First with the "Jarvis" hint: from afar or in a hurry Whisper otherwise
        // writes "già l'ho visto". Then without it, for short phrases (a looser check);
        // in English only if nothing came out: the room may be noisy.
        var first: String?
        for (language, hinted) in [("it", true), ("it", false), ("en", false)] {
            if language == "it" && !hinted && audio.count > 3 * 16_000 { continue }
            if language == "en" && !(first?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) { break }
            var options = DecodingOptions(language: language, temperatureFallbackCount: 0, usePrefillPrompt: true,
                                          detectLanguage: false, skipSpecialTokens: true, withoutTimestamps: true)
            if hinted, let tokenizer = model.tokenizer {
                options.promptTokens = tokenizer.encode(text: " Jarvis.").filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            }
            guard let results = try? await model.transcribe(audioArray: audio, decodeOptions: options) else { continue }
            let text = results.map(\.text).joined(separator: " ")
            if WakeVerifier.command(from: text) != nil || WakeVerifier.isSoundalike(text) { return text }
            if first?.trimmingCharacters(in: .whitespaces).isEmpty ?? true { first = text }
        }
        // A "Jarvis" said alone (short word, lots of silence) sometimes comes out empty
        // from turbo: the small Whisper tries again, which costs a tenth of a second.
        if first?.trimmingCharacters(in: .whitespaces).isEmpty ?? true, let small = wakeWhisper, small !== model {
            let options = DecodingOptions(language: "it", temperatureFallbackCount: 0, usePrefillPrompt: true,
                                          detectLanguage: false, skipSpecialTokens: true, withoutTimestamps: true)
            if let results = try? await small.transcribe(audioArray: audio, decodeOptions: options) {
                return results.map(\.text).joined(separator: " ")
            }
        }
        return first
    }

    /// While JARVIS speaks: transcription in Italian to hear "basta". Uses the
    /// large Whisper: with two overlapping voices the small one writes only the louder.
    func quickTranscript(_ samples: [Float]) async -> String? {
        guard let model = whisper ?? wakeWhisper else { return nil }
        var audio = samples
        if audio.count < 16_000 { audio += [Float](repeating: 0, count: 16_000 - audio.count) }
        let options = DecodingOptions(language: "it", temperatureFallbackCount: 0, usePrefillPrompt: true,
                                      detectLanguage: false, skipSpecialTokens: true, withoutTimestamps: true)
        guard let results = try? await model.transcribe(audioArray: audio, decodeOptions: options) else { return nil }
        return results.map(\.text).joined(separator: " ")
    }

    func load(model: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let folder = try await Self.modelFolder(model, progress: progress)
        let config = WhisperKitConfig(
            modelFolder: folder.path,
            tokenizerFolder: Self.modelsBase,
            computeOptions: ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine,
                                                textDecoderCompute: .cpuAndNeuralEngine),
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        whisper = try await WhisperKit(config)
    }

    /// `lenient`: for the answer to one of JARVIS's questions. An exam answer said in a rush,
    /// full of technical terms, makes Whisper unsure and the normal filter threw it all away.
    func transcribe(_ samples: [Float], lenient: Bool = false) async throws -> (text: String, language: Language) {
        guard let whisper else { return ("", .italian) }
        // Whisper works on windows of at least 1 s: pad with silence.
        var audio = samples
        if audio.count < 16_000 { audio += [Float](repeating: 0, count: 16_000 - audio.count) }

        // WhisperKit returns only the most likely language. Everything that is not
        // English (Italian, but also Spanish or Portuguese picked by mistake) is Italian.
        let detection = try await whisper.detectLangauge(audioArray: audio)
        let italian = try await decode(audio, language: .italian, lenient: lenient, with: whisper)
        guard detection.language == "en" else { return (italian.text, .italian) }

        // On short phrases with "Jarvis" Whisper often takes Italian for
        // English (and translates!). Transcribe in both languages and keep the
        // surer version, with a small advantage for Italian.
        let english = try await decode(audio, language: .english, lenient: lenient, with: whisper)
        if italian.text.isEmpty { return (english.text, .english) }
        return english.confidence > italian.confidence + 0.15 ? (english.text, .english) : (italian.text, .italian)
    }

    /// The vocabulary as "previous sentence": Whisper tends to reuse its
    /// spelling, so "Arduino" does not become "Ardoino" and "Claude" does not become "Cloud".
    private func prompt(for whisper: WhisperKit) -> [Int]? {
        guard !vocabulary.isEmpty, let tokenizer = whisper.tokenizer else { return nil }
        if vocabularyTokens == nil {
            vocabularyTokens = tokenizer.encode(text: " " + vocabulary)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        return vocabularyTokens
    }

    private func decode(_ audio: [Float], language: Language, lenient: Bool = false, with whisper: WhisperKit) async throws -> (text: String, confidence: Float) {
        var options = DecodingOptions(
            language: language.rawValue,
            temperatureFallbackCount: 2,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        options.promptTokens = prompt(for: whisper)
        let results = try await whisper.transcribe(audioArray: audio, decodeOptions: options)
        // Discard segments where Whisper itself thinks there is no voice
        // or is very unsure: that is where invented phrases come from.
        let segments = results.flatMap(\.segments).filter { $0.noSpeechProb < (lenient ? 0.8 : 0.6) && $0.avgLogprob > (lenient ? -1.6 : -1.0) }
        let text = segments.map(\.text).joined(separator: " ")
        let confidence = segments.isEmpty ? -10 : segments.map(\.avgLogprob).reduce(0, +) / Float(segments.count)
        return (Self.clean(text), confidence)
    }

    /// Removes annotations like "[Musica]" and the phrases Whisper "invents"
    /// when it hears only noise.
    /// Courtesy phrases Whisper often produces from silence. During free
    /// conversation (without "Jarvis") they are ignored: no answer is needed.
    static func isCourtesyOnly(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return ["thank you", "thanks", "thank you very much", "grazie", "grazie mille", "ok", "okay", "bye",
                "ciao", "you", "perfetto", "va bene"].contains(t)
    }

    static func clean(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)|<\|[^|]*\|>|\*[^*]*\*|♪"#, with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let hallucinations = ["sottotitoli", "amara.org", "grazie per la visione", "thank you for watching",
                              "thanks for watching", "iscriviti al canale", "subscribe"]
        if hallucinations.contains(where: lower.contains) { return "" }
        let letters = text.filter(\.isLetter)
        return letters.count < 2 ? "" : text
    }
}

/// Second wake word check on Whisper's text: accepts only if
/// the phrase really holds a word very close to "Jarvis".
enum WakeVerifier {
    /// Returns the command without the wake word, or nil if "Jarvis" is not there.
    /// `loose`: looser recognition, only when the small Whisper has
    /// already heard "Jarvis" and the large one wrote it differently.
    static func command(from text: String, loose: Bool = false) -> String? {
        let words = text.split(whereSeparator: { $0 == " " })
        for (i, word) in words.prefix(loose ? 3 : words.count).enumerated() {
            let w = normalize(String(word))
            guard loose ? isLooseJarvis(w) : isJarvis(w) else { continue }
            let after = words[(i + 1)...].joined(separator: " ")
            let before = words[..<i].joined(separator: " ")
            let rest = after.isEmpty ? before : after
            return rest.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:!?-"))
        }
        return nil
    }

    /// The small Whisper writes "Jarvis" said the Italian way in many forms:
    /// "giardis", "ciarvis", "charvis", "sciarvis", "djarvis", "jarbis"…
    /// The start is mapped back to "j" and then compared with "jarvis".
    static func isJarvis(_ w: String) -> Bool {
        if w == "giardice" { return true }
        guard (4...10).contains(w.count) else { return false }
        var core = w
        for start in ["sci", "dgi", "dj", "dg", "dz", "gi", "ci", "ch", "sh", "zh"] where core.hasPrefix(start) {
            core = "j" + core.dropFirst(start.count)
            break
        }
        guard let first = core.first, "jgy".contains(first) else { return false }
        return ["jarvis", "jarvi", "jervis", "jarviss", "jarbis", "jarvise"].contains { distance(core, $0) <= 1 }
            || distance(core, "jarvis") <= 2
    }

    /// Real phrases Whisper writes instead of a hurried "Jarvis": alone they are not
    /// enough to wake it, the voice must also be the user's.
    static func isSoundalike(_ text: String) -> Bool {
        ["gialhovisto", "giavisto", "gialavviso", "gialaviso", "giadisse", "gialadvista", "giaavvisse",
         "giaalbis", "giornodisse", "gialavista", "giaavisa"].contains(normalize(text))
    }

    static func isLooseJarvis(_ w: String) -> Bool {
        (4...9).contains(w.count) && (distance(w, "jarvis") <= 3 || w.hasSuffix("rvis") || w.hasSuffix("rvi"))
    }

    private static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .filter(\.isLetter)
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var prev = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var row = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                row[j] = min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = row
        }
        return prev[b.count]
    }
}
