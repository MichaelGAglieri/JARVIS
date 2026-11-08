import Foundation

/// Counts the hours of study and of work on projects.
/// "Inizio a studiare Chimica" opens a session, "ho finito" closes it.
/// Saved in ~/Library/Application Support/JARVIS/activity.json.
@MainActor
final class ActivityTracker: ObservableObject {
    enum Category: String, Codable { case study, project, other }

    struct Session: Codable {
        var name: String
        var category: Category
        var start: Date
        var end: Date?

        var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }
    }

    @Published private(set) var sessions: [Session] = []
    private let url = JarvisConfig.directory.appendingPathComponent("activity.json")
    /// Sessions forgotten open: beyond this length they are considered closed.
    private let maxSession: TimeInterval = 6 * 3600

    var current: Session? { sessions.last.flatMap { $0.end == nil ? $0 : nil } }

    init() {
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            sessions = (try? decoder.decode([Session].self, from: data)) ?? []
        }
        closeStaleSession()
    }

    // MARK: Commands

    func start(_ name: String, category: Category) -> String {
        var message = ""
        if let open = current {
            message = "Chiusa \"\(open.name)\" dopo \(Self.spoken(open.duration)). "
            stopCurrent()
        }
        sessions.append(Session(name: name, category: category, start: Date()))
        save()
        return message + "Avviata la sessione \"\(name)\" (\(category == .study ? "studio" : category == .project ? "progetto" : "attività"))."
    }

    func stop() -> String {
        guard let open = current else { return "Nessuna sessione in corso" }
        stopCurrent()
        let today = total(from: Calendar.current.startOfDay(for: Date()), category: open.category)
        return "Chiusa \"\(open.name)\" dopo \(Self.spoken(open.duration)). Oggi in totale: \(Self.spoken(today))."
    }

    func report(period: String, category: String?) -> String {
        let calendar = Calendar.current
        let now = Date()
        let from: Date
        switch period.lowercased() {
        case "yesterday", "ieri":
            from = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        case "week", "settimana":
            from = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        case "month", "mese":
            from = calendar.dateInterval(of: .month, for: now)?.start ?? now
        case "all", "tutto":
            from = .distantPast
        default:
            from = calendar.startOfDay(for: now)
        }
        let to = period.lowercased() == "yesterday" || period.lowercased() == "ieri" ? calendar.startOfDay(for: now) : now
        let filter = category.flatMap { Category(rawValue: $0) }
        let relevant = sessions.filter { $0.start < to && ($0.end ?? now) > from && (filter == nil || $0.category == filter) }
        guard !relevant.isEmpty else { return "Nessuna sessione registrata nel periodo \(period)." }

        var byName: [String: TimeInterval] = [:]
        for s in relevant {
            let overlap = min(s.end ?? now, to).timeIntervalSince(max(s.start, from))
            byName[s.name, default: 0] += max(0, overlap)
        }
        let total = byName.values.reduce(0, +)
        let detail = byName.sorted { $0.value > $1.value }.map { "\($0.key): \(Self.spoken($0.value))" }.joined(separator: ", ")
        var out = "Totale \(period): \(Self.spoken(total)). Dettaglio: \(detail)."
        if let open = current { out += " In corso: \"\(open.name)\" da \(Self.spoken(open.duration))." }
        return out
    }

    // MARK: Totals for the HUD

    func total(from: Date, category: Category? = nil) -> TimeInterval {
        let now = Date()
        return sessions
            .filter { ($0.end ?? now) > from && (category == nil || $0.category == category) }
            .reduce(0) { $0 + max(0, ($1.end ?? now).timeIntervalSince(max($1.start, from))) }
    }

    var todayTotal: TimeInterval { total(from: Calendar.current.startOfDay(for: Date())) }
    var weekTotal: TimeInterval { total(from: Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()) }

    // MARK: Internals

    private func stopCurrent() {
        guard let index = sessions.indices.last, sessions[index].end == nil else { return }
        sessions[index].end = Date()
        save()
    }

    private func closeStaleSession() {
        guard let index = sessions.indices.last, sessions[index].end == nil,
              sessions[index].duration > maxSession else { return }
        sessions[index].end = sessions[index].start.addingTimeInterval(maxSession)
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        try? encoder.encode(sessions).write(to: url, options: .atomic)
        Security.protect(url)
    }

    static func spoken(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        let (h, m) = (minutes / 60, minutes % 60)
        if h == 0 { return "\(m) minuti" }
        return m == 0 ? "\(h) ore" : "\(h) ore e \(m) minuti"
    }

    static func clock(_ interval: TimeInterval) -> String {
        let s = Int(interval)
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
