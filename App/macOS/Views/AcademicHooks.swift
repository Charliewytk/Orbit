import SwiftUI
import SwiftData
import OrbitCore

// Where the academic brain (`brain.academic`, App/macOS/Brain/Brain+Academic.swift)
// surfaces in the shared screens. Mac only: the iPhone doesn't have it.

/// "Week 2 · Term 1" in the Today header (followed by " · " when `trailingSeparator`).
struct AcademicWeekLabel: View {
    @Environment(OrbitBrain.self) private var brain
    var now: Date
    var trailingSeparator: Bool = false

    var body: some View {
        if let w = brain.academic.currentWeek {
            Text("Week \(w.week) · Term \(w.term)\(w.isReadingWeek ? " · Reading week" : "")\(trailingSeparator ? " · " : "")")
        }
    }
}

/// Homework due soon and "You may have missed…" lecture reviews on Today.
struct AcademicTodaySections: View {
    @Environment(AppModel.self) private var app
    @Environment(OrbitBrain.self) private var brain
    @Query(filter: #Predicate<StoredTask> { $0.completedAt != nil }) private var doneTasks: [StoredTask]
    var now: Date

    var body: some View {
        let doneIDs = Set(doneTasks.map(\.id))
        let horizon = now.addingTimeInterval(7 * 86400)
        let homework = brain.academic.homework.filter { h in
            guard !doneIDs.contains(h.taskID.uuidString) else { return false }
            guard let due = h.due else { return false }
            return due < horizon && due > now.addingTimeInterval(-2 * 86400)
        }
        let reviews = brain.academic.lectureReviews
            .filter { !$0.missed.isEmpty && $0.updatedAt > now.addingTimeInterval(-14 * 86400) }
            .prefix(4)

        if !homework.isEmpty {
            PageSection(title: "Homework", count: homework.count) {
                VStack(spacing: 0) {
                    ForEach(homework) { item in
                        HomeworkRow(item: item, task: brain.academic.homeworkTask(for: item), now: now)
                    }
                }
            }
        }

        if !reviews.isEmpty {
            PageSection(title: "You may have missed") {
                VStack(spacing: 0) {
                    ForEach(Array(reviews)) { review in
                        LectureReviewRow(review: review)
                    }
                }
            }
        }
    }
}

private struct HomeworkRow: View {
    @Environment(AppModel.self) private var app
    var item: HomeworkItem
    var task: StoredTask?
    var now: Date

    var body: some View {
        HStack(spacing: 10) {
            if let task {
                CircleCheckbox(isOn: task.isDone) {
                    withAnimation(Motion.smooth) { app.toggleComplete(task) }
                }
            } else {
                Image(systemName: "doc.text")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 16)
            }
            Text(item.title).font(Theme.body).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Text(item.kind.label).font(Theme.caption).foregroundStyle(Theme.textTertiary)
            ModuleTag(code: item.moduleCode)
            Spacer(minLength: Theme.Space.s)
            Text(Fmt.duration(item.estimateMinutes))
                .font(Theme.caption.monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            if let due = item.due {
                DueText(date: due, calendar: app.calendar, now: now, style: .short)
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 32)
        .hoverRow()
        .onTapGesture {
            if let s = item.url, let url = URL(string: s) { openExternal(url) }
        }
        .help(item.summary.isEmpty ? item.title : item.summary)
    }
}

private struct LectureReviewRow: View {
    @Environment(AppModel.self) private var app
    var review: LectureReview

    var body: some View {
        let first = review.missed.first
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            ModuleDot(code: review.moduleCode, size: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(first.map { "‘\($0.topic)’ (\($0.slideText))" } ?? review.title)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(place + (review.missed.count > 1 ? " · \(review.missed.count - 1) more topic\(review.missed.count == 2 ? "" : "s")" : ""))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Space.s)
            if let coverage = review.coverage {
                Text("\(Int((coverage * 100).rounded()))% covered")
                    .font(Theme.caption.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 6)
        .hoverRow()
        .onTapGesture {
            guard let noteID = review.noteIDs.first else { return }
            app.selectedNoteID = noteID
            NotificationCenter.default.post(name: .orbitNavigate, object: Destination.notes)
        }
    }

    private var place: String {
        guard let week = review.week else { return "\(review.moduleCode) · \(review.title)" }
        return (review.term ?? 1) > 1 ? "\(review.moduleCode) · T\(review.term ?? 1) week \(week)" : "\(review.moduleCode) · week \(week)"
    }
}

/// Extra lines for one week in Uni › Weeks: homework due and the lecture review.
struct AcademicWeekExtras: View {
    @Environment(AppModel.self) private var app
    @Environment(OrbitBrain.self) private var brain
    var moduleCode: String
    var week: Int

    var body: some View {
        let homework = brain.academic.homework.filter { $0.moduleCode == moduleCode && $0.week == week }
        let review = brain.academic.review(module: moduleCode, week: week)
        ForEach(homework) { h in
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "pencil.and.list.clipboard")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 16)
                Text("\(h.kind.label): \(h.title)").font(Theme.body).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: Theme.Space.s)
                if let due = h.due { DueText(date: due, calendar: app.calendar, style: .short) }
            }
            .padding(.horizontal, Theme.Space.s)
            .frame(minHeight: 28)
            .hoverRow()
            .onTapGesture { if let s = h.url, let url = URL(string: s) { openExternal(url) } }
        }
        if let review {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "checklist")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 16)
                    Text(review.coverage.map { "Your notes cover \(Int(($0 * 100).rounded()))% of the slides" } ?? "Notes reviewed against the slides")
                        .font(Theme.body)
                        .foregroundStyle(Theme.textPrimary)
                }
                ForEach(review.missed, id: \.self) { m in
                    Text("May have missed ‘\(m.topic)’ (\(m.slideText))")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.leading, 16 + Theme.Space.s)
                }
                let answered = review.questions.filter(\.isAnswered).count
                if answered > 0 {
                    Text("\(answered) question\(answered == 1 ? "" : "s") from your notes answered")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.leading, 16 + Theme.Space.s)
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 6)
        }
    }
}
