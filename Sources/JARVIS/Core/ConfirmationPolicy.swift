import Foundation

/// When an action inside an app asks for the "yes". User rule (8 November 2026): only for three things,
/// everything else runs at once, robot moves included.
/// 1. buying or paying; 2. a password; 3. sending an email (in the Mail app or similar).
/// Typing into a password field stays forbidden anyway, elsewhere.
enum ConfirmationPolicy {
    private static let purchaseStems = [
        "compra", "acquista", "acquisto", "paga", "pagamento", "abbonati", "abbonamento", "ordina",
        "buy", "purchase", "payment", "checkout", "subscribe", "order",
    ]
    private static let purchaseExact: Set<String> = ["pay"]
    private static let passwordWords = ["password", "passcode", "parola chiave"]
    private static let sendStems = ["invia", "manda", "spedisci", "send"]
    /// Mail apps: there "Invia" sends an email.
    private static let mailApps = ["com.apple.mail", "mail ", "outlook", "gmail", "spark", "airmail", "mimestream"]

    private static func words(_ text: String) -> [String] {
        text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
    }

    static func isMail(identity: String) -> Bool {
        let text = identity.lowercased() + " "
        return mailApps.contains { text.contains($0) }
    }

    /// `identity`: the app's name and identifier.
    static func isRisky(_ label: String, identity: String) -> Bool {
        let list = words(label)
        let lower = label.lowercased()
        if list.contains(where: { w in purchaseExact.contains(w) || purchaseStems.contains { w.hasPrefix($0) && w.count - $0.count <= 4 } }) { return true }
        if passwordWords.contains(where: lower.contains) { return true }
        // "Inviati" is a folder: opening it sends nothing.
        let sends = list.contains { w in !["inviati", "inviato", "inviata", "inviate", "sent"].contains(w) && sendStems.contains { w.hasPrefix($0) && w.count - $0.count <= 4 } }
        return sends && isMail(identity: identity)
    }

    /// Return sends only in an email's window.
    static func sendsOnReturn(identity: String) -> Bool { isMail(identity: identity) }

    static func keyIsRisky(_ combo: String, identity: String) -> Bool {
        let parts = combo.split(separator: "+").map(String.init)
        // ⇧⌘D and ⌘Return send in Mail.
        guard isMail(identity: identity) else { return false }
        return combo == "cmd+shift+d" || combo == "shift+cmd+d" || ((parts.contains("return") || parts.contains("enter")) && parts.contains("cmd"))
    }
}
