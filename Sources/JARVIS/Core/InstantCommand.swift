import Foundation

/// Simple commands that do not need the model: opening and quitting apps, volume, timers.
/// Only the whole sentence counts: "apri Safari e cerca il meteo" does not match and goes to the model.
enum InstantCommand: Equatable {
    case open(String)
    case close(String)
    case setVolume(Int)
    case changeVolume(Int)
    case mute(Bool)
    case timer(seconds: Int, label: String?)
    case printerStatus
    case filament(load: Bool)
    case time
    case music(MusicAction)
    case tv(on: Bool)

    enum MusicAction: String { case pause, play, next, previous, status }

    static func parse(_ raw: String) -> InstantCommand? {
        let text = clean(raw)
        guard !text.isEmpty else { return nil }
        return time(text) ?? music(text) ?? television(text) ?? filament(text) ?? printer(text) ?? volume(text) ?? timer(text) ?? app(text)
    }

    /// Lowercase, without punctuation at the ends and without "jarvis" and "per favore".
    private static func clean(_ raw: String) -> String {
        var text = raw.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: ",", with: " ")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".!?;: ").union(.whitespacesAndNewlines))
        text = text.split(separator: " ").joined(separator: " ")
        if text.hasPrefix("jarvis ") { text.removeFirst(7) }
        for polite in [" per favore", " per piacere", " please"] where text.hasSuffix(polite) { text.removeLast(polite.count) }
        return text
    }

    // MARK: Music

    private static let musicPhrases: [MusicAction: Set<String>] = [
        .pause: ["pausa", "metti in pausa", "metti in pausa la musica", "metti la musica in pausa", "ferma la musica", "stoppa la musica",
                 "spegni la musica", "pause", "pause the music", "stop the music"],
        .play: ["riprendi", "riprendi la musica", "fai ripartire la musica", "fai ripartire", "riparti", "continua la musica",
                "togli la pausa", "resume", "resume the music"],
        .next: ["prossima canzone", "canzone successiva", "prossimo brano", "brano successivo", "salta", "salta questa", "salta canzone",
                "salta questa canzone", "salta il brano", "cambia canzone", "next song", "next track", "skip", "skip this song"],
        .previous: ["canzone precedente", "brano precedente", "torna alla canzone precedente", "torna al brano precedente",
                    "metti la canzone di prima", "previous song", "previous track"],
        .status: ["che canzone è", "che canzone è questa", "che canzone e", "che canzone e questa", "che brano è", "che brano è questo",
                  "che brano e", "che brano e questo", "cosa sta suonando", "cos'è questa canzone", "what song is this", "what's playing"],
    ]

    private static func music(_ text: String) -> InstantCommand? {
        musicPhrases.first { $0.value.contains(text) }.map { .music($0.key) }
    }

    // MARK: TV

    private static func television(_ text: String) -> InstantCommand? {
        let names = ["la tv", "la televisione", "tv", "televisione", "the tv"]
        if names.flatMap({ ["accendi \($0)", "turn on \($0)"] }).contains(text) { return .tv(on: true) }
        if names.flatMap({ ["spegni \($0)", "turn off \($0)"] }).contains(text) { return .tv(on: false) }
        return nil
    }

    // MARK: Printer

    /// "A che punto è la stampa?", not "stampa questo documento".
    private static func printer(_ text: String) -> InstantCommand? {
        let asksItalian = ["a che punto", "come va", "quanto manca", "stato", "percentuale"].contains { text.contains($0) }
        let asksEnglish = ["status", "how is", "how's", "how long", "progress"].contains { text.contains($0) }
        return (text.contains("stampa") && asksItalian) || (text.contains("print") && asksEnglish) ? .printerStatus : nil
    }

    /// The time comes from the clock: the model, reading "01:13", ended up saying "le ventuno e tredici".
    private static func time(_ text: String) -> InstantCommand? {
        let phrases = ["che ore sono", "che ora e", "che ora è", "sai che ore sono", "mi dici che ore sono", "mi dici che ora e", "mi dici che ora è",
                       "what time is it", "whats the time", "what is the time"]
        return phrases.contains(text) ? .time : nil
    }

    /// "Sono le quindici e tredici", "È l'una e cinque", "È mezzanotte": without digits, which the voice may misread.
    static func spokenTime(_ date: Date, italian: Bool) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let (hour, minute) = (parts.hour ?? 0, parts.minute ?? 0)
        guard italian else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_GB")
            formatter.dateFormat = "h:mm a"
            return "It's \(formatter.string(from: date))"
        }
        let start: String
        switch hour {
        case 0: start = "È mezzanotte"
        case 1: start = "È l'una"
        case 12: start = "È mezzogiorno"
        default: start = "Sono le \(italianNumber(hour))"
        }
        return minute == 0 ? start : "\(start) e \(italianNumber(minute))"
    }

    private static func italianNumber(_ n: Int) -> String {
        let units = ["", "uno", "due", "tre", "quattro", "cinque", "sei", "sette", "otto", "nove", "dieci", "undici", "dodici", "tredici",
                     "quattordici", "quindici", "sedici", "diciassette", "diciotto", "diciannove"]
        guard n >= 20 else { return units[max(0, min(n, 19))] }
        let tens = ["venti", "trenta", "quaranta", "cinquanta"][min(n / 10 - 2, 3)]
        let unit = n % 10
        // "ventuno" and "ventotto" lose the vowel, "ventitré" takes the accent.
        if unit == 1 || unit == 8 { return String(tens.dropLast()) + units[unit] }
        return tens + (unit == 3 ? "tré" : units[unit])
    }

    /// "Scarica il filamento", not "come si carica il filamento?". "scarica" contains "carica": it comes first.
    private static func filament(_ text: String) -> InstantCommand? {
        guard text.contains("filament"), text.split(separator: " ").count <= 6 else { return nil }
        guard !["come", "perché", "perche", "quanto", "quando", "dove", "how", "why", "when", "where"].contains(where: { text.contains($0) }) else { return nil }
        if ["scarica", "togli", "rimuovi", "unload", "remove"].contains(where: { text.contains($0) }) { return .filament(load: false) }
        if ["carica", "inserisci", "load"].contains(where: { text.contains($0) }) { return .filament(load: true) }
        return nil
    }

    // MARK: Apps

    private static let openVerbs = ["apri", "aprimi", "avvia", "lancia", "open", "launch"]
    private static let closeVerbs = ["chiudi", "chiudimi", "close", "quit"]
    /// These words point to something else (a file, a tab, two actions): the model decides.
    private static let otherThings: Set<String> = [
        "e", "ed", "poi", "su", "in", "con", "per", "nel", "nella", "nei", "dentro", "a", "al", "alla", "da", "dal", "del", "della", "che",
        "and", "then", "on", "with", "for", "from", "to", "of", "at",
        "file", "cartella", "progetto", "sito", "pagina", "documento", "link", "video", "scheda", "schede", "finestra", "finestre",
        "tutto", "tutte", "tutti", "questa", "questo", "quella", "quello", "mia", "mio", "ultima", "ultimo",
        "all", "everything", "this", "that", "my", "tab", "window", "folder", "project", "page",
    ]

    /// How Whisper mangles verbs right after "Jarvis". The app name is checked anyway.
    private static let heardAsOpen: Set<String> = ["abri", "abre", "apre", "appri", "aprii", "apra", "aprei", "aprì", "avri", "avrei", "avre"]
    private static let heardAsClose: Set<String> = ["qd", "kiudi", "ciudi", "giudi", "chiude", "chiudo", "chiuda"]

    /// The word is an "apri" or a "chiudi", even mangled or stuck to the name.
    static func isAppVerb(_ word: String) -> Bool {
        normalizedVerb([word]).first.map { openVerbs.contains($0) || closeVerbs.contains($0) } ?? false
    }

    /// "apricalcolatrice" → "apri calcolatrice"; "qd calcolatrice" → "chiudi calcolatrice".
    private static func normalizedVerb(_ words: [String]) -> [String] {
        guard let first = words.first else { return words }
        if heardAsOpen.contains(first) { return ["apri"] + words.dropFirst() }
        if heardAsClose.contains(first) { return ["chiudi"] + words.dropFirst() }
        for verb in ["apri", "chiudi"] where first.hasPrefix(verb) && first.count >= verb.count + 3 && !["aprimi", "chiudimi"].contains(first) {
            return [verb, String(first.dropFirst(verb.count))] + words.dropFirst()
        }
        return words
    }

    private static func app(_ text: String) -> InstantCommand? {
        let words = normalizedVerb(text.split(separator: " ").map(String.init))
        guard let verb = words.first, words.count >= 2, words.count <= 5 else { return nil }
        let isOpen = openVerbs.contains(verb)
        guard isOpen || closeVerbs.contains(verb) else { return nil }
        let name = words.dropFirst()
        guard !name.contains(where: { otherThings.contains($0) || $0.contains(".") }) else { return nil }
        let joined = withoutArticle(name.joined(separator: " "))
        // "Avvia il robot" is a command for the robot: it does not open Robot Console.
        guard !joined.isEmpty, joined != "robot", joined != "app" else { return nil }
        return isOpen ? .open(joined) : .close(joined)
    }

    private static func withoutArticle(_ name: String) -> String {
        var name = name
        for lead in ["l'applicazione ", "l'app ", "applicazione ", "app ", "il programma ", "programma "] where name.hasPrefix(lead) {
            name.removeFirst(lead.count)
        }
        for article in ["il ", "lo ", "la ", "le ", "gli ", "i ", "the ", "l'"] where name.hasPrefix(article) {
            name.removeFirst(article.count)
            break
        }
        return name
    }

    // MARK: Volume

    private static func volume(_ text: String) -> InstantCommand? {
        let mutes = ["muto", "metti il muto", "metti in muto", "silenzia", "silenzia l'audio", "silenzia il volume", "togli l'audio", "mute", "mute the sound", "mute the volume"]
        if mutes.contains(text) { return .mute(true) }
        if ["togli il muto", "riattiva l'audio", "rimetti l'audio", "unmute", "unmute the sound"].contains(text) { return .mute(false) }

        let target = "(?:il volume|volume|l'audio|audio|the volume)"
        if captures(text, "^(?:alza|aumenta|metti|porta) \(target) al massimo$") != nil || text == "volume al massimo" { return .setVolume(100) }
        let little = "(?:un po' |un poco )?"
        if let m = captures(text, "^(?:alza|aumenta|turn up|raise) \(little)\(target)(?: up)?(?: un po'| un poco)?(?: di (.+))?$") {
            return step(m.first, sign: 1)
        }
        if let m = captures(text, "^(?:abbassa|diminuisci|turn down|lower) \(little)\(target)(?: down)?(?: un po'| un poco)?(?: di (.+))?$") {
            return step(m.first, sign: -1)
        }
        if ["più volume", "volume più alto", "volume su", "turn the volume up", "volume up"].contains(text) { return .changeVolume(10) }
        if ["meno volume", "volume più basso", "volume giù", "turn the volume down", "volume down"].contains(text) { return .changeVolume(-10) }
        if let m = captures(text, "^(?:(?:metti|imposta|porta|set) )?\(target) (?:al |a |all'|to |at )?(.+?)(?: ?%| per cento| percent)?$"),
           let value = m.first.flatMap(number), (0...100).contains(value) {
            return .setVolume(value)
        }
        return nil
    }

    private static func step(_ amount: String?, sign: Int) -> InstantCommand? {
        guard let amount else { return .changeVolume(10 * sign) }
        let digits = amount.replacingOccurrences(of: " per cento", with: "").replacingOccurrences(of: "%", with: "")
        return number(digits).map { .changeVolume($0 * sign) }
    }

    // MARK: Timers

    private static func timer(_ text: String) -> InstantCommand? {
        guard let m = captures(text, "^(?:(?:imposta|metti|avvia|fai partire|fai|set|start) )?(?:un |a )?timer (?:di |da |per |for |of )?(.+?)(?: (?:per|for) (.+))?$"),
              let duration = m.first.flatMap(seconds), duration > 0 else { return nil }
        return .timer(seconds: duration, label: m.count > 1 ? m[1] : nil)
    }

    /// "25 minuti", "un'ora e mezza", "1 ora e 30 minuti". The whole text must be a duration.
    private static func seconds(_ text: String) -> Int? {
        if text == "mezz'ora" || text == "half an hour" { return 1800 }
        var total = 0, lastUnit = 0
        let parts = text.replacingOccurrences(of: "un'ora", with: "1 ora")
            .replacingOccurrences(of: " and ", with: " e ").components(separatedBy: " e ")
        for part in parts {
            if ["mezza", "mezzo", "a half"].contains(part), lastUnit > 0 { total += lastUnit / 2; continue }
            let words = part.split(separator: " ").map(String.init)
            guard words.count == 2, let value = number(words[0]), let unit = unitSeconds[words[1]] else { return nil }
            total += value * unit
            lastUnit = unit
        }
        return total
    }

    private static let unitSeconds = ["ora": 3600, "ore": 3600, "hour": 3600, "hours": 3600, "minuto": 60, "minuti": 60, "minute": 60,
                                      "minutes": 60, "secondo": 1, "secondi": 1, "second": 1, "seconds": 1]

    /// How a duration is said aloud.
    static func spoken(seconds total: Int, italian: Bool) -> String {
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        var parts: [String] = []
        if h > 0 { parts.append(italian ? "\(h) \(h == 1 ? "ora" : "ore")" : "\(h) \(h == 1 ? "hour" : "hours")") }
        if m > 0 { parts.append(italian ? "\(m) \(m == 1 ? "minuto" : "minuti")" : "\(m) \(m == 1 ? "minute" : "minutes")") }
        if s > 0 { parts.append(italian ? "\(s) \(s == 1 ? "secondo" : "secondi")" : "\(s) \(s == 1 ? "second" : "seconds")") }
        return parts.joined(separator: italian ? " e " : " and ")
    }

    // MARK: Numbers

    private static let units = ["un": 1, "uno": 1, "una": 1, "due": 2, "tre": 3, "quattro": 4, "cinque": 5, "sei": 6, "sette": 7, "otto": 8, "nove": 9,
                                "dieci": 10, "undici": 11, "dodici": 12, "tredici": 13, "quattordici": 14, "quindici": 15, "sedici": 16,
                                "diciassette": 17, "diciotto": 18, "diciannove": 19, "cento": 100,
                                "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
                                "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60]
    private static let tens = ["venti": 20, "trenta": 30, "quaranta": 40, "cinquanta": 50, "sessanta": 60, "settanta": 70, "ottanta": 80, "novanta": 90]

    private static func number(_ word: String) -> Int? {
        let word = word.trimmingCharacters(in: .whitespaces)
        if let value = Int(word) { return value }
        if let value = units[word] { return value }
        for (name, value) in tens {
            if word == name { return value }
            // "ventuno", "trentotto" lose the vowel; "venticinque" does not.
            let stem = String(name.dropLast())
            guard word.hasPrefix(stem) else { continue }
            let rest = String(word.dropFirst(stem.count))
            for candidate in [rest, String(rest.dropFirst())] {
                if let unit = units[candidate == "tre" || candidate == "tré" ? "tre" : candidate], unit < 10 { return value + unit }
            }
        }
        return nil
    }

    private static func captures(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
}
