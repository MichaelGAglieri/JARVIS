import Foundation

/// Flashcards in schede.json. Box-based repetition (Leitner): a right answer sees the card
/// again later and later, a wrong one sees it tomorrow. Nothing is deleted without asking.
@MainActor
final class Flashcards {
    struct Card: Codable {
        var id: Int
        var topic: String
        var question: String
        var answer: String
        var source: String
        var box = 0
        var due = Date()
    }

    private static let intervals = [1, 2, 4, 8, 16, 32]
    private let url = JarvisConfig.directory.appendingPathComponent("schede.json")
    private lazy var cards: [Card] = {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Card].self, from: data)) ?? []
    }()

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(cards) else { return }
        try? data.write(to: url, options: .atomic)
        Security.protect(url)
    }

    /// `json` is a list of {question, answer, source}: without a source in the notes the card is not added.
    func add(topic: String, json: String) -> String {
        guard let data = json.data(using: .utf8), let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return "Le schede non sono in un formato valido."
        }
        var added = 0, skipped = 0
        var next = (cards.map(\.id).max() ?? 0) + 1
        for item in list {
            guard let question = (item["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty,
                  let answer = (item["answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty,
                  let source = (item["source"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty,
                  !cards.contains(where: { $0.question.caseInsensitiveCompare(question) == .orderedSame }) else {
                skipped += 1
                continue
            }
            cards.append(Card(id: next, topic: topic, question: question, answer: answer, source: source))
            next += 1
            added += 1
        }
        save()
        return "Salvate \(added) schede su \(topic)" + (skipped > 0 ? ", \(skipped) scartate perché doppie o senza fonte." : ".")
    }

    /// The cards to review today, the most overdue first. The answer is for the model: it says it only afterwards.
    func due(topic: String?, limit: Int) -> String {
        let now = Date()
        let found = cards.filter { $0.due <= now && matches($0, topic) }.sorted { ($0.box, $0.due) < ($1.box, $1.due) }
        guard !found.isEmpty else {
            let total = cards.filter { matches($0, topic) }.count
            // Without cards the quiz must not stop: it moves on to the notes.
            let fallback = " Se ti ha chiesto di interrogarlo, cerca con search_notes e fai le domande dagli appunti, senza fermarti."
            return (total == 0 ? "Nessuna scheda salvata\(topic.map { " su \($0)" } ?? "")." : "Nessuna scheda da rivedere oggi: sono \(total), tutte in regola.") + fallback
        }
        let lines = found.prefix(max(1, min(limit, 30))).map { "#\($0.id) [\($0.topic), \($0.source)] D: \($0.question) R: \($0.answer)" }
        return "Da rivedere: \(found.count). Fai una domanda alla volta, senza dire la risposta prima.\n" + lines.joined(separator: "\n")
    }

    func grade(id: Int, correct: Bool) -> String {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return "Scheda \(id) non trovata." }
        cards[index].box = correct ? min(cards[index].box + 1, Self.intervals.count - 1) : 0
        let days = Self.intervals[cards[index].box]
        cards[index].due = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        save()
        return "Scheda \(id): da rivedere tra \(days) \(days == 1 ? "giorno" : "giorni")."
    }

    func summary() -> String {
        guard !cards.isEmpty else { return "Nessuna scheda salvata." }
        let now = Date()
        let topics = Dictionary(grouping: cards, by: \.topic).sorted { $0.key < $1.key }.map { topic, list in
            "\(topic): \(list.count), da rivedere \(list.filter { $0.due <= now }.count), imparate bene \(list.filter { $0.box >= 3 }.count)"
        }
        return topics.joined(separator: "\n")
    }

    private func matches(_ card: Card, _ topic: String?) -> Bool {
        guard let topic, !topic.isEmpty else { return true }
        return card.topic.range(of: topic, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
