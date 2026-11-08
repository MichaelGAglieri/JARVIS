import AVFoundation

/// Records while the button is pressed and plays JARVIS's sentences one after another.
final class PhoneAudio {
    private let levels: AudioLevels
    private let muted: Bool
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playback = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var recorded: [Float] = []
    private var recording = false
    private var generation = 0
    private var mutedEnd = Date.distantPast
    /// A separate engine for the microphone: on a real iPhone the input cannot be added to the voice
    /// engine once it has started.
    private var recorder: AVAudioEngine?
    /// The last stretch of voice, so "Jarvis" and what was said right after are not lost.
    private var recent: [Float] = []
    private var observers: [NSObjectProtocol] = []
    private static let recentLimit = 16_000 * 3
    /// Each microphone block: from the audio thread, for recognition.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Level and duration of each block, on the main thread.
    var onLevel: ((Float, Double) -> Void)?

    init(levels: AudioLevels, muted: Bool) {
        self.levels = levels
        self.muted = muted
        guard !muted else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playback)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            let level = self.player.isPlaying ? Self.level(buffer) : 0
            DispatchQueue.main.async { self.levels.voice = level }
        }
    }

    private static func decibels(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return -100 }
        var sum: Float = 0
        let n = Int(buffer.frameLength)
        for i in 0..<n { sum += data[0][i] * data[0][i] }
        return 20 * log10(max(sqrt(sum / Float(n)), 1e-7))
    }

    // MARK: Wake sound

    /// Three sharp notes and, for the voice wake-up, at full level: if you did not call it you must hear it.
    /// The volume stays the phone's: iOS gives apps no way to raise it.
    func playChime(loud: Bool) {
        vibrate()
        guard !muted, (try? prepare()) != nil else { return }
        let gain: Float = loud ? 1 : 0.3
        let notes: [(frequency: Float, seconds: Float)] = [(988, 0.09), (1319, 0.09), (1976, 0.16)]
        let rate: Float = 24_000
        let count = notes.reduce(0) { $0 + Int($1.seconds * rate) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playback, frameCapacity: AVAudioFrameCount(count)) else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        var at = 0
        let out = buffer.floatChannelData![0]
        for note in notes {
            let length = Int(note.seconds * rate)
            for i in 0..<length {
                let t = Float(i) / rate
                // The third harmonic makes the sound sharper and louder on the phone's speaker.
                let wave = sin(2 * .pi * note.frequency * t) + 0.4 * sin(2 * .pi * note.frequency * 3 * t)
                let edge = min(1, min(Float(i), Float(length - i)) / 120)
                out[at + i] = max(-1, min(1, wave * 0.8 * edge)) * gain
            }
            at += length
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    private func vibrate() {
        try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }

    private static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        let n = Int(buffer.frameLength)
        for i in 0..<n { sum += data[0][i] * data[0][i] }
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-7))
        return max(0, min(1, (db + 45) / 35))
    }

    private func prepareSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
    }

    private func prepare() throws {
        try prepareSession()
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    // MARK: JARVIS's voice

    func play(_ clip: PhoneClip, done: @escaping () -> Void) {
        if muted {
            // Night test: no sound, but the timings stay real.
            let start = max(Date(), mutedEnd)
            mutedEnd = start.addingTimeInterval(clip.duration)
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + mutedEnd.timeIntervalSinceNow) { [weak self] in
                if self?.generation == gen { done() }
            }
            return
        }
        guard (try? prepare()) != nil, let buffer = buffer(for: clip) else {
            done()
            return
        }
        let gen = generation
        player.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                done()
            }
        }
        if !player.isPlaying { player.play() }
    }

    func stopPlaying() {
        generation += 1
        mutedEnd = .distantPast
        levels.voice = 0
        guard !muted else { return }
        player.stop()
    }

    private func buffer(for clip: PhoneClip) -> AVAudioPCMBuffer? {
        let ratio = 24_000 / Double(clip.sampleRate)
        let count = Int(Double(clip.samples.count) * ratio)
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: playback, frameCapacity: AVAudioFrameCount(count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        let out = buffer.floatChannelData![0]
        if clip.sampleRate == 24_000 {
            clip.samples.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: count) }
        } else {
            for i in 0..<count {
                let position = Double(i) / ratio
                let index = Int(position)
                let next = min(index + 1, clip.samples.count - 1)
                let fraction = Float(position - Double(index))
                out[i] = clip.samples[index] * (1 - fraction) + clip.samples[next] * fraction
            }
        }
        return buffer
    }

    // MARK: Microphone

    func askMicrophone() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Opens the microphone; it stays open until `stopMicrophone` is called.
    func startMicrophone() throws {
        guard !muted, recorder == nil else { return }
        // Output first: if it started after, it could stop the microphone already open.
        try prepare()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let converter = AVAudioConverter(from: format, to: target) else {
            throw CocoaError(.featureUnsupported)
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.consume(buffer, converter: converter)
        }
        engine.prepare()
        try engine.start()
        recorder = engine
        watchForInterruptions()
    }

    /// A phone call, Siri or unplugged headphones stop the microphone without telling whoever uses it.
    private func watchForInterruptions() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            self?.reopenMicrophone()
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.reopenMicrophone()
        })
    }

    private func reopenMicrophone() {
        guard let old = recorder, !old.isRunning else { return }
        old.inputNode.removeTap(onBus: 0)
        recorder = nil
        try? startMicrophone()
    }

    func stopMicrophone() {
        recorder?.inputNode.removeTap(onBus: 0)
        recorder?.stop()
        recorder = nil
        levels.mic = 0
        lock.withLock { recent.removeAll(keepingCapacity: true) }
    }

    /// `earlier`: how many seconds already heard to keep, so the start of the phrase is not cut.
    func startRecording(earlier: Double = 0) throws {
        try startMicrophone()
        lock.withLock {
            recorded = Array(recent.suffix(Int(earlier * 16_000)))
            recording = true
        }
    }

    /// Only for simulator tests: a file instead of the microphone.
    func testFeed(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        consume(buffer, converter: converter)
    }

    private func consume(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        onBuffer?(buffer)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var used = false
        converter.convert(to: out, error: nil) { _, status in
            if used {
                status.pointee = .noDataNow
                return nil
            }
            used = true
            status.pointee = .haveData
            return buffer
        }
        guard let data = out.floatChannelData, out.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
        let level = Self.level(out)
        lock.withLock {
            if recording { recorded.append(contentsOf: samples) }
            recent.append(contentsOf: samples)
            if recent.count > Self.recentLimit * 2 { recent.removeFirst(recent.count - Self.recentLimit) }
        }
        let db = Self.decibels(out)
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        DispatchQueue.main.async { [weak self] in
            self?.levels.mic = level
            self?.onLevel?(db, seconds)
        }
    }

    /// The microphone stays open: whoever is using it closes it, when no longer needed.
    func finishRecording() -> [Float] {
        levels.mic = 0
        return lock.withLock {
            recording = false
            let samples = recorded
            recorded = []
            return samples
        }
    }
}
