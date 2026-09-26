import Foundation
import SwiftData
import OrbitCore

extension OrbitBrain {
    /// The Google Calendar client for the current Google session (recreated if the session changes).
    func googleCalendarClient() -> GoogleCalendarClient? {
        guard accounts.googleConnected, let session = accounts.google else { return nil }
        if let cached = calendarClient, cached.session === session { return cached.client }
        let client = GoogleCalendarClient(tokens: session, orbitCalendarID: state.orbitCalendarID, timeZone: prefs.timeZone)
        calendarClient = (session, client)
        return client
    }

    // MARK: Reading calendars

    /// Google (every visible calendar), Exeter Outlook, and the timetable feed,
    /// from a week ago to three weeks ahead.
    func syncCalendar() async {
        guard begin(.calendar) else { return }
        defer { end(.calendar) }
        await accounts.refreshStatus()
        let prefs = self.prefs
        let cal = DayCalendar(timeZone: prefs.timeZone)
        let from = cal.addingDays(-8, to: cal.startOfDay(Date()))
        let to = cal.addingDays(22, to: cal.startOfDay(Date()))
        var fetched: [CalendarEvent] = []
        var covered = Set<String>()
        var errors: [String] = []
        let blockEventIDs = Set(context.all(StoredBlock.self).compactMap(\.externalEventID))

        if let google = googleCalendarClient() {
            do {
                let orbitID = try await google.findOrCreateOrbitCalendar()
                if state.orbitCalendarID != orbitID {
                    state.orbitCalendarID = orbitID
                    saveState()
                }
                for calendar in try await google.listCalendars() where !calendar.hidden {
                    do {
                        var events = try await google.listEvents(calendarID: calendar.id, from: from, to: to)
                        if calendar.id == orbitID {
                            // Study blocks are tracked separately; other Orbit-calendar events are
                            // accepted plans, which are real commitments.
                            events = events.filter { !blockEventIDs.contains($0.id) }.map { e in
                                var e = e
                                e.source = .local
                                return e
                            }
                        }
                        fetched += events
                        covered.insert(calendar.id)
                    } catch {
                        errors.append("\(calendar.summary): \(error)")
                    }
                }
            } catch {
                errors.append("Google Calendar: \(error)")
            }
        }

        if accounts.microsoftConnected, let session = accounts.microsoft,
           MacPrefs.defaults.object(forKey: MacPrefs.useExeterCalendar) as? Bool ?? true {
            do {
                let client = OutlookCalendarClient(tokens: session, timeZone: prefs.timeZone)
                fetched += try await client.listEvents(from: from, to: to)
                covered.insert(client.calendarID)
            } catch {
                errors.append("Exeter calendar: \(error)")
            }
        }

        // Every calendar in the Mac's Calendar app (Exeter via Internet Accounts, iCloud, …).
        let macCalendars = MacCalendarAccess.shared
        if macCalendars.granted {
            let usingGraphCalendar = accounts.microsoftConnected
                && (MacPrefs.defaults.object(forKey: MacPrefs.useExeterCalendar) as? Bool ?? true)
            let result = macCalendars.events(from: from, to: to, skipGoogle: accounts.googleConnected,
                                             skipExchange: usingGraphCalendar)
            fetched += result.events
            covered.formUnion(result.calendarIDs)
            OrbitLog.log("calendar", "Mac calendars: \(result.events.count) events from \(result.calendarIDs.count) calendars")
        }

        if let s = MacPrefs.string(MacPrefs.timetableURL),
           let url = URL(string: s.replacingOccurrences(of: "webcal://", with: "https://")) {
            do {
                let data = try await HTTPClient(timeout: 30).data("GET", url)
                let events = ICSParser.parse(String(decoding: data, as: UTF8.self), source: .timetable, calendarID: "timetable",
                                             defaultTimeZone: prefs.timeZone, expandUntil: to)
                fetched += events.filter { $0.end > from && $0.start < to }
                covered.insert("timetable")
            } catch {
                errors.append("Timetable feed: \(error)")
            }
        }

        let changed = applyEvents(fetched, covered: covered, from: from, to: to)
        record(.calendar, error: errors.isEmpty ? nil : errors.joined(separator: "\n"),
               detail: "\(fetched.count) events from \(covered.count) calendars")
        if changed { scheduleReplan(after: 1) }
    }

    /// Upserts events and removes ones that disappeared from calendars that were
    /// fully refreshed. Returns true if anything changed.
    @discardableResult
    func applyEvents(_ events: [CalendarEvent], covered: Set<String>, from: Date, to: Date) -> Bool {
        let index = context.indexed(StoredEvent.self)
        var seen = Set<String>()
        var changed = false
        for e in events {
            let key = StoredEvent.key(e)
            guard seen.insert(key).inserted else { continue }
            if let existing = index[key] {
                if existing.start != e.start || existing.end != e.end || existing.title != e.title || existing.isBusy != e.isBusy {
                    changed = true
                }
                existing.apply(e)
            } else {
                context.insert(StoredEvent(event: e))
                changed = true
            }
        }
        let expired = Date().addingTimeInterval(-30 * 86400)
        for (key, stored) in index where !seen.contains(key) {
            let vanished = covered.contains(stored.calendarID) && stored.start < to && stored.end > from
            if vanished || stored.end < expired {
                context.delete(stored)
                changed = true
            }
        }
        context.saveQuietly()
        return changed
    }

    // MARK: Planning

    func scheduleReplan(after seconds: Double = 3) {
        replanTask?.cancel()
        replanTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            _ = await self.replanNow()
        }
    }

    private struct PlanInputs {
        var tasks: [OrbitTask]
        var events: [CalendarEvent]
        var current: [ScheduledBlock]
        var completed: Set<UUID>
        var replanner: Replanner
    }

    private func planInputs() -> PlanInputs {
        let prefs = self.prefs
        let blocks = context.all(StoredBlock.self)
        let assessments = context.all(StoredAssessment.self).map(\.value)
        let scorer = TaskScorer(assessments: assessments, dailyCapacityMinutes: Double(prefs.maxFocusMinutesPerDay) * 0.7)
        return PlanInputs(tasks: context.all(StoredTask.self).map(\.value),
                          events: context.all(StoredEvent.self).map(\.value),
                          current: blocks.map(\.value),
                          completed: Set(blocks.filter(\.completed).map(\.uuid)),
                          replanner: Replanner(prefs: prefs, scorer: scorer, horizonDays: 14))
    }

    /// Re-runs the scheduler over the next two weeks and writes the changes to the Orbit calendar.
    @discardableResult
    func replanNow() async -> SchedulePlan {
        while replanning { try? await Task.sleep(for: .milliseconds(200)) }
        replanning = true
        defer { replanning = false }
        let input = planInputs()
        let result = input.replanner.replan(tasks: input.tasks, events: input.events, current: input.current,
                                            completedBlockIDs: input.completed, now: Date())
        return await commit(result)
    }

    /// "Lighten my day": moves part of the day's planned work to later days.
    @discardableResult
    func lightenNow(day: Date, fraction: Double) async -> SchedulePlan {
        while replanning { try? await Task.sleep(for: .milliseconds(200)) }
        replanning = true
        defer { replanning = false }
        let input = planInputs()
        let result = input.replanner.lighten(day: day, by: fraction, tasks: input.tasks, events: input.events,
                                             current: input.current, completedBlockIDs: input.completed, now: Date())
        return await commit(result)
    }

    private func commit(_ result: ReplanResult) async -> SchedulePlan {
        var blocks = result.plan.blocks
        var changes = result.changes
        // Blocks planned while Google wasn't connected (or after a failed write) have no
        // event yet. Sending them as updates finds them by tag or creates them.
        let now = Date()
        let unsynced = changes.unchanged.filter { $0.externalEventID == nil && $0.end > now }
        if !unsynced.isEmpty {
            let ids = Set(unsynced.map(\.id))
            changes.unchanged.removeAll { ids.contains($0.id) }
            changes.update += unsynced
        }
        if !changes.isEmpty, let google = googleCalendarClient() {
            do {
                blocks = try await google.apply(changes)
            } catch {
                // Keep the old plan so the next attempt recomputes the same changes.
                record(.calendar, error: "Couldn't update the Orbit calendar: \(error)")
                return result.plan
            }
        }
        writeBlocks(blocks)
        app?.refreshWidgets()
        return result.plan
    }

    func writeBlocks(_ blocks: [ScheduledBlock]) {
        let index = context.indexed(StoredBlock.self)
        let keep = Set(blocks.map { $0.id.uuidString })
        for b in blocks {
            if let existing = index[b.id.uuidString] {
                existing.apply(b)
            } else {
                context.insert(StoredBlock(block: b))
            }
        }
        let now = Date(), oldest = now.addingTimeInterval(-14 * 86400)
        for (key, stored) in index where !keep.contains(key) {
            // Future blocks the planner dropped go; past ones stay a while for reviews.
            if stored.end > now || stored.end < oldest { context.delete(stored) }
        }
        context.saveQuietly()
    }

    // MARK: Accepted plans → calendar

    /// Puts accepted plans (from messages, email or chat) on the Orbit calendar.
    func writeAcceptedPlans() async {
        let waiting = context.all(StoredPlan.self).filter { $0.status == .accepted && $0.calendarEventID == nil }
        guard !waiting.isEmpty else { return }
        let prefs = self.prefs
        var added = 0
        for plan in waiting {
            var event = plan.event
            if let google = googleCalendarClient(), let session = accounts.google {
                do {
                    let calendarID = try await google.findOrCreateOrbitCalendar()
                    event.id = try await GoogleEventWriter(tokens: session).insert(event, calendarID: calendarID, timeZone: prefs.timeZone)
                    event.calendarID = calendarID
                } catch {
                    record(.calendar, error: "Couldn't add “\(plan.title)” to Google Calendar: \(error)")
                    continue
                }
            } else {
                event.id = "plan-\(plan.id)"
                event.calendarID = "orbit-local"
            }
            event.source = .local
            plan.calendarEventID = event.id
            if context.record(StoredEvent.self, id: StoredEvent.key(event)) == nil {
                context.insert(StoredEvent(event: event))
            }
            added += 1
        }
        context.saveQuietly()
        if added > 0 { scheduleReplan(after: 1) }
    }
}
