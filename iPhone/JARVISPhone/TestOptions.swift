import AVFoundation
import Foundation

/// Automatic tests, active only on the simulator: on a real phone these arguments do not exist.
/// The arguments say which Mac to connect to and what to ask, without microphone or speakers,
/// and the log ends up in Documents/prova.log.
@MainActor
final class TestOptions {
    private(set) var muted = false
    private(set) var code: String?
    private(set) var host: String?
    /// Sentences to send one after another, separated by "||", each when the previous one has finished.
    private var script: [String] = []
    /// After how many seconds to press stop.
    private var stopAfter: Double?
    private var awaitingAnswer = false
    private var audioPath: String?
    private var started = false
    private let file: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("prova.log")
    private var clipCount = 0

    init() {
        #if targetEnvironment(simulator)
        let a = CommandLine.arguments
        func value(_ name: String) -> String? {
            guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
            return a[i + 1]
        }
        muted = a.contains("--muted")
        code = value("--test-code")
        host = value("--test-host")
        script = value("--test-text")?.components(separatedBy: "||") ?? []
        stopAfter = value("--test-stop").flatMap(Double.init)
        audioPath = value("--test-audio")
        if let file { try? FileManager.default.removeItem(at: file) }
        #endif
    }

    func log(_ line: String) {
        #if targetEnvironment(simulator)
        guard let file else { return }
        let row = "\(Date().timeIntervalSince1970) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(row.utf8))
            try? handle.close()
        } else {
            try? row.write(to: file, atomically: true, encoding: .utf8)
        }
        #endif
    }

    func connected(_ assistant: Assistant) {
        #if targetEnvironment(simulator)
        log("benvenuto")
        guard !started else { return }
        started = true
        if CommandLine.arguments.contains("--test-watch") { assistant.startWatching() }
        if let i = CommandLine.arguments.firstIndex(of: "--test-ear"), i + 1 < CommandLine.arguments.count {
            hear(CommandLine.arguments[i + 1], assistant)
        }
        becameIdle(assistant)
        if let stopAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + stopAfter) {
                self.log("premo stop")
                assistant.stop()
            }
        }
        if let audioPath, let samples = Self.load(audioPath) {
            log("mando audio, \(samples.count) campioni")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { assistant.sendTestAudio(samples) }
        }
        #endif
    }

    /// A file instead of the microphone, at the same speed as speech.
    private func hear(_ path: String, _ assistant: Assistant) {
        #if targetEnvironment(simulator)
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            log("file non letto: \(path)")
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            log("inizio file")
            // "--test-heard 2.5:Jarvis che ore|4:Jarvis annulla": what the recogniser would have understood, and when.
            if let j = CommandLine.arguments.firstIndex(of: "--test-heard"), j + 1 < CommandLine.arguments.count {
                for step in CommandLine.arguments[j + 1].split(separator: "|") {
                    let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2, let at = Double(parts[0]) else { continue }
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(at))
                        assistant.testEarHeard(parts[1])
                    }
                }
            }
            // "--test-control 3:click:0.5:0.5|4:type:ciao|5:key:return": commands on the Mac screen.
            if let j = CommandLine.arguments.firstIndex(of: "--test-control"), j + 1 < CommandLine.arguments.count {
                for step in CommandLine.arguments[j + 1].split(separator: "|") {
                    let p = step.split(separator: ":").map(String.init)
                    guard let at = Double(p[0]) else { continue }
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(at))
                        switch p[1] {
                        case "type": assistant.typeOnMac(p[2])
                        case "key": assistant.pressOnMac(p[2])
                        case "scroll": assistant.pointer("scroll", x: Double(p[2])!, y: Double(p[3])!, amount: Int(p[4]))
                        default: assistant.pointer(p[1], x: Double(p[2])!, y: Double(p[3])!)
                        }
                    }
                }
            }
            // "--test-tap 0.1:0.1": microphone tap after some time, for how long.
            if let j = CommandLine.arguments.firstIndex(of: "--test-tap"), j + 1 < CommandLine.arguments.count {
                for step in CommandLine.arguments[j + 1].split(separator: "|") {
                    let parts = step.split(separator: ":").map(String.init)
                    guard parts.count == 2, let at = Double(parts[0]), let hold = Double(parts[1]) else { continue }
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(at))
                        assistant.micPressed()
                        try? await Task.sleep(for: .seconds(hold))
                        assistant.micReleased()
                    }
                }
            }
            let block = AVAudioFrameCount(file.processingFormat.sampleRate * 0.05)
            while let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: block), (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 {
                assistant.testHearFile(buffer, converter: converter)
                try? await Task.sleep(for: .milliseconds(50))
            }
            log("fine file")
        }
        #endif
    }

    func becameIdle(_ assistant: Assistant) {
        #if targetEnvironment(simulator)
        // The "idle" state that arrives right after connecting does not mean the sentence is over.
        guard started, !awaitingAnswer, !script.isEmpty else { return }
        awaitingAnswer = true
        let next = script.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.log("mando: \(next)")
            assistant.send(text: next)
        }
        #endif
    }

    func becameBusy() {
        awaitingAnswer = false
    }

    /// Keeps the received sentence to check later that it is real voice.
    func savedClip(_ clip: PhoneClip) {
        #if targetEnvironment(simulator)
        clipCount += 1
        log("voce \(clip.id): \(String(format: "%.1f", clip.duration)) s a \(clip.sampleRate) Hz")
        guard let folder = file?.deletingLastPathComponent(),
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(clip.sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clip.samples.count)),
              let output = try? AVAudioFile(forWriting: folder.appendingPathComponent("voce\(clipCount).wav"), settings: format.settings) else { return }
        buffer.frameLength = AVAudioFrameCount(clip.samples.count)
        clip.samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: clip.samples.count) }
        try? output.write(from: buffer)
        #endif
    }

    private static func load(_ path: String) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: source)) != nil,
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 64)
        else { return nil }
        var used = false
        converter.convert(to: out, error: nil) { _, status in
            if used {
                status.pointee = .endOfStream
                return nil
            }
            used = true
            status.pointee = .haveData
            return source
        }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}
