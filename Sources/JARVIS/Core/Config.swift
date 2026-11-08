import Foundation

/// JARVIS's persistent settings, saved in
/// ~/Library/Application Support/JARVIS/config.json.
/// Every key missing from the file takes its default value, so new
/// versions of the app can add options without breaking old ones.
struct JarvisConfig: Codable, Equatable {
    var userName = "Utente"
    /// Full name and one line about who you are, in English: they go into the instructions (a few words).
    /// Empty, they are not mentioned.
    var userFullName = ""
    var userAbout = ""
    /// After how many misunderstood requests in a row JARVIS asks Claude Opus for help.
    var learnAfterFailures = 2
    /// Initiative (phase 3): alerts JARVIS gives by itself.
    /// App control (Accessibility permission): only with Claude.
    var appControl = true
    /// Touch ID (or the Mac password) after the "yes" for delicate actions.
    var ownerCheck = true
    /// Voiceprint on "Jarvis": "off", "observe" (measures and does not block) or "on".
    var voiceCheck = "observe"
    var voiceThreshold: Float = 0.6
    var alertCalendar = true
    /// Phase 4: "Jarvis, basta" interrupts it while it speaks.
    var bargeIn = true
    /// macOS echo cancellation on the microphone. Off: on a MacBook Air it makes the
    /// microphone almost mute (-68 dB) and "Jarvis" is no longer heard.
    var echoCancellation = false
    var alertReminders = true
    var alertStudy = true
    var alertBattery = true
    var morningBriefing = true
    /// The briefing starts at the first activation between these hours (5–12).
    var briefingFrom = 5
    var briefingUntil = 12
    /// Quiet hours: no alerts from `quietFrom` to `quietTo`.
    var quietFrom = 23
    var quietTo = 8
    var picovoiceAccessKey = ""
    var wakeSensitivity: Float = 0.55
    /// Continuous listening for "Jarvis" with a small Whisper (free, no keys).
    var whisperWake = true
    /// Test mode for development (commands with the key from dev_token). Turn it off when development is done.
    var developerMode = false
    /// Dark shaded disc behind the NUCLEUS (off: it blends completely with the wallpaper).
    var nucleusBackdrop = true
    var whisperModel = "openai_whisper-large-v3-v20240930_turbo_632MB"
    var localModel = "gemma4:12b-it-qat"
    var ollamaURL = "http://localhost:11434"
    var englishVoice = "Jamie"
    var italianVoice = "Luca"
    var speechRate: Float = 0.5
    var followUpConversation = false
    var greetOnLaunch = true
    var historyTurns = 12
    /// Time after which the local model is removed from RAM if you do not use it.
    var modelKeepAlive = "30m"
    /// Below this percentage of free RAM the local model is unloaded.
    var memoryUnloadBelow = 20
    /// "local" (Ollama) or "claude" (Claude Code with the subscription).
    var brain = "local"
    var claudeModel = "sonnet"
    /// Words Whisper must spell correctly (names, acronyms): they are given to it
    /// as context before every transcription. You can add your own.
    var vocabulary = "Jarvis, Claude, Sonnet, Opus, Haiku, Gemma, ROS 2, Arduino, Bambu Studio, Robot Console."
    /// Kokoro neural voice (if installed); otherwise Apple voices.
    var neuralVoice = true
    var kokoroEnglishVoice = "bm_lewis"
    /// Blend chosen by the user: Nicola with a third of Fable, livelier but with an Italian accent.
    var kokoroItalianVoice = "im_nicola:0.65+bm_fable:0.35"
    var kokoroSpeed = 1.0
    /// User's choice: faster and one semitone higher, less dark.
    var kokoroItalianSpeed = 1.2
    /// Pitch in cents of a semitone (100 = one semitone higher).
    var kokoroItalianPitch: Float = 100
    var kokoroEnglishPitch: Float = 0
    /// Italian voice chosen by the user: half M4 and half M3 of Supertonic. Empty = Kokoro.
    var supertonicItalianVoice = "M4:0.5+M3:0.5"
    var supertonicItalianSpeed = 1.2
    /// Italian voice chosen by the user: Qwen3 imitating the voice in Resources/voce_jarvis.wav.
    var qwenItalian = true
    var qwenItalianSpeed = 1.0
    /// Bambu printer on the home network. Empty = off.
    var bambuHost = ""
    var bambuSerial = ""
    var bambuCode = ""
    /// Folders searched by notes search. They must be chosen: personal documents stay out.
    /// Link with the iPhone app: off until the user turns it on.
    var phoneBridge = false
    var notesFolders = ["~/Documents/Appunti"]
    /// ROS 2 project of the simulated lab (pixi environment with Webots).
    var labProject = "~/Projects/ros2_lab"

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("JARVIS", isDirectory: true)
        // Only the user can enter JARVIS's folder.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }()

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    static func load() -> JarvisConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(JarvisConfig.self, from: data) else {
            let config = JarvisConfig()
            config.save()
            return config
        }
        return config
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
        // The file holds the Picovoice key: readable only by the user.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = JarvisConfig()
        userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? d.userName
        picovoiceAccessKey = try c.decodeIfPresent(String.self, forKey: .picovoiceAccessKey) ?? d.picovoiceAccessKey
        wakeSensitivity = try c.decodeIfPresent(Float.self, forKey: .wakeSensitivity) ?? d.wakeSensitivity
        whisperWake = try c.decodeIfPresent(Bool.self, forKey: .whisperWake) ?? d.whisperWake
        developerMode = try c.decodeIfPresent(Bool.self, forKey: .developerMode) ?? d.developerMode
        nucleusBackdrop = try c.decodeIfPresent(Bool.self, forKey: .nucleusBackdrop) ?? d.nucleusBackdrop
        whisperModel = try c.decodeIfPresent(String.self, forKey: .whisperModel) ?? d.whisperModel
        localModel = try c.decodeIfPresent(String.self, forKey: .localModel) ?? d.localModel
        ollamaURL = try c.decodeIfPresent(String.self, forKey: .ollamaURL) ?? d.ollamaURL
        englishVoice = try c.decodeIfPresent(String.self, forKey: .englishVoice) ?? d.englishVoice
        italianVoice = try c.decodeIfPresent(String.self, forKey: .italianVoice) ?? d.italianVoice
        speechRate = try c.decodeIfPresent(Float.self, forKey: .speechRate) ?? d.speechRate
        followUpConversation = try c.decodeIfPresent(Bool.self, forKey: .followUpConversation) ?? d.followUpConversation
        greetOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .greetOnLaunch) ?? d.greetOnLaunch
        historyTurns = try c.decodeIfPresent(Int.self, forKey: .historyTurns) ?? d.historyTurns
        modelKeepAlive = try c.decodeIfPresent(String.self, forKey: .modelKeepAlive) ?? d.modelKeepAlive
        // Configurations saved before the memory check (v1.3.1): the model
        // goes from 5 to 30 minutes in RAM, once.
        if !c.contains(.memoryUnloadBelow) && modelKeepAlive == "5m" { modelKeepAlive = d.modelKeepAlive }
        memoryUnloadBelow = try c.decodeIfPresent(Int.self, forKey: .memoryUnloadBelow) ?? d.memoryUnloadBelow
        brain = try c.decodeIfPresent(String.self, forKey: .brain) ?? d.brain
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? d.claudeModel
        vocabulary = try c.decodeIfPresent(String.self, forKey: .vocabulary) ?? d.vocabulary
        userFullName = try c.decodeIfPresent(String.self, forKey: .userFullName) ?? d.userFullName
        userAbout = try c.decodeIfPresent(String.self, forKey: .userAbout) ?? d.userAbout
        learnAfterFailures = try c.decodeIfPresent(Int.self, forKey: .learnAfterFailures) ?? d.learnAfterFailures
        appControl = try c.decodeIfPresent(Bool.self, forKey: .appControl) ?? d.appControl
        ownerCheck = try c.decodeIfPresent(Bool.self, forKey: .ownerCheck) ?? d.ownerCheck
        voiceCheck = try c.decodeIfPresent(String.self, forKey: .voiceCheck) ?? d.voiceCheck
        voiceThreshold = try c.decodeIfPresent(Float.self, forKey: .voiceThreshold) ?? d.voiceThreshold
        alertCalendar = try c.decodeIfPresent(Bool.self, forKey: .alertCalendar) ?? d.alertCalendar
        bargeIn = try c.decodeIfPresent(Bool.self, forKey: .bargeIn) ?? d.bargeIn
        echoCancellation = try c.decodeIfPresent(Bool.self, forKey: .echoCancellation) ?? d.echoCancellation
        alertReminders = try c.decodeIfPresent(Bool.self, forKey: .alertReminders) ?? d.alertReminders
        alertStudy = try c.decodeIfPresent(Bool.self, forKey: .alertStudy) ?? d.alertStudy
        alertBattery = try c.decodeIfPresent(Bool.self, forKey: .alertBattery) ?? d.alertBattery
        morningBriefing = try c.decodeIfPresent(Bool.self, forKey: .morningBriefing) ?? d.morningBriefing
        briefingFrom = try c.decodeIfPresent(Int.self, forKey: .briefingFrom) ?? d.briefingFrom
        briefingUntil = try c.decodeIfPresent(Int.self, forKey: .briefingUntil) ?? d.briefingUntil
        quietFrom = try c.decodeIfPresent(Int.self, forKey: .quietFrom) ?? d.quietFrom
        quietTo = try c.decodeIfPresent(Int.self, forKey: .quietTo) ?? d.quietTo
        neuralVoice = try c.decodeIfPresent(Bool.self, forKey: .neuralVoice) ?? d.neuralVoice
        kokoroEnglishVoice = try c.decodeIfPresent(String.self, forKey: .kokoroEnglishVoice) ?? d.kokoroEnglishVoice
        kokoroItalianVoice = try c.decodeIfPresent(String.self, forKey: .kokoroItalianVoice) ?? d.kokoroItalianVoice
        kokoroSpeed = try c.decodeIfPresent(Double.self, forKey: .kokoroSpeed) ?? d.kokoroSpeed
        kokoroItalianSpeed = try c.decodeIfPresent(Double.self, forKey: .kokoroItalianSpeed) ?? d.kokoroItalianSpeed
        kokoroItalianPitch = try c.decodeIfPresent(Float.self, forKey: .kokoroItalianPitch) ?? d.kokoroItalianPitch
        kokoroEnglishPitch = try c.decodeIfPresent(Float.self, forKey: .kokoroEnglishPitch) ?? d.kokoroEnglishPitch
        supertonicItalianVoice = try c.decodeIfPresent(String.self, forKey: .supertonicItalianVoice) ?? d.supertonicItalianVoice
        supertonicItalianSpeed = try c.decodeIfPresent(Double.self, forKey: .supertonicItalianSpeed) ?? d.supertonicItalianSpeed
        qwenItalian = try c.decodeIfPresent(Bool.self, forKey: .qwenItalian) ?? d.qwenItalian
        qwenItalianSpeed = try c.decodeIfPresent(Double.self, forKey: .qwenItalianSpeed) ?? d.qwenItalianSpeed
        bambuHost = try c.decodeIfPresent(String.self, forKey: .bambuHost) ?? d.bambuHost
        bambuSerial = try c.decodeIfPresent(String.self, forKey: .bambuSerial) ?? d.bambuSerial
        bambuCode = try c.decodeIfPresent(String.self, forKey: .bambuCode) ?? d.bambuCode
        phoneBridge = try c.decodeIfPresent(Bool.self, forKey: .phoneBridge) ?? d.phoneBridge
        notesFolders = try c.decodeIfPresent([String].self, forKey: .notesFolders) ?? d.notesFolders
        labProject = try c.decodeIfPresent(String.self, forKey: .labProject) ?? d.labProject
    }
}

/// The app's bundle identifier, written into Info.plist by the build
/// (`JARVIS_BUNDLE_ID` in local.env). It prefixes the test and nucleus notifications.
let jarvisBundleID = Bundle.main.bundleIdentifier ?? "com.example.jarvis"

enum Language: String {
    case italian = "it"
    case english = "en"

    var label: String { self == .italian ? "IT" : "EN" }
}
