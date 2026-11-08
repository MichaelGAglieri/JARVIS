import Foundation

/// The user's voiceprint: a series of numbers for each recorded sentence,
/// from which the audio cannot be rebuilt. It lives only on the Mac (`voiceprint.json`).
@MainActor
final class VoicePrint: ObservableObject {
    private let url = JarvisConfig.directory.appendingPathComponent("voiceprint.json")
    @Published private(set) var samples: [[Float]] = []

    var isEnrolled: Bool { !samples.isEmpty }

    init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([[Float]].self, from: data) {
            samples = saved
        }
    }

    /// `adding`: the sentences are added to those already recorded (other distances and tones).
    func save(_ embeddings: [[Float]], adding: Bool = false) {
        // A sentence very different from the others of the same session is not the user's voice (someone
        // spoke over it). The comparison is internal only: from afar the voice differs from up close.
        let session = embeddings.map(Self.normalized)
        let scores = Self.similarities(session)
        let median = scores.sorted()[scores.count / 2]
        let kept = zip(session, scores).filter { $0.1 >= median - 0.25 }.map(\.0)
        samples = adding ? samples + kept : kept
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: url, options: .atomic)
        Security.protect(url)
    }

    func delete() {
        samples = []
        try? FileManager.default.removeItem(at: url)
    }

    /// Similarity with the three closest recorded sentences: a short word closely resembles
    /// some recording of the same word, less their average.
    func score(_ embedding: [Float]) -> Float {
        let e = Self.normalized(embedding)
        let similar = samples.map { s in zip(s, e).reduce(Float(0)) { $0 + $1.0 * $1.1 } }.sorted(by: >).prefix(3)
        return similar.isEmpty ? 0 : similar.reduce(0, +) / Float(similar.count)
    }

    /// How much each recording resembles the others: tells how consistent the enrolment is.
    func selfScores() -> [Float] { Self.similarities(samples) }

    private static func similarities(_ samples: [[Float]]) -> [Float] {
        samples.indices.map { i in
            let others = samples.enumerated().filter { $0.offset != i }.map { o in
                zip(o.element, samples[i]).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            }.sorted(by: >).prefix(3)
            return others.isEmpty ? 0 : others.reduce(0, +) / Float(others.count)
        }
    }

    private static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }
}

/// Guided voice enrolment: shows one sentence at a time and keeps it only
/// if it really contains "Jarvis". The audio is not kept.
@MainActor
final class VoiceEnrollment: ObservableObject {
    static let firstPrompts = [
        "Jarvis", "Jarvis", "Jarvis", "Jarvis",
        "Jarvis (più piano)", "Jarvis (più piano)",
        "Jarvis (più veloce)", "Jarvis (più veloce)",
        "Jarvis (allontanati un po' dal Mac)", "Jarvis (allontanati un po' dal Mac)",
        "Jarvis (come se fossi occupato)", "Jarvis (come se fossi occupato)",
        "Jarvis, che ore sono?",
        "Jarvis, apri Safari.",
        "Jarvis, quali sono gli impegni di oggi?",
        "Jarvis, apri il PDF di chimica organica.",
        "Jarvis, ricordami di chiamare domani mattina.",
        "Jarvis, what's the weather like today?",
    ]

    /// More sentences: at each beep change place, direction or tone.
    static let morePrompts = Array(repeating: "Jarvis\n(a ogni beep cambia distanza, direzione o tono)", count: 15)

    /// Real commands, said as after the beep: the voice of a whole sentence, not just of "Jarvis".
    static let commandPrompts = [
        "Apri Safari.", "Chiudi Safari.", "Apri l'applicazione Promemoria.", "Che appuntamenti ho domani?",
        "Crea un evento domani alle quindici.", "Imposta un timer di venticinque minuti.", "Metti un po' di musica.",
        "Alza il volume.", "Che tempo fa oggi?", "Cerca il PDF di chimica organica.",
        "Apri Robot Console.", "Com'è il robot?", "Inizio a studiare Chimica.",
        "Quanto ho studiato questa settimana?", "Leggimi le mail nuove.", "Scrivi una mail al professore.",
        "Spiegami questo errore sullo schermo.", "Chiudi la scheda di YouTube.", "Minimizza questa finestra.",
        "Sì, confermo.", "No, annulla.", "Usa Claude Opus per questa domanda.",
        "What's the weather like today?", "Open Visual Studio Code.",
    ]

    private(set) var adding = false
    private(set) var commands = false
    private var refusals = 0
    var prompts: [String] { commands ? Self.commandPrompts : adding ? Self.morePrompts : Self.firstPrompts }
    @Published private(set) var isActive = false
    @Published private(set) var step = 0
    @Published var message = ""
    private(set) var embeddings: [[Float]] = []

    var prompt: String { step < prompts.count ? prompts[step] : "" }
    var progress: Double { Double(step) / Double(prompts.count) }
    var isFinished: Bool { step >= prompts.count }

    func start(adding: Bool = false, commands: Bool = false) {
        self.adding = adding
        self.commands = commands
        refusals = 0
        embeddings = []
        step = 0
        message = "Leggi la frase a voce normale, poi fai una breve pausa."
        isActive = true
    }

    /// The recorded sentence is the right one: "Jarvis" or at least half the words of the command.
    /// So the TV or someone else in the background do not end up in the voiceprint.
    func accepts(_ heard: String) -> Bool {
        guard commands else { return WakeVerifier.command(from: heard) != nil }
        let words = { (text: String) in
            Set(text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
                .components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
        }
        let expected = words(prompt)
        return !expected.isEmpty && Double(expected.intersection(words(heard)).count) / Double(expected.count) >= 0.5
    }

    /// Whisper did not understand the sentence. For commands, after three attempts it moves to the next:
    /// one hard word must not lose the whole enrolment.
    func refused() {
        message = commands ? "Non ho capito la frase: rileggila." : "Non ho sentito \"Jarvis\": ripeti la frase."
        guard commands else { return }
        refusals += 1
        if refusals >= 3 {
            refusals = 0
            step += 1
            message = "Questa la saltiamo: leggi la prossima."
        }
    }

    func accept(_ embedding: [Float]) {
        refusals = 0
        embeddings.append(embedding)
        step += 1
        message = "Bene."
    }

    func stop(_ text: String? = nil) {
        isActive = false
        if let text { message = text }
    }
}
