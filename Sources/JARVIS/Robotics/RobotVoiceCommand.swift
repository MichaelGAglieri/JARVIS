import Foundation

/// Whole-phrase commands only. Questions, multi-actions and ambiguous numbers
/// are left to the normal conversation; nothing is inferred from a substring.
enum RobotVoiceCommand: Equatable {
    case enable, close, home, sequence(String?)
    case joint(Int, Double, absolute: Bool)

    static func parse(_ raw: String, consoleInFront: Bool = false) -> RobotVoiceCommand? {
        var text = raw.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?;: ").union(.whitespacesAndNewlines))
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if text.hasPrefix("jarvis") { text = String(text.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: ", ")) }
        for suffix in [" per favore", " per piacere", " jarvis"] where text.hasSuffix(suffix) { text.removeLast(suffix.count) }
        // How Whisper wrote these phrases on 9 November: "Abilità robot", "E segui sequenzo", "segui sequenza".
        text = text.replacingOccurrences(of: "abilità", with: "abilita").replacingOccurrences(of: "sequenzo", with: "sequenza")
        if text.hasPrefix("e segui ") { text = "esegui " + text.dropFirst(8) }
        if text.hasPrefix("segui ") { text = "e" + text }
        if ["abilita robot", "abilita il robot", "abilita i robot", "abilitare il robot", "abilita il braccio", "abilita il braccio robotico", "attiva il robot", "protocollo robot"].contains(text) { return .enable }
        if ["chiudi robot console", "chiudi l'app robot console", "chiudi l'applicazione robot console", "chiudi la console del robot", "qd robot console"].contains(text) { return .close }
        if consoleInFront, ["chiudi l'applicazione", "chiudi l'app", "chiudi questa applicazione"].contains(text) { return .close }
        // "Jarvis torna a Dom": Whisper's spelling of "torna a home" on 10 November.
        let homeVerbs = #"(torna|tornare|ritorna|vai|riporta il robot|riporta il braccio|riportati|porta il robot|porta il braccio)"#
        if text.range(of: "^" + homeVerbs + #"( a| in| alla| al| nella)? (home|hom|om|ohm|dom|posizione home|posizione iniziale)$"#, options: .regularExpression) != nil { return .home }
        let prefixes = ["fai sequenza", "fai la sequenza", "esegui la sequenza", "esegui sequenza", "avvia la sequenza", "avvia sequenza", "riproduci la sequenza", "fai partire la sequenza", "esegui la posa", "fai la posa"]
        for prefix in prefixes {
            if text == prefix { return .sequence(nil) }
            if text.hasPrefix(prefix + " ") { return .sequence(String(text.dropFirst(prefix.count + 1))) }
        }
        let pattern = #"^(muovi|sposta|ruota|porta) (?:il )?(?:giunto )?(?:j\s*|giunto\s+)([1-6]|uno|due|tre|quattro|cinque|sei) (di|a) (.+?) (?:gradi|grado|°)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ n: Int) -> String { Range(match.range(at: n), in: text).map { String(text[$0]) } ?? "" }
        guard let joint = number(group(2)), let degrees = number(group(4)), abs(degrees) <= 360 else { return nil }
        return .joint(Int(joint), degrees, absolute: group(3) == "a")
    }

    /// While the arm moves, any short phrase with one of these words stops it, without
    /// "Jarvis". Whole words only; "non fermarti" and long phrases are not a STOP.
    /// `echo`: what JARVIS is saying right now, so its own voice from the speakers does not count.
    static func isMotionStop(_ raw: String, echo: String? = nil) -> Bool {
        let fold = { (s: String) in s.lowercased().folding(options: .diacriticInsensitive, locale: nil) }
        let words = fold(raw).components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= 8, !words.contains("non"), !words.contains("don") else { return false }
        let echoed = Set(fold(echo ?? "").components(separatedBy: CharacterSet.letters.inverted))
        let stops: Set<String> = ["stop", "stopp", "stoppa", "stoppati", "basta", "ferma", "fermati", "fermo", "fermalo",
                                  "fermatevi", "alt", "halt", "arresta", "arrestati", "blocca", "bloccati", "emergenza", "enough"]
        return words.contains { stops.contains($0) && !echoed.contains($0) }
    }

    private static func number(_ raw: String) -> Double? {
        var text = raw.replacingOccurrences(of: ",", with: ".")
        var sign = 1.0
        if text.hasPrefix("meno ") { sign = -1; text.removeFirst(5) }
        else if text.hasPrefix("più ") { text.removeFirst(4) }
        if let value = Double(text), value.isFinite { return sign * value }
        let small = ["zero", "uno", "due", "tre", "quattro", "cinque", "sei", "sette", "otto", "nove", "dieci", "undici", "dodici", "tredici", "quattordici", "quindici", "sedici", "diciassette", "diciotto", "diciannove"]
        if let i = small.firstIndex(of: text) { return sign * Double(i) }
        text = text.replacingOccurrences(of: "é", with: "e")
        for (i, tens) in ["venti", "trenta", "quaranta", "cinquanta", "sessanta", "settanta", "ottanta", "novanta"].enumerated() {
            if text == tens { return sign * Double((i + 2) * 10) }
            for unit in 1...9 {
                let prefix = (unit == 1 || unit == 8) ? String(tens.dropLast()) : tens
                if text == prefix + small[unit] { return sign * Double((i + 2) * 10 + unit) }
            }
        }
        return nil
    }

    var tool: String {
        switch self { case .enable: return "robot_enable"; case .close: return "robot_close"; case .home: return "robot_home"; case .sequence: return "robot_sequence"; case .joint: return "robot_joint" }
    }
    var arguments: [String: Any] {
        switch self {
        case .enable, .close, .home: return [:]
        case .sequence(let name): return name.map { ["name": $0] } ?? [:]
        case .joint(let joint, let degrees, let absolute): return ["joint": joint, "degrees": degrees, "mode": absolute ? "absolute" : "relative"]
        }
    }
}
