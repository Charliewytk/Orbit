import Foundation
import SwiftData
import OrbitCore

extension FeatureHub {
    static let readingRefPrefix = "reading:"

    /// Readings due in the next ~10 days, each tied to the session it's for.
    func readingAssignments(now: Date) -> [ReadingAssignment] {
        guard let context, let brain else { return [] }
        let academic = brain.academic.calendar
        let events = context.all(StoredEvent.self).map(\.value)
        let term = academic.week(for: now)?.term ?? academic.currentOrNextWeek(now)?.term ?? academic.defaultTerm(for: now)
        let horizon = now.addingTimeInterval(10 * 86400)
        let readingMultiplier = state.learner.multiplier(for: .reading)
        var out: [ReadingAssignment] = []
        var seenTitles = Set<String>()

        func neededBy(module: String, week: Int) -> Date? {
            guard let start = academic.weekStart(term: term, week: week) else { return nil }
            return ReadingPlanner.neededBy(moduleCode: module, weekStart: start, events: events, timeZone: prefs.timeZone)
        }
        func adjusted(_ r: ReadingAssignment) -> ReadingAssignment {
            guard readingMultiplier != 1 else { return r }
            var copy = r
            copy.minutes = Int(Double(ReadingEstimator.estimate(r).minutes) * readingMultiplier)
            return copy
        }

        // Reading-list items (Talis / ELE "Reading for week N").
        let readings = context.all(StoredReading.self)
        let modulesWithEssentials = Set(readings.filter(\.essential).map(\.moduleCode))
        for r in readings where !r.done {
            guard let week = r.week, let due = neededBy(module: r.moduleCode, week: week) else { continue }
            guard due <= horizon, due > now.addingTimeInterval(-3 * 86400) else { continue }
            // Essential readings always; others only if the list doesn't mark importance at all.
            guard r.essential || !modulesWithEssentials.contains(r.moduleCode) else { continue }
            seenTitles.insert(FlashcardDeck.normalise(r.title))
            out.append(adjusted(ReadingAssignment(id: r.id, moduleCode: r.moduleCode, title: r.title, week: week,
                                                  essential: r.essential, neededBy: due)))
        }
        // Reading guides from the ELE week pages.
        for module in context.all(StoredModule.self) {
            for w in module.weeks {
                guard let due = neededBy(module: module.id, week: w.week), due <= horizon, due > now.addingTimeInterval(-3 * 86400) else { continue }
                for guide in w.readingGuides {
                    let key = FlashcardDeck.normalise(guide.name)
                    guard seenTitles.insert(key).inserted else { continue }
                    let id = "guide-\(module.id)-\(w.week)-" + MD5.hex(guide.name).prefix(8)
                    out.append(adjusted(ReadingAssignment(id: id, moduleCode: module.id, title: guide.name, week: w.week,
                                                          isGuide: true, neededBy: due)))
                }
            }
        }
        return out
    }

    /// Plans reading once a day (from 06:00) and whenever the readings change. Existing
    /// unstarted chunks are updated in place (stable ids), finished ones stay, and stale ones go.
    func planReadingIfNeeded(now: Date, force: Bool = false) async {
        guard FeatureSettings.bool(FeatureSettings.readingPlannerEnabled, default: true), let context else { return }
        let assignments = readingAssignments(now: now)
        let fingerprint = MD5.hex(assignments.map { "\($0.id)|\($0.neededBy.timeIntervalSince1970)|\($0.minutes ?? 0)" }.sorted().joined(separator: ","))
        let day = cal.format(now, "yyyy-MM-dd")
        let lastDay = state.lastReadingPlan.map { cal.format($0, "yyyy-MM-dd") }
        guard force || fingerprint != state.readingFingerprint || (lastDay != day && cal.minuteOfDay(now) >= 6 * 60) else { return }
        state.readingFingerprint = fingerprint
        state.lastReadingPlan = now

        let stored = context.all(StoredTask.self).filter { ($0.sourceRef ?? "").hasPrefix(Self.readingRefPrefix) }
        func readingID(_ t: StoredTask) -> String {
            let ref = String((t.sourceRef ?? "").dropFirst(Self.readingRefPrefix.count))
            return ref.split(separator: "#").first.map(String.init) ?? ref
        }
        var done: [String: Int] = [:]
        for t in stored {
            let minutes = t.completedAt != nil ? t.estimateMinutes : t.minutesDone
            if minutes > 0 { done[readingID(t), default: 0] += minutes }
        }
        let chunks = ReadingPlanner(prefs: prefs).plan(assignments, minutesDone: done, now: now)
        let byID = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let keep = Set(chunks.map { $0.id.uuidString })
        var added = 0, updated = 0, removed = 0
        for chunk in chunks {
            let task = chunk.task()
            if let existing = byID[chunk.id.uuidString] {
                guard existing.completedAt == nil else { continue }
                guard existing.deadline != task.deadline || existing.estimateMinutes != task.estimateMinutes
                        || existing.title != task.title else { continue }
                if existing.minutesDone == 0 {
                    existing.apply(task)
                } else {
                    // Keep progress on a part-read chunk; just move it.
                    existing.deadline = task.deadline
                    existing.earliestStart = task.earliestStart
                    existing.updatedAt = Date()
                }
                updated += 1
            } else {
                context.insert(StoredTask(task: task))
                added += 1
            }
        }
        for t in stored where !keep.contains(t.id) && t.completedAt == nil {
            if t.minutesDone == 0 {
                context.delete(t)
            } else {
                // Part-read chunk: close it at what was read; the rest is in the new chunks.
                t.estimateMinutes = t.minutesDone
                t.completedAt = now
                t.updatedAt = now
            }
            removed += 1
        }
        // A reading whose chunks are all done is ticked off.
        let finished = Set(assignments.filter { (done[$0.id] ?? 0) >= ReadingEstimator.estimate($0).minutes - 5 }.map(\.id))
        for r in context.all(StoredReading.self) where !r.done && finished.contains(r.id) { r.done = true }
        state.readingChunks = chunks
        context.saveQuietly()
        save()
        readingStatus = "\(chunks.count) reading chunk\(chunks.count == 1 ? "" : "s") planned"
        if added + updated + removed > 0 {
            OrbitLog.log("reading", "plan: +\(added) ~\(updated) -\(removed) (\(assignments.count) readings)")
            tasksChanged()
        }
    }

    func readingPlanText(week: Int?) -> String {
        let chunks = state.readingChunks.filter { c in week == nil || readingWeek(c) == week }
        guard !chunks.isEmpty else { return "No reading planned\(week.map { " for week \($0)" } ?? "") right now." }
        return chunks.map { c in
            "\(cal.shortDay(c.day)): \(c.title) · \(c.minutes) min (\(c.moduleCode), finish by \(cal.shortDay(c.deadline)) \(cal.time(c.deadline)))"
        }.joined(separator: "\n")
    }

    private func readingWeek(_ c: ReadingChunk) -> Int? {
        guard let context else { return nil }
        if let r = context.record(StoredReading.self, id: c.readingID) { return r.week }
        let parts = c.readingID.split(separator: "-")
        return parts.count >= 3 ? Int(parts[2]) : nil
    }
}
