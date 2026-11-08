import Foundation

/// Connects microphone, wake word and voice activity detection (VAD).
///
/// In `.wake` mode it keeps the last second and a half of audio in memory and
/// passes everything to Porcupine. When it hears "Jarvis" it tells the assistant, which
/// starts capturing the command with `beginCapture`. Capture ends when
/// the person stops speaking and hands over the audio (wake word included)
/// for Whisper to transcribe and confirm it really was "Jarvis".
final class VoicePipeline {
    private let queue = DispatchQueue(label: "jarvis.audio", qos: .userInteractive)
    private let input = AudioInput()
    private var porcupine: Porcupine?

    private enum Mode { case wake, capture }
    private var mode: Mode = .wake

    private let window = 320                 // 20 ms at 16 kHz
    private let prerollLimit = 24_000        // 1,5 s
    private var preroll: [Float] = []
    private var captured: [Float] = []
    private var carry: [Float] = []

    // VAD state during capture.
    private var noiseDB: Float = -55
    private var speechTime = 0.0
    private var silenceTime = 0.0
    private var elapsed = 0.0
    private var startTimeout = 5.0
    private var minSpeech = 0.2
    private var thresholdBoost: Float = 11
    private var heardSpeech: Bool { speechTime >= minSpeech }

    /// Always called on the main thread.
    var onWake: (() -> Void)?
    /// `pauseFinal`: after the last pause announced with `onPause` nobody spoke again,
    /// so the early transcription of that pause is valid for the whole phrase.
    var onUtterance: ((_ samples: [Float], _ needsWakeCheck: Bool, _ pauseFinal: Bool) -> Void)?
    /// First pause (0.4 s) in the phrase: the assistant already starts transcribing,
    /// while here the rest of the silence is awaited to be sure it is over.
    var onPause: (([Float]) -> Void)?
    private var pauseSent = false

    /// While JARVIS speaks: phrases cut every 2 s (with 0.8 s of overlap),
    /// so "Jarvis, basta" arrives at once even if its voice never pauses.
    var bargeIn = false
    var onNothingHeard: (() -> Void)?
    var onLevel: ((Float) -> Void)?

    private var needsWakeCheck = false

    /// Continuous listening without Porcupine: every phrase said near the Mac is
    /// handed over (while waiting) for a small Whisper to check whether it contains "Jarvis".
    var listensForSpeech = false
    var onSpeechSegment: (([Float]) -> Void)?
    private var segment: [Float] = []
    private var inSegment = false
    private var segmentSpeech = 0.0
    private var segmentSilence = 0.0

    /// Echo cancellation: requested and actual state.
    var wantsEchoCancellation: Bool {
        get { input.wantsEchoCancellation }
        set { input.wantsEchoCancellation = newValue }
    }
    var echoCancellation: Bool { input.echoCancellation }

    var wakeWordReady: Bool { porcupine != nil }

    func start(accessKey: String, sensitivity: Float) throws -> String? {
        var wakeError: String?
        if !accessKey.isEmpty {
            do {
                porcupine = try Porcupine(accessKey: accessKey, sensitivity: sensitivity)
            } catch {
                wakeError = error.localizedDescription
            }
        }
        input.onSamples = { [weak self] samples in
            self?.queue.async { self?.process(samples) }
        }
        try input.start()
        return wakeError
    }

    /// Stops the microphone (to start over after a start-up error).
    func stop() {
        input.stop()
    }

    func debugBreak(_ how: String) { input.debugBreak(how) }

    func reloadWakeWord(accessKey: String, sensitivity: Float) -> String? {
        queue.sync {
            porcupine = nil
            guard !accessKey.isEmpty else { return nil }
            do {
                porcupine = try Porcupine(accessKey: accessKey, sensitivity: sensitivity)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }

    /// Starts recording a command.
    /// - afterWake: true if it started from the word "Jarvis" (the previous audio
    ///   is included and will have to be verified by Whisper).
    /// - lookback: seconds of just-past audio to keep (whoever speaks before the beep does not lose the start).
    func beginCapture(afterWake: Bool, strict: Bool = false, timeout: Double, lookback: Double = 0) {
        queue.async { [self] in
            captured = afterWake ? preroll : Array(preroll.suffix(Int(lookback * 16_000)))
            needsWakeCheck = afterWake
            speechTime = 0
            silenceTime = 0
            elapsed = 0
            startTimeout = timeout
            resetSegment()
            // In free conversation a clearer and longer voice is needed to start,
            // so noises and the tail of JARVIS's voice are not taken for commands.
            minSpeech = strict ? 0.4 : 0.2
            thresholdBoost = strict ? 15 : 11
            pauseSent = false
            mode = .capture
        }
    }

    func cancelCapture() {
        queue.async { [self] in
            mode = .wake
            captured = []
        }
    }

    private func process(_ samples: [Float]) {
        carry.append(contentsOf: samples)
        var offset = 0
        var peak: Float = 0
        while carry.count - offset >= window {
            let frame = Array(carry[offset..<offset + window])
            offset += window
            let db = Self.decibels(frame)
            peak = max(peak, db)
            switch mode {
            case .wake: processWake(frame, db: db)
            case .capture: processCapture(frame, db: db)
            }
        }
        carry.removeFirst(offset)
        let level = max(0, min(1, (peak + 60) / 50))
        DispatchQueue.main.async { self.onLevel?(level) }
    }

    private func processWake(_ frame: [Float], db: Float) {
        // Background noise: drops at once towards low levels, rises slowly.
        noiseDB = db < noiseDB ? noiseDB * 0.9 + db * 0.1 : noiseDB + (db - noiseDB) * 0.002
        preroll.append(contentsOf: frame)
        if preroll.count > prerollLimit { preroll.removeFirst(preroll.count - prerollLimit) }
        if porcupine?.feed(frame) == true {
            DispatchQueue.main.async { self.onWake?() }
        }
        if porcupine == nil && listensForSpeech { cutSegments(frame, db: db) }
    }

    /// Cuts the phrases: starts after 0.12 s of voice, ends after 0.6 s of
    /// silence (or 8 s of length). Short noise (less than 0.2 s of voice) does not
    /// reach Whisper; a quick "Jarvis" lasts about 0.3 s.
    private func cutSegments(_ frame: [Float], db: Float) {
        let speaking = db > max(noiseDB + 11, -50)
        guard inSegment else {
            segmentSpeech = speaking ? segmentSpeech + 0.02 : 0
            if segmentSpeech >= 0.12 {
                inSegment = true
                segmentSilence = 0
                segment = Array(preroll.suffix(8_000))   // half a second earlier, so the start is not lost
            }
            return
        }
        segment.append(contentsOf: frame)
        if speaking {
            segmentSpeech += 0.02
            segmentSilence = 0
        } else {
            segmentSilence += 0.02
        }
        if bargeIn && segmentSilence < 0.6 && segment.count >= 2 * 16_000 {
            let audio = segment
            segment = Array(segment.suffix(12_800))
            segmentSpeech = 0.4
            DispatchQueue.main.async { self.onSpeechSegment?(audio) }
            return
        }
        if segmentSilence >= 0.6 || segment.count >= 8 * 16_000 {
            let audio = segment
            let spoke = segmentSpeech
            resetSegment()
            if spoke >= 0.2 { DispatchQueue.main.async { self.onSpeechSegment?(audio) } }
        }
    }

    private func resetSegment() {
        inSegment = false
        segment = []
        segmentSpeech = 0
        segmentSilence = 0
    }

    private func processCapture(_ frame: [Float], db: Float) {
        captured.append(contentsOf: frame)
        elapsed += 0.02
        let threshold = max(noiseDB + thresholdBoost, -50)
        // The first quarter of a second is the beep: it is recorded but does not count as voice.
        if db > threshold && elapsed > 0.25 {
            speechTime += 0.02
            silenceTime = 0
            pauseSent = false
        } else if heardSpeech {
            silenceTime += 0.02
        }
        if heardSpeech && !pauseSent && silenceTime >= 0.4 {
            pauseSent = true
            let audio = captured
            DispatchQueue.main.async { self.onPause?(audio) }
        }

        if heardSpeech && (silenceTime >= 0.8 || elapsed >= 20) {
            finish(deliver: true)
        } else if !heardSpeech && elapsed >= startTimeout {
            finish(deliver: false)
        }
    }

    private func finish(deliver: Bool) {
        mode = .wake
        let audio = captured
        let check = needsWakeCheck
        let final = pauseSent && silenceTime > 0
        captured = []
        preroll = []
        DispatchQueue.main.async {
            if deliver { self.onUtterance?(audio, check, final) } else { self.onNothingHeard?() }
        }
    }

    private static func decibels(_ frame: [Float]) -> Float {
        var sum: Float = 0
        for s in frame { sum += s * s }
        let rms = sqrt(sum / Float(frame.count))
        return 20 * log10(max(rms, 1e-7))
    }
}
