import Foundation
import EventKit
import AppKit
import Observation
import OrbitCore

/// Reads every calendar on this Mac (Calendar app accounts: Exeter/Exchange,
/// iCloud, Google, subscriptions) through EventKit. Needs no sign-in: the user
/// adds accounts in System Settings → Internet Accounts, then allows Orbit to
/// see calendars once.
@MainActor
@Observable
final class MacCalendarAccess {
    static let shared = MacCalendarAccess()

    @ObservationIgnored private(set) var store = EKEventStore()
    private(set) var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    /// Titles of the calendars Orbit can see, e.g. "Calendar (Exeter)".
    private(set) var calendarNames: [String] = []
    private(set) var exeterCalendarFound = false
    var lastError: String?

    private init() { refresh() }

    var granted: Bool { status == .fullAccess }
    var denied: Bool { status == .denied || status == .restricted || status == .writeOnly }

    /// Re-reads the permission and the calendar list.
    func refresh() {
        status = EKEventStore.authorizationStatus(for: .event)
        guard granted else {
            calendarNames = []
            exeterCalendarFound = false
            return
        }
        let calendars = store.calendars(for: .event)
        calendarNames = calendars.map { "\($0.title) (\($0.source?.title ?? "On My Mac"))" }.sorted()
        exeterCalendarFound = calendars.contains(where: Self.isExeter)
    }

    /// Shows the macOS "Allow Orbit to access your calendars?" prompt.
    @discardableResult
    func requestAccess() async -> Bool {
        OrbitLog.log("calendar", "Asking for calendar access (status \(status.rawValue))")
        do {
            let ok = try await store.requestFullAccessToEvents()
            OrbitLog.log("calendar", "Calendar access \(ok ? "granted" : "refused")")
            if ok {
                // A fresh store sees the newly allowed calendars straight away.
                store = EKEventStore()
            }
            lastError = ok ? nil : "Orbit wasn't allowed to see your calendars. Turn it on in System Settings → Privacy & Security → Calendars."
        } catch {
            OrbitLog.log("calendar", "Calendar access request failed: \(error)")
            lastError = "Couldn't ask for calendar access: \(error.localizedDescription)"
        }
        refresh()
        return granted
    }

    static func openCalendarPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openInternetAccounts() {
        // macOS 13+ System Settings pane for Internet Accounts.
        let candidates = ["x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension",
                          "x-apple.systempreferences:com.apple.preferences.internetaccounts"]
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    /// An Exchange account, or anything named after Exeter.
    static func isExeter(_ calendar: EKCalendar) -> Bool {
        let names = (calendar.title + " " + (calendar.source?.title ?? "")).lowercased()
        return calendar.source?.sourceType == .exchange || names.contains("exeter")
    }

    private static func isGoogle(_ calendar: EKCalendar) -> Bool {
        let name = (calendar.source?.title ?? "").lowercased()
        return name.contains("google") || name.contains("gmail") || name.hasSuffix("@googlemail.com")
    }

    /// Events between `from` and `to` from every calendar on the Mac, as Orbit events.
    /// Skips calendars Orbit already reads another way (Google when connected,
    /// Exchange when the Microsoft sign-in is used) and its own "Orbit" calendar.
    func events(from: Date, to: Date, skipGoogle: Bool, skipExchange: Bool) -> (events: [CalendarEvent], calendarIDs: Set<String>) {
        refresh()
        guard granted else { return ([], []) }
        let calendars = store.calendars(for: .event).filter { cal in
            if cal.type == .birthday { return false }
            if cal.title == "Orbit" { return false }
            if skipGoogle && Self.isGoogle(cal) { return false }
            if skipExchange && cal.source?.sourceType == .exchange { return false }
            return true
        }
        guard !calendars.isEmpty else { return ([], []) }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
        var out: [CalendarEvent] = []
        for event in store.events(matching: predicate) {
            guard let start = event.startDate, let end = event.endDate else { continue }
            let calendar = event.calendar
            let calendarID = "mac-" + (calendar?.calendarIdentifier ?? "unknown")
            // Repeating events share one identifier, so add the start time.
            let base = event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? UUID().uuidString
            let source: CalendarSource = (calendar.map(Self.isExeter) ?? false) ? .outlook : .local
            out.append(CalendarEvent(id: "\(base)@\(Int(start.timeIntervalSince1970))",
                                     title: event.title ?? "(No title)", start: start, end: end,
                                     isAllDay: event.isAllDay, location: event.location, notes: event.notes,
                                     calendarID: calendarID, source: source,
                                     isBusy: event.availability != .free && !event.isAllDay))
        }
        return (out, Set(calendars.map { "mac-" + $0.calendarIdentifier }))
    }
}
