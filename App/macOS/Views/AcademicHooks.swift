import SwiftUI
import OrbitCore

// Hooks where the academic "brain" (App/macOS/Brain/Brain+Academic.swift, being
// written separately) surfaces in the UI. They render nothing until that API
// exists, so the screens don't guess at it.
//
// TODO(academic): once `OrbitBrain.academic` lands, fill these in:
//   - AcademicWeekLabel:     brain.academic.currentWeek → "Week 2 · Term 1"
//   - AcademicTodaySections: brain.academic.homework (due soon) and
//                            brain.academic.lectureReviews ("You may have missed…")
//   - AcademicWeekExtras:    brain.academic.weekOverview(module:week:) → homework and
//                            the lecture review for that week in Uni › Weeks.
// Style: rows like `DueRow` (hoverRow, 32 pt, module dot, DueText), sections via `PageSection`.

/// "Week 2 · Term 1" in the Today header (followed by " · " when `trailingSeparator`).
struct AcademicWeekLabel: View {
    @Environment(OrbitBrain.self) private var brain
    var now: Date
    var trailingSeparator: Bool = false

    var body: some View {
        // TODO(academic): Text("\(label)\(trailingSeparator ? " · " : "")") from brain.academic.currentWeek.
        EmptyView()
    }
}

/// Homework due and lecture review items on Today.
struct AcademicTodaySections: View {
    @Environment(OrbitBrain.self) private var brain
    var now: Date

    var body: some View {
        // TODO(academic): PageSection("Homework") { … } and PageSection("You may have missed") { … }
        EmptyView()
    }
}

/// Extra lines for one week in Uni › Weeks (homework, lecture review).
struct AcademicWeekExtras: View {
    @Environment(OrbitBrain.self) private var brain
    var moduleCode: String
    var week: Int

    var body: some View {
        // TODO(academic): rows from brain.academic.weekOverview(…) for this module and week.
        EmptyView()
    }
}
