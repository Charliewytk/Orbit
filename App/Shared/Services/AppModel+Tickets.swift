import Foundation
import OrbitCore

/// "Tickets on sale" cards: promos and ticket drops found in messages. They are
/// info, not plans; they only reach the calendar when the user says they bought
/// a ticket (or a FIXR/Eventbrite confirmation email arrives, which auto-adds).
extension AppModel {
    /// Stores new ticket drops as info cards. Returns how many were new.
    @discardableResult
    func ingest(ticketDrops: [TicketDrop], source: String) -> Int {
        guard !ticketDrops.isEmpty else { return 0 }
        let existing = Set(context.all(StoredPlan.self).map(\.id))
        var added = 0
        for d in ticketDrops where !existing.contains(d.id) {
            let plan = StoredPlan(id: d.id)
            plan.isTicketDrop = true
            plan.title = d.title
            // Undated drops stay visible for a week.
            plan.start = d.eventStart ?? d.receivedAt.addingTimeInterval(7 * 86400)
            plan.end = d.eventStart.map { $0.addingTimeInterval(PlanKind.party.defaultDuration) }
            plan.location = d.venue
            plan.buyURL = d.buyURL?.absoluteString
            plan.sourceRaw = source
            plan.quote = d.quote
            plan.kindLabel = d.provider.map { "\($0.label) tickets" } ?? "Tickets on sale"
            plan.confidence = 1
            plan.status = .pending
            context.insert(plan)
            added += 1
        }
        context.saveQuietly()
        return added
    }

    /// "Remind me before it sells out": a short to-do due within a day.
    func remindToBuy(_ drop: StoredPlan) {
        let due = min(Date().addingTimeInterval(24 * 3600), drop.start.addingTimeInterval(-3600))
        var task = OrbitTask(title: "Buy tickets: \(drop.title)", notes: drop.buyURL ?? "", estimateMinutes: 10,
                             deadline: max(due, Date().addingTimeInterval(1800)), source: .message, sourceRef: drop.id)
        task.minBlockMinutes = 10
        addTask(task)
        drop.status = .dismissed
        context.saveQuietly()
        show("I'll remind you to buy tickets for “\(drop.title)”")
    }

    /// "Add if I buy": hide the card; the ticket email puts it on the calendar.
    func addIfBought(_ drop: StoredPlan) {
        drop.addIfBought = true
        drop.status = .dismissed
        context.saveQuietly()
        show("Buy it and Orbit adds it when your ticket email arrives", undo: { [weak self] in
            drop.addIfBought = false
            drop.status = .pending
            self?.context.saveQuietly()
        })
    }

    /// "I've got a ticket": it becomes a real plan on the calendar.
    func boughtTicket(_ drop: StoredPlan) async {
        drop.isTicketDrop = false
        drop.kindLabel = PlanKind.party.label
        await accept(drop)
    }
}
