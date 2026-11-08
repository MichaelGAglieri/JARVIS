import Contacts
import Foundation

/// Mail through the Mail app (all the accounts configured there).
/// Reading is free; sending always goes through a spoken confirmation (see Assistant).
enum MailActions {
    private static let field = "‖"   // separator unlikely in email texts

    static func listUnread(_ args: [String: Any]) async -> String {
        let limit = Int(args.number("limit") ?? 10)
        let script = """
        tell application "Mail"
            -- Con una posta grande "whose read status" non finisce mai: il conto è immediato
            -- e i non letti si cercano solo tra i messaggi più recenti, che stanno in cima.
            set total to unread count of inbox
            set out to (total as string) & linefeed
            if total > 0 then
                set shown to 0
                set recent to count of messages of inbox
                if recent > 150 then set recent to 150
                repeat with i from 1 to recent
                    set m to message i of inbox
                    if read status of m is false then
                        set out to out & (id of m) & "\(field)" & (sender of m) & "\(field)" & (subject of m) & "\(field)" & ((date received of m) as string) & linefeed
                        set shown to shown + 1
                        if shown is \(limit) then exit repeat
                    end if
                end repeat
            end if
            return out
        end tell
        """
        let result = await Shell.osascript(script, timeout: args.number("timeout") ?? 25)
        guard result.ok else { return result.err.isEmpty ? "Mail non ha risposto in tempo." : "Errore Mail: \(result.err)" }
        var lines = result.out.split(separator: "\n").map(String.init)
        guard let total = lines.first else { return "Nessuna risposta da Mail" }
        lines.removeFirst()
        if total == "0" { return "Nessuna email non letta." }
        let items = lines.map { line -> String in
            let p = line.components(separatedBy: field)
            guard p.count >= 4 else { return line }
            return "- [id \(p[0])] da \(cleanSender(p[1])): \"\(p[2])\" (\(p[3]))"
        }
        return "Non lette: \(total). Le più recenti:\n" + items.joined(separator: "\n")
    }

    static func search(_ args: [String: Any]) async -> String {
        guard let query = args.string("query") else { return "Ricerca mancante" }
        let q = Shell.quote(query)
        let script = """
        tell application "Mail"
            set msgs to (messages of inbox whose subject contains \(q) or sender contains \(q))
            set n to count of msgs
            if n > 8 then set n to 8
            set out to ""
            repeat with i from 1 to n
                set m to item i of msgs
                set out to out & (id of m) & "\(field)" & (sender of m) & "\(field)" & (subject of m) & "\(field)" & ((date received of m) as string) & linefeed
            end repeat
            return out
        end tell
        """
        let result = await Shell.osascript(script, timeout: 60)
        guard result.ok else { return "Errore Mail: \(result.err)" }
        guard !result.out.isEmpty else { return "Nessuna email trovata per \(query)" }
        return result.out.split(separator: "\n").map { line in
            let p = String(line).components(separatedBy: field)
            guard p.count >= 4 else { return String(line) }
            return "- [id \(p[0])] da \(cleanSender(p[1])): \"\(p[2])\" (\(p[3]))"
        }.joined(separator: "\n")
    }

    static func read(_ args: [String: Any]) async -> String {
        guard let id = args.number("id").map({ Int($0) }) else { return "Serve l'id della mail (da list_unread_emails o search_emails)" }
        let script = """
        tell application "Mail"
            set m to first message of inbox whose id is \(id)
            return (sender of m) & linefeed & (subject of m) & linefeed & ((date received of m) as string) & linefeed & linefeed & (content of m)
        end tell
        """
        let result = await Shell.osascript(script, timeout: 30)
        guard result.ok else { return "Errore leggendo la mail: \(result.err)" }
        let text = result.out.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return String(text.prefix(4000))
    }

    /// Actually sends: called only after the spoken confirmation.
    static func send(to: String, subject: String, body: String) async -> String {
        let script = """
        tell application "Mail"
            set m to make new outgoing message with properties {subject:\(Shell.quote(subject)), content:\(Shell.quote(body)), visible:false}
            tell m to make new to recipient at end of to recipients with properties {address:\(Shell.quote(to))}
            send m
        end tell
        """
        let result = await Shell.osascript(script, timeout: 45)
        return result.ok ? "Email inviata a \(to)" : "Errore inviando: \(result.err)"
    }

    /// "Marco" → email address from Contacts; an address stays as it is.
    static func resolveRecipient(_ value: String) async -> (address: String?, label: String) {
        if value.contains("@") { return (value, value) }
        let store = CNContactStore()
        guard (try? await store.requestAccess(for: .contacts)) == true else { return (nil, value) }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let contacts = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: value), keysToFetch: keys)) ?? []
        guard let contact = contacts.first(where: { !$0.emailAddresses.isEmpty }),
              let email = contact.emailAddresses.first?.value as String? else { return (nil, value) }
        return (email, "\(contact.givenName) \(contact.familyName) <\(email)>".trimmingCharacters(in: .whitespaces))
    }

    private static func cleanSender(_ sender: String) -> String {
        // "Mario Rossi <mario@x.it>" → "Mario Rossi"
        if let range = sender.range(of: " <") { return String(sender[..<range.lowerBound]).replacingOccurrences(of: "\"", with: "") }
        return sender
    }
}
