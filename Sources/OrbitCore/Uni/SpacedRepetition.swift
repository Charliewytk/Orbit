import Foundation

/// SuperMemo-2 scheduling for `Flashcard`s.
///
/// Grades are 0–5: 5 perfect, 4 correct after hesitation, 3 correct with
/// difficulty, 2/1/0 wrong. Correct answers space the card out (1 day, 6 days,
/// then previous interval × ease); wrong ones start it again. Ease never
/// drops below 1.3.
public enum SpacedRepetition {
    public static let minimumEase = 1.3
    /// Learning steps for new or forgotten cards in `reviewWithLearningSteps`.
    public static let relearnDelay: TimeInterval = 10 * 60

    /// Classic SM-2.
    public static func review(_ card: Flashcard, grade: Int, now: Date = Date()) -> Flashcard {
        let q = min(5, max(0, grade))
        var c = card
        if q >= 3 {
            switch c.repetitions {
            case 0: c.intervalDays = 1
            case 1: c.intervalDays = 6
            default: c.intervalDays = max(1, Int((Double(c.intervalDays) * c.easeFactor).rounded()))
            }
            c.repetitions += 1
        } else {
            c.repetitions = 0
            c.intervalDays = 1
        }
        c.easeFactor = updatedEase(c.easeFactor, grade: q)
        c.due = now.addingTimeInterval(Double(c.intervalDays) * 86400)
        return c
    }

    /// SM-2 with short learning steps (10 minutes, then 1 day) for cards that
    /// are new or were just forgotten, so they come back in the same session.
    /// A card is "learning" while it has no successful repetitions.
    public static func reviewWithLearningSteps(_ card: Flashcard, grade: Int, now: Date = Date()) -> Flashcard {
        let q = min(5, max(0, grade))
        var c = card
        if q < 3 {
            // Back to the 10-minute step. Ease only drops for cards that had graduated.
            if c.repetitions > 0 { c.easeFactor = updatedEase(c.easeFactor, grade: q) }
            c.repetitions = 0
            c.intervalDays = 0
            c.due = now.addingTimeInterval(relearnDelay)
            return c
        }
        if c.repetitions == 0 {
            // Passed the learning step: graduate to the 1-day interval.
            c.repetitions = 1
            c.intervalDays = 1
            c.due = now.addingTimeInterval(86400)
            return c
        }
        return review(c, grade: q, now: now)
    }

    /// SM-2 ease update: EF + (0.1 − (5 − q)(0.08 + (5 − q)·0.02)), floored at 1.3.
    public static func updatedEase(_ ease: Double, grade q: Int) -> Double {
        let d = Double(5 - q)
        return max(minimumEase, ease + (0.1 - d * (0.08 + d * 0.02)))
    }

    /// Cards due by `now`, most overdue first.
    public static func dueCards(_ cards: [Flashcard], now: Date = Date(), moduleCode: String? = nil, limit: Int? = nil) -> [Flashcard] {
        let due = cards.filter { $0.due <= now && (moduleCode == nil || $0.moduleCode == moduleCode) }.sorted { $0.due < $1.due }
        return limit.map { Array(due.prefix($0)) } ?? due
    }
}
