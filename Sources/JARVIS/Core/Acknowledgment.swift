import Foundation

/// The sentence JARVIS says at once, while the model works: "Subito, signore".
/// It is decided from the words of the request, without waiting for the model.
enum Acknowledgment {
    enum Kind { case action, lookup }

    private static let italianAction = ["Subito, signore.", "Come desidera, signore.", "Eseguo, signore.",
                                        "Certamente, signore.", "Provvedo subito, signore.", "Agli ordini, signore."]
    private static let italianLookup = ["Un attimo, signore.", "Controllo subito, signore.", "Verifico, signore.", "Vediamo, signore."]
    private static let englishAction = ["Right away, sir.", "As you wish, sir.", "Certainly, sir.", "On it, sir."]
    private static let englishLookup = ["One moment, sir.", "Checking now, sir.", "Let me look, sir."]

    static func stillWorking(italian: Bool) -> String {
        italian ? "Ancora un istante, signore." : "Nearly there, sir."
    }

    /// All the sentences, kept ready so they start without waiting.
    static var allPhrases: [(text: String, italian: Bool)] {
        (italianAction + italianLookup + [stillWorking(italian: true)]).map { ($0, true) }
            + (englishAction + englishLookup + [stillWorking(italian: false)]).map { ($0, false) }
    }

    static func phrase(_ kind: Kind, italian: Bool, avoiding last: String?) -> String {
        let list: [String]
        switch (kind, italian) {
        case (.action, true): list = italianAction
        case (.lookup, true): list = italianLookup
        case (.action, false): list = englishAction
        case (.lookup, false): list = englishLookup
        }
        return list.filter { $0 != last }.randomElement() ?? list[0]
    }

    private static let social: Set<String> = ["ciao", "buongiorno", "buonasera", "buonanotte", "salve", "grazie", "perfetto", "ottimo", "bravo", "ok", "okay",
                                              "hello", "hi", "hey", "thanks", "thank", "goodnight"]
    private static let socialStarts = ["come stai", "come va", "va bene", "tutto bene", "good morning", "good evening", "good night", "good afternoon", "how are you"]
    private static let questionWords: Set<String> = ["che", "cosa", "cos", "come", "quanto", "quanta", "quanti", "quante", "quando", "dove",
                                                     "perché", "perche", "chi", "qual", "quale", "quali",
                                                     "what", "whats", "how", "when", "where", "why", "who", "which"]
    private static let lookupVerbs: Set<String> = ["dimmi", "dirmi", "dici", "controlla", "controllami", "cerca", "cercami", "trova", "trovami",
                                                   "leggi", "leggimi", "mostra", "mostrami", "spiega", "spiegami", "riassumi", "guarda", "verifica", "calcola", "traduci",
                                                   "tell", "check", "search", "find", "read", "show", "explain", "summarise", "summarize", "look", "calculate", "translate"]
    private static let actionVerbs: Set<String> = ["apri", "chiudi", "imposta", "metti", "avvia", "ferma", "lancia", "esegui", "manda", "invia", "scrivi",
                                                   "crea", "aggiungi", "prepara", "segna", "ricordami", "fissa", "programma", "sposta", "rinomina", "copia",
                                                   "compila", "carica", "attiva", "disattiva", "spegni", "accendi", "alza", "abbassa", "riproduci", "suona",
                                                   "prenota", "collega", "connetti", "salva", "fai", "fammi", "minimizza", "riduci", "nascondi", "inizia", "riavvia", "cambia", "passa", "stampa",
                                                   "open", "close", "set", "put", "start", "run", "send", "write", "create", "add", "prepare", "schedule",
                                                   "remind", "move", "rename", "copy", "compile", "upload", "turn", "raise", "lower", "play", "connect", "save", "make", "print", "minimize", "minimise", "hide"]
    private static let polite: Set<String> = ["per", "favore", "please", "mi", "ti", "prego", "kindly"]
    private static let modals = ["puoi", "potresti", "può", "potrebbe", "vorrei", "voglio", "mi serve", "ho bisogno",
                                 "can you", "could you", "would you", "will you", "i want", "i need", "id like"]

    /// nil: a greeting, a thank-you or a single word, which just gets an answer.
    /// If the sentence is not understood (Whisper may mangle it) the acknowledgment stays: better than silence.
    static func kind(of command: String) -> Kind? {
        var words = command.lowercased()
            .replacingOccurrences(of: "'", with: " ").replacingOccurrences(of: "’", with: " ")
            .components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        if words.first == "jarvis" { words.removeFirst() }
        // A long word is often a glued sentence: "apricalcolatrice".
        guard let first = words.first, words.count >= 2 || first.count >= 8, !social.contains(first) else { return nil }
        let joined = words.joined(separator: " ")
        if socialStarts.contains(where: { joined.hasPrefix($0) }) { return nil }
        while let next = words.first, polite.contains(next), words.count > 1 { words.removeFirst() }
        let text = words.joined(separator: " ")
        if let modal = modals.first(where: { text == $0 || text.hasPrefix($0 + " ") }) {
            let rest = text.dropFirst(modal.count).split(separator: " ").map(String.init).filter { !polite.contains($0) }
            return rest.first.map(lookupVerbs.contains) == true ? .lookup : .action
        }
        guard let verb = words.first else { return nil }
        if questionWords.contains(verb) || lookupVerbs.contains(verb) { return .lookup }
        return actionVerbs.contains(verb) || InstantCommand.isAppVerb(verb) ? .action : .lookup
    }

    private static let bareWords: Set<String> = ["certamente", "subito", "come", "desidera", "signore", "eseguo", "provvedo", "agli", "ordini",
                                                 "certainly", "sir", "right", "away", "as", "you", "wish", "on", "it", "of", "course"]

    /// The model repeated the acknowledgment already said: "Certamente, signore." and nothing else.
    static func isBare(_ sentence: String) -> Bool {
        let words = sentence.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        return !words.isEmpty && words.count <= 5 && words.allSatisfy(bareWords.contains)
    }
}
