import Foundation

/// Long-term memory: facts about the user JARVIS must remember from one
/// session to the next (deadlines, preferences, people, project details).
/// Saved in ~/Library/Application Support/JARVIS/memory.json.
@MainActor
final class MemoryStore: ObservableObject {
    struct Fact: Codable, Identifiable {
        var id = UUID()
        var text: String
        var created = Date()
    }

    @Published private(set) var facts: [Fact] = []
    private let url = JarvisConfig.directory.appendingPathComponent("memory.json")

    init() {
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            facts = (try? decoder.decode([Fact].self, from: data)) ?? []
        }
    }

    func remember(_ text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "Niente da ricordare" }
        if facts.contains(where: { $0.text.caseInsensitiveCompare(clean) == .orderedSame }) { return "Lo sapevo già" }
        facts.append(Fact(text: clean))
        if facts.count > 120 { facts.removeFirst(facts.count - 120) }
        save()
        return "Memorizzato: \(clean)"
    }

    func forget(_ query: String) -> String {
        let q = query.lowercased()
        let matches = facts.filter { $0.text.lowercased().contains(q) }
        guard !matches.isEmpty else { return "Nessun ricordo contiene \"\(query)\"" }
        facts.removeAll { $0.text.lowercased().contains(q) }
        save()
        return "Dimenticato: " + matches.map(\.text).joined(separator: "; ")
    }

    func list() -> String {
        facts.isEmpty ? "Nessun ricordo salvato" : facts.map { "- \($0.text)" }.joined(separator: "\n")
    }

    /// Block to insert into the model's instructions.
    var promptBlock: String {
        guard !facts.isEmpty else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "Things you remember about him (saved on the date shown):\n"
            + facts.suffix(80).map { "- [\(formatter.string(from: $0.created))] \($0.text)" }.joined(separator: "\n")
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        try? encoder.encode(facts).write(to: url, options: .atomic)
        Security.protect(url)
    }
}
