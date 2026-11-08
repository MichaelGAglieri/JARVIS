import Foundation

/// Finds an app even if Whisper mangled its name: "PDF Graft", "Pide Fer Kraft" → PdfCraft.
/// Compares names by how they sound. If two apps are close it does not guess: it suggests both.
enum AppIndex {
    enum Match: Equatable {
        case found(String)
        case ambiguous([String])
        case none(similar: [String])
    }

    /// From here up the name is the right one, if no other is close to it.
    private static let sure = 0.70
    private static let margin = 0.10
    private static let similarFloor = 0.45

    /// Words around the name, including "l'app", which Whisper writes "LAP".
    private static let fillers: Set<String> = ["app", "lapp", "lap", "applicazione", "lapplicazione", "programma", "il", "la", "lo", "l", "the", "gioco"]

    /// How letters are pronounced in Italian, for acronyms: PDF → "pi di effe".
    private static let letters: [Character: String] = [
        "a": "a", "b": "bi", "c": "ci", "d": "di", "e": "e", "f": "effe", "g": "gi", "h": "acca", "i": "i", "j": "i",
        "k": "kappa", "l": "elle", "m": "emme", "n": "enne", "o": "o", "p": "pi", "q": "cu", "r": "erre", "s": "esse",
        "t": "ti", "u": "u", "v": "vu", "w": "vu", "x": "ics", "y": "i", "z": "zeta",
    ]

    /// With a higher `sure` only an almost certain name is accepted: instant commands have no model checking.
    static func resolve(_ query: String, among names: [String], sure: Double = AppIndex.sure) -> Match {
        let wanted = key(query, dropFillers: true)
        guard !wanted.isEmpty else { return .none(similar: []) }
        // The exact name always wins: "Notes" is not Notes+.
        let spoken = query.trimmingCharacters(in: .whitespaces).lowercased()
        if let exact = names.first(where: { $0.lowercased() == spoken }) ?? names.first(where: { plain($0) == plain(query) }) {
            return .found(exact)
        }
        let scored = names.map { (name: $0, score: score(wanted, query: query, name: $0)) }.sorted { $0.score > $1.score }
        guard let best = scored.first else { return .none(similar: []) }
        let close = scored.filter { $0.score >= similarFloor }.prefix(4).map(\.name)
        guard best.score >= sure else { return .none(similar: close) }
        let rivals = scored.filter { $0.score >= sure && best.score - $0.score < margin }.map(\.name)
        return rivals.count == 1 ? .found(best.name) : .ambiguous(Array(rivals.prefix(5)))
    }

    /// How much an app's name resembles the requested one, from 0 to 1.
    private static func score(_ wanted: String, query: String, name: String) -> Double {
        var result = distinctiveSimilarity(wanted, key(name, dropFillers: false))
        // A whole piece of the name is enough: "Isaac" for The Binding of Isaac, "Power Point" for Microsoft PowerPoint.
        let parts = words(name)
        for start in parts.indices {
            for end in start..<parts.count where parts[start...end].joined().count >= 4 {
                let similarity = similarity(wanted, key(parts[start...end].joined(separator: " "), dropFillers: false))
                if similarity >= 0.8 { result = max(result, 0.9 * similarity) }
            }
        }
        return result
    }

    /// With many apps ending the same way (…Craft) the different part counts most.
    private static func distinctiveSimilarity(_ a: String, _ b: String) -> Double {
        let whole = similarity(a, b)
        // Already almost equal ("Saund Kraft", "SoundCraft"): removing the common part would skew the count.
        if whole >= 0.85 { return whole }
        var x = Array(a), y = Array(b), shared = 0
        while let last = x.last, last == y.last { x.removeLast(); y.removeLast(); shared += 1 }
        guard shared >= 4, !x.isEmpty, !y.isEmpty else { return whole }
        return 0.4 * whole + 0.6 * similarity(String(x), String(y))
    }

    private static func similarity(_ a: String, _ b: String) -> Double {
        let longest = max(a.count, b.count)
        return longest == 0 ? 0 : 1 - Double(distance(Array(a), Array(b))) / Double(longest)
    }

    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var previous = row[0]
            row[0] = i + 1
            for (j, y) in b.enumerated() {
                let current = row[j + 1]
                row[j + 1] = min(current + 1, row[j] + 1, previous + (x == y ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }

    private static func plain(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The words of the name, also joined ones: "PdfCraft" → Pdf, Craft; "CADCraft" → CAD, Craft.
    private static func words(_ text: String) -> [String] {
        var result: [String] = [], current = ""
        let characters = Array(text)
        for (i, c) in characters.enumerated() {
            guard c.isLetter || c.isNumber else {
                if !current.isEmpty { result.append(current); current = "" }
                continue
            }
            let startsWord = c.isUppercase && !current.isEmpty
                && (current.last!.isLowercase || (i + 1 < characters.count && characters[i + 1].isLowercase))
            if startsWord { result.append(current); current = "" }
            current.append(c)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// The name as it sounds: spelled-out acronyms, c/k/q/g equal (Craft and Graft), double letters simplified.
    private static func key(_ text: String, dropFillers: Bool) -> String {
        var parts = words(text).map { $0.folding(options: .diacriticInsensitive, locale: nil) }
        if dropFillers {
            let kept = parts.filter { !fillers.contains($0.lowercased()) }
            if !kept.isEmpty { parts = kept }
        }
        return parts.map(sound).joined()
    }

    private static func sound(_ word: String) -> String {
        var text = word.lowercased()
        // An acronym without vowels is read letter by letter: PDF, HTML.
        if text.count >= 2, text.allSatisfy({ $0.isLetter }), !text.contains(where: { "aeiouy".contains($0) }) {
            text = text.map { letters[$0] ?? String($0) }.joined()
        }
        for (from, to) in [("ph", "f"), ("ch", "k"), ("sh", "s"), ("gh", "g"), ("x", "ks")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        var result = ""
        for c in text where c != "h" {
            let mapped: Character
            switch c {
            case "c", "q", "g": mapped = "k"
            case "y": mapped = "i"
            case "w": mapped = "v"
            case "z": mapped = "s"
            default: mapped = c
            }
            if result.last != mapped { result.append(mapped) }
        }
        return result
    }
}
