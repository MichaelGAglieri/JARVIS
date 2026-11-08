import EventKit
import Foundation

/// Calendar and Reminders through EventKit (the same data as Apple's apps, iCloud included).
final class CalendarActions {
    private let store = EKEventStore()
    private var eventsGranted = false
    private var remindersGranted = false

    private func ensureEvents() async -> Bool {
        if eventsGranted { return true }
        eventsGranted = (try? await store.requestFullAccessToEvents()) ?? false
        return eventsGranted
    }

    private func ensureReminders() async -> Bool {
        if remindersGranted { return true }
        remindersGranted = (try? await store.requestFullAccessToReminders()) ?? false
        return remindersGranted
    }

    private static let noAccess = "Accesso negato: abilita JARVIS in Impostazioni di Sistema › Privacy e sicurezza."

    // MARK: Events

    func listEvents(_ args: [String: Any]) async -> String {
        guard await ensureEvents() else { return Self.noAccess }
        let start = Calendar.current.startOfDay(for: DateArg.parse(args["start_date"]) ?? Date())
        let days = Int(args.number("days") ?? 1)
        let end = Calendar.current.date(byAdding: .day, value: max(1, days), to: start)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        guard !events.isEmpty else { return "Nessun appuntamento dal \(DateArg.spoken(start, allDay: true)) per \(days) giorni." }
        return events.prefix(25).map { e in
            var line = "- \(e.title ?? "Senza titolo"): " + (e.isAllDay ? "\(DateArg.spoken(e.startDate, allDay: true)), tutto il giorno"
                                                                       : "\(DateArg.spoken(e.startDate)) – \(e.endDate.formatted(date: .omitted, time: .shortened))")
            if let location = e.location, !location.isEmpty { line += ", presso \(location)" }
            return line
        }.joined(separator: "\n")
    }

    func createEvent(_ args: [String: Any]) async -> String {
        guard await ensureEvents() else { return Self.noAccess }
        guard let title = args.string("title"), let start = DateArg.parse(args["start"]) else {
            return "Servono titolo e data di inizio (formato YYYY-MM-DDTHH:MM)"
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        if let end = DateArg.parse(args["end"]) {
            event.endDate = end
        } else {
            event.endDate = start.addingTimeInterval((args.number("duration_minutes") ?? 60) * 60)
        }
        event.isAllDay = args.bool("all_day") ?? false
        event.location = args.string("location")
        event.notes = args.string("notes")
        event.calendar = store.defaultCalendarForNewEvents
        event.addAlarm(EKAlarm(relativeOffset: -15 * 60))
        do {
            try store.save(event, span: .thisEvent)
            return "Creato \"\(title)\" \(DateArg.spoken(start)) nel calendario \(event.calendar.title)"
        } catch {
            return "Errore creando l'evento: \(error.localizedDescription)"
        }
    }

    /// Finds the event to delete. It deletes nothing by itself: with a single event
    /// it asks for spoken confirmation, with several it asks to choose.
    func prepareDeleteEvent(_ args: [String: Any]) async -> ToolOutcome {
        guard await ensureEvents() else { return .result(Self.noAccess) }
        guard let query = args.string("title")?.lowercased(), !query.isEmpty else { return .result("Titolo mancante") }
        let day = DateArg.parse(args["date"])
        let exactTime = (args.string("date") ?? "").contains("T")
        let start = Calendar.current.startOfDay(for: day ?? Date())
        let end = Calendar.current.date(byAdding: .day, value: day == nil ? 60 : 1, to: start)!
        let matches = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { ($0.title ?? "").lowercased().contains(query) }
            // With the time, two events with the same title on the same day can be told apart.
            .filter { e in !exactTime || day.map { abs(e.startDate.timeIntervalSince($0)) < 60 } == true }
            .sorted { $0.startDate < $1.startDate }
        let spoken = { (e: EKEvent) in "\"\(e.title ?? "Senza titolo")\" \(DateArg.spoken(e.startDate, allDay: e.isAllDay))" }
        guard let event = matches.first else {
            return .result("Nessun evento corrisponde a \"\(query)\" " + (day == nil ? "nei prossimi 60 giorni." : "in quel giorno."))
        }
        guard matches.count == 1 else {
            let list = matches.prefix(10).map { "- " + spoken($0) }.joined(separator: "\n")
            return .result("Nulla eliminato: più eventi corrispondono. Chiedi all'utente quale, poi richiama con titolo completo, data e ora.\n" + list)
        }
        guard event.calendar.allowsContentModifications else {
            return .result("Il calendario \(event.calendar.title) è di sola lettura: non posso eliminare questo evento.")
        }
        let recurring = event.hasRecurrenceRules ? " (solo questa volta, le altre ripetizioni restano)" : ""
        return .needsConfirmation(PendingAction(summary: "Eliminare " + spoken(event) + recurring) { [store] in
            do {
                try store.remove(event, span: .thisEvent)
                return "Eliminato " + spoken(event)
            } catch {
                return "Errore eliminando l'evento: \(error.localizedDescription)"
            }
        })
    }

    // MARK: Reminders

    func listReminders(_ args: [String: Any]) async -> String {
        guard await ensureReminders() else { return Self.noAccess }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }
        guard !reminders.isEmpty else { return "Nessun promemoria in sospeso." }
        let sorted = reminders.sorted {
            ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture)
        }
        return sorted.prefix(25).map { r in
            var line = "- \(r.title ?? "Senza titolo")"
            if let due = r.dueDateComponents?.date { line += " (scadenza \(DateArg.spoken(due)))" }
            if let list = r.calendar?.title { line += " [\(list)]" }
            return line
        }.joined(separator: "\n")
    }

    func createReminder(_ args: [String: Any]) async -> String {
        guard await ensureReminders() else { return Self.noAccess }
        guard let title = args.string("title") else { return "Titolo mancante" }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = args.string("notes")
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let due = DateArg.parse(args["due"]) {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        do {
            try store.save(reminder, commit: true)
            let when = reminder.dueDateComponents?.date.map { " per \(DateArg.spoken($0))" } ?? ""
            return "Promemoria \"\(title)\" creato\(when)"
        } catch {
            return "Errore creando il promemoria: \(error.localizedDescription)"
        }
    }

    /// With a single reminder it asks for spoken confirmation, with several it asks which.
    func prepareDeleteReminder(_ args: [String: Any]) async -> ToolOutcome {
        guard await ensureReminders() else { return .result(Self.noAccess) }
        guard let query = args.string("title")?.lowercased(), !query.isEmpty else { return .result("Titolo mancante") }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }
        let matches = reminders.filter { ($0.title ?? "").lowercased().contains(query) }
        guard let match = matches.first else { return .result("Nessun promemoria corrisponde a \"\(query)\"") }
        guard matches.count == 1 else {
            let list = matches.prefix(10).map { "- " + ($0.title ?? "") }.joined(separator: "\n")
            return .result("Nulla eliminato: più promemoria corrispondono. Chiedi all'utente quale.\n" + list)
        }
        let title = match.title ?? query
        return .needsConfirmation(PendingAction(summary: "Eliminare il promemoria \"\(title)\"") { [store] in
            do {
                try store.remove(match, commit: true)
                return "Eliminato il promemoria \"\(title)\""
            } catch {
                return "Errore: \(error.localizedDescription)"
            }
        })
    }

    func completeReminder(_ args: [String: Any]) async -> String {
        guard await ensureReminders() else { return Self.noAccess }
        guard let query = args.string("title")?.lowercased() else { return "Titolo mancante" }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }
        guard let match = reminders.first(where: { ($0.title ?? "").lowercased().contains(query) }) else {
            return "Nessun promemoria corrisponde a \"\(query)\""
        }
        match.isCompleted = true
        do {
            try store.save(match, commit: true)
            return "Completato \"\(match.title ?? query)\""
        } catch {
            return "Errore: \(error.localizedDescription)"
        }
    }
}
