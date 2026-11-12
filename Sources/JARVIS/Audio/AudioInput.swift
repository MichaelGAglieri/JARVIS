import AVFoundation
import CoreAudio
import os

/// A single audio engine for the microphone and JARVIS's voice: macOS echo
/// cancellation (voice processing) removes from the microphone only what goes
/// out of the same engine, that is JARVIS's voice. So while it speaks
/// it can hear "Jarvis, basta" even from the speakers.
enum AudioHub {
    private(set) static var engine = makeEngine()
    /// Tests without sound: applies to engines created later too.
    static var muted = false {
        didSet { engine.mainMixerNode.outputVolume = muted ? 0 : 1 }
    }
    /// Whoever has nodes on the engine moves them to the new one; receives the old one.
    static var onReplaced: ((AVAudioEngine) -> Void)?

    private static func makeEngine() -> AVAudioEngine {
        let engine = AVAudioEngine()
        // Output and mixer must be created before turning on echo cancellation,
        // otherwise start-up fails (error -10875).
        _ = engine.outputNode
        _ = engine.mainMixerNode
        return engine
    }

    /// An engine caught in the middle of a device change keeps the old formats and
    /// hears nothing more: as after an app restart, only a new one finds the right ones.
    static func replaceEngine() {
        let old = engine
        old.stop()
        engine = makeEngine()
        if muted { engine.mainMixerNode.outputVolume = 0 }
        onReplaced?(old)
    }
}

/// Captures the microphone and converts it to mono Float32 samples at 16 kHz,
/// the format both Porcupine and Whisper expect.
final class AudioInput {
    static let sampleRate: Double = 16_000

    private var engine: AVAudioEngine { AudioHub.engine }
    private var converter: AVAudioConverter?
    private var mono: AVAudioFormat?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: AudioInput.sampleRate,
                                       channels: 1, interleaved: false)!
    private var configObserver: NSObjectProtocol?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var pendingRebuild: DispatchWorkItem?
    private var watchdog: Timer?
    /// Between `start` and `stop`. In privacy mode the microphone is off and nothing must turn it back on.
    private var wanted = false
    private let lastSound = OSAllocatedUnfairLock<CFAbsoluteTime>(initialState: 0)
    private var failures = 0
    private var nextRetry: CFAbsoluteTime = 0

    /// Called on the audio thread with blocks of 16 kHz samples.
    var onSamples: (([Float]) -> Void)?

    /// Requested by the settings; `echoCancellation` says whether it is really active.
    var wantsEchoCancellation = true
    private(set) var echoCancellation = false

    func start() throws {
        // Repeatable: after a failed attempt it starts clean.
        stopWatching()
        try startWithFallback()
        wanted = true
        startWatching()
    }

    func stop() {
        wanted = false
        stopWatching()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: Device changes

    /// Headphones, AirPods, AirPlay, a microphone change: the engine stops and must be rebuilt. Wait
    /// a second, because macOS goes through intermediate devices before the final one.
    private func startWatching() {
        observeEngine()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRebuild("dispositivo predefinito cambiato")
        }
        deviceListener = listener
        for selector in Self.defaultDevices {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        // The only proof the microphone works is the sound that arrives: if it is missing, reconnect,
        // whatever the reason. A real microphone never gives perfect zeros for seconds.
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkSound() }
        timer.tolerance = 0.5
        watchdog = timer
    }

    private func stopWatching() {
        pendingRebuild?.cancel()
        pendingRebuild = nil
        watchdog?.invalidate()
        watchdog = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let deviceListener {
            for selector in Self.defaultDevices {
                var address = Self.address(selector)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, deviceListener)
            }
        }
        deviceListener = nil
    }

    private func observeEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.scheduleRebuild("configurazione audio cambiata")
        }
    }

    /// When rebuilds come in a row (with AirPods: 88 in six minutes, each start of the microphone
    /// changing the headset's profile again) the wait grows, so the audio can settle.
    private var recentRebuilds: [CFAbsoluteTime] = []

    private func scheduleRebuild(_ reason: String) {
        guard wanted else { return }
        pendingRebuild?.cancel()
        let now = CFAbsoluteTimeGetCurrent()
        recentRebuilds.removeAll { now - $0 > 30 }
        let delay: Double = recentRebuilds.count >= 6 ? 8 : recentRebuilds.count >= 3 ? 3 : 1
        let work = DispatchWorkItem { [weak self] in self?.rebuild(reason) }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func rebuild(_ reason: String) {
        guard wanted else { return }
        pendingRebuild = nil
        // The change did not stop the engine and the format still matches: nothing to rebuild.
        let input = engine.inputNode
        if engine.isRunning, let mono, input.inputFormat(forBus: 0).sampleRate == mono.sampleRate,
           input.outputFormat(forBus: 0).sampleRate == mono.sampleRate {
            Diagnostics.log("audio     \(reason): microfono ancora attivo, nessun riaggancio")
            return
        }
        recentRebuilds.append(CFAbsoluteTimeGetCurrent())
        Diagnostics.log("audio     microfono da riagganciare: \(reason)")
        engine.inputNode.removeTap(onBus: 0)
        // First on the same engine: a new engine closes the microphone for a moment, and with AirPods
        // that close/reopen switches the headset's profile again, which caused the next change (11 November).
        do {
            engine.stop()
            try startWithFallback()
            return
        } catch {
            Diagnostics.log("audio     riaggancio sullo stesso motore non riuscito (\(error.localizedDescription)): motore nuovo")
        }
        engine.inputNode.removeTap(onBus: 0)
        AudioHub.replaceEngine()
        observeEngine()
        do {
            try startWithFallback()
        } catch {
            Diagnostics.log("audio     microfono non riavviato: \(error.localizedDescription)")
        }
    }

    private func checkSound() {
        let now = CFAbsoluteTimeGetCurrent()
        let silence = now - lastSound.withLock { $0 }
        guard silence > 6 else {
            failures = 0
            return
        }
        guard wanted, pendingRebuild == nil, now >= nextRetry else { return }
        failures += 1
        nextRetry = now + min(60, 5 * pow(2, Double(failures - 1)))
        rebuild("nessun suono da \(Int(silence)) s")
    }

    private static let defaultDevices = [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice]

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// Only for test-mode tests: reproduces faults without touching the Mac's settings.
    func debugBreak(_ how: String) {
        switch how {
        case "sordo":
            engine.inputNode.removeTap(onBus: 0)
        case "bgm":
            var uid = "BGMDevice" as CFString
            var device = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var address = Self.address(kAudioHardwarePropertyTranslateUIDToDevice)
            let found = withUnsafeMutablePointer(to: &uid) {
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                           UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
            }
            guard found == noErr, device != 0, let unit = engine.inputNode.audioUnit else {
                Diagnostics.log("audio     prova: Background Music non trovato")
                return
            }
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            Diagnostics.log("audio     prova: motore spostato su Background Music (\(status))")
        default:
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        }
    }

    /// First with echo cancellation; if macOS cannot start it,
    /// fall back to normal listening (as before phase 4).
    private func startWithFallback() throws {
        if wantsEchoCancellation {
            do {
                try installTapAndStart(processVoice: true)
                return
            } catch {
                Diagnostics.log("audio     cancellazione eco non disponibile (\(error.localizedDescription)): ascolto normale")
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
            }
        }
        try installTapAndStart(processVoice: false)
    }

    private func installTapAndStart(processVoice: Bool) throws {
        // AirPods and other Bluetooth headsets drop to 16-24 kHz when their microphone opens.
        // An engine built before still says 48 kHz, and a tap with that stale format makes macOS
        // abort the whole app instead of returning an error (11 November, AirPods 4: 48000 vs 24000).
        // So: compare with the hardware, rebuild the engine once, otherwise give up with an error.
        for attempt in 0..<2 {
            let input = engine.inputNode
            if input.isVoiceProcessingEnabled != processVoice {
                try input.setVoiceProcessingEnabled(processVoice)
            }
            if processVoice, #available(macOS 14.0, *) {
                // Does not duck other apps' music and video while JARVIS listens.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
            let format = input.outputFormat(forBus: 0)
            let hardware = input.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw JarvisError.noMicrophone }
            if hardware.sampleRate > 0, hardware.sampleRate != format.sampleRate {
                Diagnostics.log("audio     formato del microfono cambiato (\(Int(format.sampleRate)) → \(Int(hardware.sampleRate)) Hz)\(attempt == 0 ? ": motore ricostruito" : ": ancora diverso, riprovo più tardi")")
                guard attempt == 0 else { throw JarvisError.noMicrophone }
                input.removeTap(onBus: 0)
                AudioHub.replaceEngine()
                observeEngine()
                continue
            }
            echoCancellation = processVoice
            // With echo cancellation the microphone arrives on several channels (7 on a
            // MacBook Air): the clean voice is the first, the others must not be mixed in.
            let monoFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!
            mono = monoFormat
            converter = AVAudioConverter(from: monoFormat, to: target)
            measuredFrames = 0
            channelEnergy = []
            // Time to start: afterwards, absolute silence means nothing is arriving.
            lastSound.withLock { $0 = CFAbsoluteTimeGetCurrent() }
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.convert(buffer)
            }
            engine.prepare()
            try engine.start()
            Diagnostics.log("audio     microfono \(format.channelCount) canali a \(Int(format.sampleRate)) Hz, cancellazione eco \(processVoice ? "attiva" : "spenta")")
            return
        }
    }

    /// Energy per channel in the first seconds after start-up, written to diagnostica.log.
    private var channelEnergy: [Float] = []
    private var measuredFrames = 0

    private func measure(_ buffer: AVAudioPCMBuffer) {
        guard measuredFrames >= 0, let data = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount), n = Int(buffer.frameLength)
        if channelEnergy.count != channels { channelEnergy = [Float](repeating: 0, count: channels) }
        for c in 0..<channels { for i in 0..<n { channelEnergy[c] += data[c][i] * data[c][i] } }
        measuredFrames += n
        if measuredFrames > Int(buffer.format.sampleRate * 8) {
            let levels = channelEnergy.map { String(format: "%.0f", 10 * log10(max($0 / Float(measuredFrames), 1e-12))) }
            Diagnostics.log("audio     livello per canale (dB): \(levels.joined(separator: " "))")
            measuredFrames = -1
        }
    }

    private func noteSound(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let samples = UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))
        if samples.contains(where: { $0 != 0 }) {
            lastSound.withLock { $0 = CFAbsoluteTimeGetCurrent() }
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) {
        measure(buffer)
        noteSound(buffer)
        guard let converter, let mono, let source = buffer.floatChannelData,
              let first = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
              let firstData = first.floatChannelData else { return }
        first.frameLength = buffer.frameLength
        firstData[0].update(from: source[0], count: Int(buffer.frameLength))
        let ratio = target.sampleRate / mono.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return first
        }
        guard error == nil, let channel = out.floatChannelData, out.frameLength > 0 else { return }
        onSamples?(Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength))))
    }
}

enum JarvisError: LocalizedError {
    case noMicrophone
    case wakeWord(String)
    case ollama(String)

    var errorDescription: String? {
        switch self {
        case .noMicrophone: return "Nessun microfono disponibile"
        case .wakeWord(let m): return "Wake word: \(m)"
        case .ollama(let m): return "Ollama: \(m)"
        }
    }
}
