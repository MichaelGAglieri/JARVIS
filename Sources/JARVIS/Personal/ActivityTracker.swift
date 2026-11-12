import Foundation

/// Counts the hours of study and of work on projects.
/// "Inizio a studiare Chimica" opens a session, "ho finito" closes it.
/// Saved in ~/Library/Application Support/JARVIS/activity.json.
@MainActor
final class ActivityTracker: ObservableObject {
    enum Category: String, Codable { case study, project, other }

    struct Pause: Codable {
        var start: Date
        var end: Date?
        var length: TimeInterval { (end ?? Date()).timeIntervalSince(start) }
    }

    struct Session: Codable {
        var name: String
        var category: Category
        var start: Date
        var end: Date?
        /// Breaks taken during the session (11 November: "pausa" must not close it). Optional for older files.
        var pauses: [Pause]? = nil

        var elapsed: TimeInterval { (end ?? Date()).timeIntervalSince(start) }
        var pausedTime: TimeInterval { (pauses ?? []).reduce(0) { $0 + $1.length } }
        /// Time actually spent studying or working: breaks are not counted.
        var duration: TimeInterval { max(0, elapsed - pausedTime) }
        var isPaused: Bool { pauses?.last.map { $0.end == nil } ?? false }
    }

    /// Last report per session name ("python" → where the user had got to), recalled at the next start.
    struct Report: Codable {
        var date: Date
        var text: String
    }

    @Published private(set) var sessions: [Session] = []
    private let url = JarvisConfig.directory.appendingPathComponent("activity.json")
    /// Sessions forgotten open: beyond this length they are considered closed.
    private let maxSession: TimeInterval = 6 * 3600

    var current: Session? { sessions.last.flatMap { $0.end == nil ? $0 : nil } }
    private let reportsURL = JarvisConfig.directory.appendingPathComponent("resoconti.json")
    private var reports: [String: Report] = [:]

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url) {
            sessions = (try? decoder.decode([Session].self, from: data)) ?? []
        }
        if let data = try? Data(contentsOf: reportsURL) {
            reports = (try? decoder.decode([String: Report].self, from: data)) ?? [:]
        }
        closeStaleSession()
    }

    private static func key(_ name: String) -> String {
        name.lowercased().folding(options: .diacriticInsensitive, locale: nil).trimmingCharacters(in: .whitespaces)
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
        message += "Avviata la sessione \"\(name)\" (\(category == .study ? "studio" : category == .project ? "progetto" : "attività"))."
        if let last = reports[Self.key(name)] {
            let day = last.date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "it_IT")))
            message += " Resoconto dell'ultima sessione (\(day)): \(last.text). Remind the user briefly where they had got to."
        }
        return message
    }

    func stop() -> String {
        guard let open = current else { return "Nessuna sessione in corso" }
        stopCurrent()
        let closed = sessions.last ?? open
        let today = total(from: Calendar.current.startOfDay(for: Date()), category: open.category)
        let count = closed.pauses?.count ?? 0
        let breaks = count == 0 ? "nessuna pausa" : count == 1 ? "1 pausa (\(Self.spoken(closed.pausedTime)))" : "\(count) pause (\(Self.spoken(closed.pausedTime)) in tutto)"
        return "Chiusa \"\(open.name)\" dopo \(Self.spoken(closed.duration)) di lavoro effettivo su \(Self.spoken(closed.elapsed)) complessivi, \(breaks). Oggi in totale: \(Self.spoken(today))."
            + " Now ask the user what to write in the report of this session (e.g. \"Cosa scriviamo nel resoconto?\") and save their answer with save_session_report."
    }

    /// "Facciamo una pausa": the session stays open, the break is counted apart.
    func pause() -> String {
        guard let index = sessions.indices.last, sessions[index].end == nil else { return "Nessuna sessione in corso" }
        guard !sessions[index].isPaused else { return "La sessione \"\(sessions[index].name)\" è già in pausa." }
        sessions[index].pauses = (sessions[index].pauses ?? []) + [Pause(start: Date())]
        save()
        return "Sessione \"\(sessions[index].name)\" in pausa dopo \(Self.spoken(sessions[index].duration)) di lavoro (pausa numero \(sessions[index].pauses?.count ?? 1))."
    }

    func resume() -> String {
        guard let index = sessions.indices.last, sessions[index].end == nil else { return "Nessuna sessione in corso" }
        guard sessions[index].isPaused, var pauses = sessions[index].pauses else { return "La sessione \"\(sessions[index].name)\" non è in pausa." }
        pauses[pauses.count - 1].end = Date()
        sessions[index].pauses = pauses
        save()
        let s = sessions[index]
        return "Sessione \"\(s.name)\" ripresa. Finora \(Self.spoken(s.duration)) di lavoro su \(Self.spoken(s.elapsed)) complessivi, \(pauses.count) \(pauses.count == 1 ? "pausa" : "pause")."
    }

    func saveReport(_ text: String, name: String?) -> String {
        guard let name = name ?? sessions.last?.name else { return "Nessuna sessione a cui legare il resoconto." }
        reports[Self.key(name)] = Report(date: Date(), text: text)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        try? encoder.encode(reports).write(to: reportsURL, options: .atomic)
        Security.protect(reportsURL)
        return "Resoconto di \"\(name)\" salvato: lo ricorderò alla prossima sessione."
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
        let now = Date()
        if sessions[index].isPaused, var pauses = sessions[index].pauses {
            pauses[pauses.count - 1].end = now
            sessions[index].pauses = pauses
        }
        sessions[index].end = now
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
