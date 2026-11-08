import AVFoundation
import Speech

/// Recognition of the word "Jarvis": compares the text, so it can be tested without a microphone too.
enum WakeWord {
    /// How the Italian recogniser may write "Jarvis".
    private static let variants = ["jarvis", "jarvi", "jarviss", "giarvis", "giarvi", "gervis", "jervis", "jarvys", "garvis", "charvis", "giarviss"]
    private static let cancels = ["annulla", "stop", "ferma", "fermati", "basta", "lascia"]

    static func words(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "it_IT"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// The words said after "Jarvis", or nil if it was not said.
    static func tail(_ text: String) -> [String]? {
        var list = words(text)
        // "Jar vis" sometimes arrives split in two.
        if let index = list.indices.dropLast().first(where: { list[$0] == "jar" && ["vis", "wiz", "viz"].contains(list[$0 + 1]) }) {
            list.replaceSubrange(index...index + 1, with: ["jarvis"])
        }
        guard let index = list.lastIndex(where: variants.contains) else { return nil }
        return Array(list[(index + 1)...])
    }

    /// After the sound: "annulla" or "stop" means it was not for JARVIS.
    static func wantsCancel(_ tail: [String]) -> Bool {
        tail.count <= 2 && tail.contains(where: cancels.contains)
    }
}

/// Tells when one stopped speaking by looking at the level. Background noise is the lowest level
/// of the last few seconds: even in dense speech there are lower moments, and a constant noise stays below.
struct SilenceGate {
    enum Outcome { case going, ended, nothing }

    /// The start sound comes out of the speaker: while it plays it does not count.
    var ignore: Double
    private(set) var heard = false
    private var elapsed = 0.0
    private var sinceVoice = 0.0
    private var recent: [Float] = []

    init(ignore: Double = 0) { self.ignore = ignore }

    /// The recogniser has already understood some words.
    mutating func markSpeech() {
        heard = true
        sinceVoice = 0
    }

    mutating func feed(db: Float, seconds: Double) -> Outcome {
        elapsed += seconds
        guard elapsed > ignore else { return .going }
        recent.append(db)
        if recent.count > 70 { recent.removeFirst() }
        let floor = recent.sorted()[recent.count / 10]
        if recent.count >= 5, db > max(floor + 14, -50) {
            heard = true
            sinceVoice = 0
        } else {
            sinceVoice += seconds
        }
        if elapsed > 25 { return .ended }
        if heard { return sinceVoice > 1.0 ? .ended : .going }
        return elapsed > 6 ? .nothing : .going
    }
}

/// Listens for "Jarvis" with Apple's recognition, on the phone only: if the on-device model
/// is missing it does not listen, because the voice must not leave the phone until it is for JARVIS.
@MainActor
final class PhoneEar {
    /// The text understood so far.
    var onText: ((String) -> Void)?
    /// For tests: what happens to recognition.
    var onEvent: ((String) -> Void)?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "it-IT"))
    private let lock = NSLock()
    nonisolated(unsafe) private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var renew: DispatchWorkItem?
    private(set) var running = false
    private var failures = 0
    /// Recognition keeps failing: usually the Dictation language is missing.
    var onUnavailable: (() -> Void)?

    var isAvailable: Bool { recognizer?.isAvailable == true && recognizer?.supportsOnDeviceRecognition == true }

    static func askPermission() async -> Bool {
        await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) }
        }
    }

    func start() {
        guard !running else { return }
        running = true
        begin()
    }

    func stop() {
        running = false
        renew?.cancel()
        finishTask()
    }

    /// Starts from scratch: what was already understood must not wake it again.
    func restart() {
        guard running else { return }
        finishTask()
        begin()
    }

    /// From the audio thread.
    nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request?.append(buffer) }
    }

    private func finishTask() {
        task?.cancel()
        task = nil
        lock.withLock {
            request?.endAudio()
            request = nil
        }
    }

    private func begin() {
        guard let recognizer, isAvailable else {
            onEvent?("non disponibile: dispositivo \(recognizer?.supportsOnDeviceRecognition == true), pronto \(recognizer?.isAvailable == true)")
            return
        }
        let new = SFSpeechAudioBufferRecognitionRequest()
        #if targetEnvironment(simulator)
        // The simulator has no model: only here, and only with test phrases, Apple's online one is used.
        new.requiresOnDeviceRecognition = false
        #else
        new.requiresOnDeviceRecognition = true
        #endif
        new.shouldReportPartialResults = true
        new.contextualStrings = ["Jarvis"]
        new.taskHint = .search
        lock.withLock { request = new }
        recognizer.queue = .main
        task = recognizer.recognitionTask(with: new) { [weak self] result, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let result {
                    self.failures = 0
                    self.onText?(result.bestTranscription.formattedString)
                }
                if let error {
                    let code = (error as NSError).code
                    self.onEvent?("riconoscimento: \(code)")
                    // 1110: no voice in the stretch listened to, it always happens in a quiet room.
                    if code != 1110 { self.failures += 1 }
                    if self.failures == 6 { self.onUnavailable?() }
                    // If the model is missing, do not insist in vain: it would drain the battery.
                    self.scheduleRenew(after: min(60, 0.5 * pow(2, Double(self.failures))))
                } else if result?.isFinal == true {
                    self.scheduleRenew(after: 0.2)
                }
            }
        }
        // A recognition cannot last forever: restart before iOS closes it.
        scheduleRenew(after: 50)
    }

    private func scheduleRenew(after seconds: Double) {
        renew?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.restart() }
        }
        renew = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
