import Foundation
import SwiftData
import OrbitCore

extension OrbitBrain {
    /// Morning brief at `morningBriefTime`, evening review at `eveningReviewTime`,
    /// weekly "on track for a First?" review on Sunday from 18:00. Each runs once a
    /// day; if the Mac was asleep at the time, it runs when it wakes.
    func runScheduledBriefs(now: Date) async {
        let prefs = self.prefs
        let cal = DayCalendar(timeZone: prefs.timeZone)
        let minute = cal.minuteOfDay(now)
        let day = cal.format(now, "yyyy-MM-dd")
        if minute >= prefs.morningBriefTime, minute < prefs.eveningReviewTime, state.lastMorningBrief != day {
            state.lastMorningBrief = day
            saveState()
            await generateMorningBrief(now: now)
        }
        if minute >= prefs.eveningReviewTime, state.lastEveningReview != day {
            state.lastEveningReview = day
            saveState()
            await generateEveningReview(now: now)
        }
        if cal.weekday(now) == 1, minute >= 18 * 60, state.lastWeeklyReview != day {
            state.lastWeeklyReview = day
            saveState()
            await generateWeeklyReview(now: now)
        }
    }

    private func upsertBrief(_ kind: BriefKind, day: Date, narrative: String?, plain: String, payload: Data?) {
        let cal = DayCalendar(timeZone: prefs.timeZone)
        let id = StoredBrief.id(kind, day: day, calendar: cal)
        let brief = context.record(StoredBrief.self, id: id) ?? {
            let b = StoredBrief(id: id)
            context.insert(b)
            return b
        }()
        brief.kindRaw = kind.rawValue
        brief.date = cal.startOfDay(day)
        brief.narrative = narrative
        brief.plainText = plain
        brief.payload = payload
        brief.createdAt = Date()
        context.saveQuietly()
    }

    private static func teaser(_ text: String) -> String {
        let first = text.split(separator: ".", maxSplits: 1).first.map { String($0) + "." } ?? text
        return String(first.prefix(200))
    }

    func generateMorningBrief(now: Date = Date()) async {
        await replanNow()
        let prefs = self.prefs
        let digests = context.all(StoredEmailDigest.self)
            .filter { !$0.handled && $0.date > now.addingTimeInterval(-2 * 86400) }.map(\.value)
        let brief = MorningBriefBuilder(prefs: prefs).build(
            now: now, events: context.all(StoredEvent.self).map(\.value),
            blocks: context.all(StoredBlock.self).filter { !$0.skipped }.map(\.value),
            tasks: context.all(StoredTask.self).map(\.value), assessments: context.all(StoredAssessment.self).map(\.value),
            emails: digests, flashcards: context.all(StoredFlashcard.self).map(\.value))
        let narrated = await brief.narrated(using: router)
        let plain = brief.plainSummary()
        upsertBrief(.morning, day: now, narrative: narrated.narrative, plain: plain, payload: StoreCoding.encode(narrated))
        let cal = DayCalendar(timeZone: prefs.timeZone)
        notify(id: "brief-morning-\(cal.format(now, "yyyy-MM-dd"))", title: "☀️ \(Fmt.greeting(firstName, now: now, cal: cal))",
               body: Self.teaser(narrated.narrative ?? "\(brief.events.count) events, \(Fmt.duration(brief.plannedMinutes)) of focus planned."),
               category: "brief")
        record(.briefs, detail: "Morning brief \(cal.time(now))")
    }

    func generateEveningReview(now: Date = Date()) async {
        let prefs = self.prefs
        let blocks = context.all(StoredBlock.self).filter { !$0.skipped || $0.start < now }
        let review = EveningReviewBuilder(prefs: prefs).build(
            now: now, blocks: blocks.map(\.value), completedBlockIDs: Set(blocks.filter(\.completed).map(\.uuid)),
            tasks: context.all(StoredTask.self).map(\.value), events: context.all(StoredEvent.self).map(\.value),
            assessments: context.all(StoredAssessment.self).map(\.value), previousStreak: state.streak ?? StreakState())
        state.streak = review.streak
        saveState()
        let narrated = await review.narrated(using: router)
        upsertBrief(.evening, day: now, narrative: narrated.narrative, plain: review.plainSummary(), payload: StoreCoding.encode(narrated))
        let cal = DayCalendar(timeZone: prefs.timeZone)
        let rate = review.completionRate.map { "\(Int(($0 * 100).rounded()))% of planned work done. " } ?? ""
        notify(id: "brief-evening-\(cal.format(now, "yyyy-MM-dd"))", title: "🌙 Today's wrap-up",
               body: Self.teaser(narrated.narrative ?? "\(rate)Streak: \(review.streak.count) days."), category: "brief")
        record(.briefs, detail: "Evening review \(cal.time(now))")
    }

    func generateWeeklyReview(now: Date = Date()) async {
        let prefs = self.prefs
        let events = context.all(StoredEvent.self).map(\.value)
        let review = StudyCoach(prefs: prefs).weeklyReview(
            modules: context.all(StoredModule.self).map(\.value),
            assessments: context.all(StoredAssessment.self).map(\.value),
            readings: context.all(StoredReading.self).map(\.value),
            notes: context.all(StoredNote.self).map(\.stub),
            lectures: events.filter(StudyCoach.isLecture),
            tasks: context.all(StoredTask.self).map(\.value),
            blocks: context.all(StoredBlock.self).map(\.value), now: now)
        let narrative = try? await review.narrate(using: router)
        upsertBrief(.weekly, day: now, narrative: narrative, plain: review.plainSummary, payload: StoreCoding.encode(review))
        notify(id: "brief-weekly-\(DayCalendar(timeZone: prefs.timeZone).format(now, "yyyy-MM-dd"))",
               title: "🎯 On track for a First? \(review.status.label)",
               body: review.topActions.first ?? "Your weekly review is ready.", category: "brief")
        record(.briefs, detail: "Weekly review")
    }
}
