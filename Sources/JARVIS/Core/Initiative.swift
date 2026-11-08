import EventKit
import Foundation
import IOKit.ps

/// Phase 3: JARVIS speaks first.
///
/// Every 30 seconds (and as soon as JARVIS goes back to waiting) it checks appointments,
/// reminders, study hours and battery. Alerts wait in a queue until
/// JARVIS can speak: not in privacy mode, not during a conversation
/// or with a pending confirmation, not in quiet hours. An alert no
/// longer relevant (the appointment has started) is dropped.
/// The morning briefing starts after the first request of the day.
@MainActor
final class Initiative {
    private struct Alert {
        let id: String
        let text: String
        let expires: Date
    }

    /// Current settings, whether JARVIS can speak now, how to announce.
    var config: () -> JarvisConfig = { JarvisConfig() }
    var canSpeak: () -> Bool = { false }
    var announce: (String) -> Void = { _ in }
    var startBriefing: () -> Void = {}
    var studySession: () -> ActivityTracker.Session? = { nil }

    private let store = EKEventStore()
    private var timer: Timer?
    private var queue: [Alert] = []
    /// Alerts already given (or queued), with the date after which they can be forgotten.
    private var seen: [String: Date] = (UserDefaults.standard.dictionary(forKey: "initiative.seen") as? [String: Date]) ?? [:] {
        // Saved: after a JARVIS restart alerts already given are not repeated.
        didSet { UserDefaults.standard.set(seen, forKey: "initiative.seen") }
    }
    private var batteryWarned = false
    private var briefingPending = false
    private var checking = false
    private static let briefingKey = "initiative.lastBriefingDay"

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        Task { await check() }
    }

    /// JARVIS went back to waiting: the right moment for queued alerts.
    func becameIdle() {
        deliver()
    }

    /// First activation of the day (voice or shortcut) in the morning: after the
    /// answer the briefing starts, once a day even after a restart.
    func activated() {
        let c = config()
        let hour = Calendar.current.component(.hour, from: Date())
        guard c.morningBriefing, (c.briefingFrom..<c.briefingUntil).contains(hour), !briefedToday else { return }
        briefingPending = true
    }

    /// The briefing was given (also on request): it is not repeated today.
    func briefingDone() {
        briefingPending = false
        UserDefaults.standard.set(Self.today, forKey: Self.briefingKey)
    }

    private var briefedToday: Bool {
        UserDefaults.standard.string(forKey: Self.briefingKey) == Self.today
    }

    private static var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: Checks

    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let c = config()
        let now = Date()
        seen = seen.filter { $0.value > now }
        if c.alertCalendar { checkEvents(now) }
        if c.alertReminders { await checkReminders(now) }
        if c.alertStudy { checkStudy(now) }
        if c.alertBattery { checkBattery(now) }
        deliver()
    }

    /// An alert coming from outside (the printer): valid for 12 hours, so a print
    /// finished during quiet hours is announced later.
    func alert(id: String, text: String) {
        enqueue(id, text, expires: Date().addingTimeInterval(12 * 3600))
        deliver()
    }

    private func enqueue(_ id: String, _ text: String, expires: Date, forget: Date? = nil) {
        guard seen[id] == nil else { return }
        seen[id] = forget ?? expires.addingTimeInterval(3600)
        queue.append(Alert(id: id, text: text, expires: expires))
        Diagnostics.log("iniziativa in coda: \(text)")
    }

    /// Timed appointments starting within 10 minutes.
    private func checkEvents(_ now: Date) {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        let window = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(10 * 60 + 15), calendars: nil)
        for event in store.events(matching: window)
        where !event.isAllDay && event.status != .canceled && event.startDate > now {
            let minutes = max(1, Int((event.startDate.timeIntervalSince(now) / 60).rounded()))
            let title = event.title?.isEmpty == false ? event.title! : "un appuntamento"
            var text = "Signore, tra \(minutes) \(minutes == 1 ? "minuto" : "minuti") ha \(title)"
            if let place = event.location?.split(separator: "\n").first, !place.isEmpty { text += ", \(place)" }
            enqueue("evento/\(event.calendarItemIdentifier)/\(Int(event.startDate.timeIntervalSince1970))",
                    text + ".", expires: event.startDate)
        }
    }

    /// Reminders with a due time reached in the last few minutes.
    private func checkReminders(_ now: Date) async {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: now.addingTimeInterval(-5 * 60),
                                                              ending: now.addingTimeInterval(20), calendars: nil)
        let due: [(id: String, title: String)] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let items = (reminders ?? [])
                    .filter { $0.dueDateComponents?.hour != nil }   // only those with a time
                    .map { (id: $0.calendarItemIdentifier, title: $0.title ?? "promemoria") }
                continuation.resume(returning: items)
            }
        }
        for item in due {
            enqueue("promemoria/\(item.id)", "Signore, promemoria: \(item.title).",
                    expires: now.addingTimeInterval(15 * 60), forget: now.addingTimeInterval(12 * 3600))
        }
    }

    /// A break every 2 hours of continuous study.
    private func checkStudy(_ now: Date) {
        guard let session = studySession(), session.category == .study else { return }
        let blocks = Int(session.duration / 7200)
        guard blocks >= 1 else { return }
        let hours = blocks * 2
        enqueue("studio/\(Int(session.start.timeIntervalSince1970))/\(blocks)",
                "Signore, studia \(session.name) da \(hours) ore. Le propongo una pausa di dieci minuti.",
                expires: now.addingTimeInterval(30 * 60), forget: now.addingTimeInterval(3 * 3600))
    }

    /// Battery at 20% or less without a charger: one alert, then again only
    /// after plugging it in (or above 25%).
    private func checkBattery(_ now: Date) {
        guard let (percent, onBattery) = Self.battery() else { return }
        if !onBattery || percent > 25 { batteryWarned = false }
        guard onBattery, percent <= 20, !batteryWarned else { return }
        batteryWarned = true
        queue.append(Alert(id: "batteria", text: "Signore, la batteria è al \(percent) per cento: conviene collegare l'alimentatore.",
                           expires: now.addingTimeInterval(20 * 60)))
        Diagnostics.log("iniziativa in coda: batteria \(percent)%")
    }

    static func battery() -> (percent: Int, onBattery: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let percent = d[kIOPSCurrentCapacityKey] as? Int else { continue }
            return (percent, d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue)
        }
        return nil
    }

    // MARK: Delivery

    private func inQuietHours(_ c: JarvisConfig) -> Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        let from = c.quietFrom, to = c.quietTo
        guard from != to else { return false }
        return from < to ? (from..<to).contains(hour) : hour >= from || hour < to
    }

    private func deliver() {
        let now = Date()
        let dropped = queue.filter { $0.expires <= now }
        for alert in dropped { Diagnostics.log("iniziativa scaduta: \(alert.text)") }
        queue.removeAll { $0.expires <= now }
        let c = config()
        guard canSpeak(), !inQuietHours(c) else { return }
        if !queue.isEmpty {
            // Several alerts together become one sentence, the most urgent first.
            let text = queue.sorted { $0.expires < $1.expires }.map(\.text).joined(separator: " ")
            queue.removeAll()
            Diagnostics.log("iniziativa detta: \(text)")
            announce(text)
        } else if briefingPending {
            briefingDone()
            Diagnostics.log("iniziativa: briefing del mattino")
            startBriefing()
        }
    }
}
