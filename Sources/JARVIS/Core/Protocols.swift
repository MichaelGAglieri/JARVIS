import Foundation

/// One phrase, several actions. They live in protocolli.json, so they can be changed without rebuilding.
struct JarvisProtocol {
    struct Step {
        let tool: String
        let arguments: [String: Any]
    }

    let name: String
    /// Whole phrases. With "*" at the end the rest of the phrase becomes {resto}.
    let phrases: [String]
    let before: [Step]
    /// If set, the model answers with this request.
    let ask: String?
    /// When it has finished speaking.
    let after: [Step]
    /// Answer without the model; {esito} is the outcome of the first action.
    let reply: String?
    /// "sintetico": a sequence of actions. JARVIS does not narrate the steps, it says only how it ended.
    var brief = false

    func matching(_ text: String) -> String? {
        for phrase in phrases {
            if phrase.hasSuffix(" *") {
                let start = String(phrase.dropLast(2))
                if text == start { return "" }
                if text.hasPrefix(start + " ") { return String(text.dropFirst(start.count + 1)) }
            } else if text == phrase {
                return ""
            }
        }
        return nil
    }
}

enum Protocols {
    private static let file = JarvisConfig.directory.appendingPathComponent("protocolli.json")

    private static let defaults: [[String: Any]] = [
        ["nome": "studio",
         "frasi": ["modalità studio *", "protocollo studio *", "attiva la modalità studio *", "attiva modalità studio *", "study mode"],
         "prima": [["tool": "start_activity", "arguments": ["name": "{resto}", "category": "study"]],
                   ["tool": "open_path", "arguments": ["path": "~/Documents/Appunti"]],
                   ["tool": "set_timer", "arguments": ["seconds": 1500, "label": "studio"]]],
         "risposta": "Modalità studio attiva, signore. Timer di venticinque minuti avviato."],
        ["nome": "fine studio",
         "frasi": ["fine studio", "fine modalità studio", "esci dalla modalità studio", "termina la modalità studio", "ho finito di studiare"],
         "prima": [["tool": "stop_activity", "arguments": [:]],
                   ["tool": "cancel_timer", "arguments": ["label": "studio"]]],
         "risposta": "{esito}"],
        ["nome": "buongiorno",
         "frasi": ["buongiorno", "protocollo buongiorno", "good morning"],
         "chiedi": "Buongiorno. Protocollo buongiorno: usa daily_briefing e printer_status, poi dimmi in poche frasi la giornata: meteo, impegni, promemoria, mail importanti, e la stampa solo se ce n'è una in corso."],
        ["nome": "buonanotte",
         "frasi": ["buonanotte", "protocollo buonanotte", "good night"],
         "prima": [["tool": "stop_activity", "arguments": [:]]],
         "chiedi": "Buonanotte. Protocollo buonanotte: guarda con list_events e list_reminders cosa ho domani e dimmelo in due frasi. Se non ho niente dillo. Non fare altre azioni.",
         "dopo": [["tool": "sleep_display", "arguments": [:]]]],
    ]

    /// JARVIS writes the file the first time; if it cannot be read the defaults apply.
    static func load() -> [JarvisProtocol] {
        if !FileManager.default.fileExists(atPath: file.path),
           let data = try? JSONSerialization.data(withJSONObject: defaults, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: file, options: .atomic)
            Security.protect(file)
        }
        let raw = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? defaults
        return raw.compactMap { item in
            guard let name = item["nome"] as? String, let phrases = item["frasi"] as? [String] else { return nil }
            func steps(_ key: String) -> [JarvisProtocol.Step] {
                (item[key] as? [[String: Any]] ?? []).compactMap { step in
                    (step["tool"] as? String).map { JarvisProtocol.Step(tool: $0, arguments: step["arguments"] as? [String: Any] ?? [:]) }
                }
            }
            return JarvisProtocol(name: name, phrases: phrases.map { clean($0) }, before: steps("prima"), ask: item["chiedi"] as? String,
                                  after: steps("dopo"), reply: item["risposta"] as? String, brief: item["sintetico"] as? Bool ?? false)
        }
    }

    static func match(_ raw: String) -> (JarvisProtocol, String)? {
        let text = clean(raw)
        for item in load() {
            if let rest = item.matching(text) { return (item, rest) }
        }
        return nil
    }

    /// Lowercase, without punctuation and without "jarvis" at the start or end.
    static func clean(_ raw: String) -> String {
        var text = raw.lowercased().replacingOccurrences(of: ",", with: " ")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".!?;: ").union(.whitespacesAndNewlines))
        text = text.split(separator: " ").joined(separator: " ")
        if text.hasPrefix("jarvis ") { text.removeFirst(7) }
        if text.hasSuffix(" jarvis") { text.removeLast(7) }
        return text
    }
}
