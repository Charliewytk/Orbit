import SwiftUI
import SwiftData
import OrbitCore

struct TasksView: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \StoredTask.createdAt) private var tasks: [StoredTask]
    @Query(sort: \StoredBlock.start) private var blocks: [StoredBlock]
    @State private var editing: StoredTask?
    @State private var showDone = false
    @State private var completedTick = 0

    private enum Bucket: String, CaseIterable {
        case today = "Today", week = "This week", later = "Later", noDate = "No date"
    }

    private func group(_ t: StoredTask, now: Date, cal: DayCalendar) -> Bucket {
        let hasBlockToday = blocks.contains { $0.taskID == t.id && cal.isSameDay($0.start, now) && !$0.completed }
        if let d = t.deadline {
            let days = cal.days(from: now, to: d)
            if days <= 0 || hasBlockToday { return .today }
            return days <= 7 ? .week : .later
        }
        return hasBlockToday ? .today : .noDate
    }

    var body: some View {
        let now = Date()
        let cal = app.calendar
        let open = TaskScorer().rank(tasks.filter { !$0.isDone }.map(\.value), now: now)
            .compactMap { v in tasks.first { $0.id == v.id.uuidString } }
        let done = tasks.filter(\.isDone).sorted { ($0.completedAt ?? now) > ($1.completedAt ?? now) }

        List {
            Section {
                QuickAddField()
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }

            if open.isEmpty {
                EmptyState(systemImage: "checkmark.seal", title: "All clear",
                           message: "Type a to-do above, like “essay plan BEM2031 2h before Friday”.")
                    .listRowBackground(Color.clear)
            }

            ForEach(Bucket.allCases, id: \.self) { g in
                let items = open.filter { group($0, now: now, cal: cal) == g }
                if !items.isEmpty {
                    Section(g.rawValue) {
                        ForEach(items) { task in
                            TaskRow(task: task, blocks: blocks.filter { $0.taskID == task.id && $0.end > now && !$0.skipped })
                                .contentShape(Rectangle())
                                .onTapGesture { editing = task }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        completedTick += 1
                                        withAnimation(Theme.spring) { app.toggleComplete(task) }
                                    } label: { Label("Done", systemImage: "checkmark") }
                                        .tint(Theme.success)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { app.delete(task) } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                    }
                }
            }

            if !done.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showDone) {
                        ForEach(done.prefix(30)) { task in
                            TaskRow(task: task, blocks: [])
                                .onTapGesture { withAnimation(Theme.spring) { app.toggleComplete(task) } }
                        }
                    } label: {
                        Text("Done (\(done.count))").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .orbitBackground()
        .navigationTitle("Tasks")
        .sheet(item: $editing) { task in
            TaskDetailSheet(task: task)
        }
        .successHaptic(completedTick)
    }
}

struct TaskRow: View {
    @Environment(AppModel.self) private var app
    var task: StoredTask
    var blocks: [StoredBlock]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                withAnimation(Theme.spring) { app.toggleComplete(task) }
            } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(task.isDone ? Theme.success : Theme.moduleColor(task.moduleCode))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .font(Theme.body.weight(.medium))
                    .foregroundStyle(task.isDone ? Theme.textTertiary : Theme.textPrimary)
                    .strikethrough(task.isDone)
                Flow {
                    ModuleChip(code: task.moduleCode)
                    Tag(text: Fmt.duration(task.remainingMinutes), systemImage: "timer")
                    if let d = task.deadline, !task.isDone {
                        Tag(text: Fmt.due(d, app.calendar), color: d < Date() ? Theme.danger : Theme.textSecondary, systemImage: "flag")
                    }
                    if task.priority >= .high { Tag(text: task.priority == .critical ? "Critical" : "High", color: Theme.danger, systemImage: "exclamationmark") }
                    if task.energy == .high { Tag(text: "Deep work", color: Theme.accent, systemImage: "brain.head.profile") }
                    if let b = blocks.first {
                        Tag(text: Fmt.dayTime(b.start, app.calendar), color: Theme.success, systemImage: "calendar")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Natural-language quick add with a live preview of what was understood.
struct QuickAddField: View {
    @Environment(AppModel.self) private var app
    @State private var text = ""
    @State private var added = 0
    @FocusState private var focused: Bool

    var body: some View {
        let result = text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : app.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                TextField("Add a to-do… “essay plan BEM2031 2h before Friday”", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(add)
                    .submitLabel(.done)
                if result != nil {
                    Button("Add", action: add)
                        .buttonStyle(PillButtonStyle())
                }
            }
            if let result {
                Flow {
                    Tag(text: result.task.title.isEmpty ? "Untitled" : result.task.title, color: Theme.textPrimary, systemImage: "text.cursor")
                    Tag(text: Fmt.duration(result.task.estimateMinutes) + (result.hasExplicitEstimate ? "" : " (guess)"),
                        color: Theme.accent, systemImage: "timer")
                    if let d = result.task.deadline {
                        Tag(text: Fmt.dayTime(d, app.calendar), color: Theme.warning, systemImage: "flag")
                    }
                    if let s = result.task.earliestStart {
                        Tag(text: "from \(Fmt.day(s, app.calendar))", color: Theme.textSecondary, systemImage: "arrow.right.to.line")
                    }
                    ModuleChip(code: result.task.moduleCode)
                    if result.task.priority > .normal { Tag(text: "Priority", color: Theme.danger, systemImage: "exclamationmark") }
                    if result.task.energy != .medium {
                        Tag(text: result.task.energy == .high ? "Deep work" : "Light", color: Theme.success, systemImage: "bolt")
                    }
                    if let r = result.ignoredRecurrence { Tag(text: "Repeats not supported: \(r)", color: Theme.textTertiary) }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Theme.spring, value: result?.task.title)
        .successHaptic(added)
    }

    private func add() {
        guard app.addTask(text: text) != nil else { return }
        added += 1
        text = ""
        app.show(app.backend.isBrain ? "Added. Orbit's finding it a slot." : "Added. Your Mac will schedule it.")
    }
}

struct TaskDetailSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \StoredBlock.start) private var allBlocks: [StoredBlock]
    @Query(sort: \StoredModule.id) private var modules: [StoredModule]
    @Bindable var task: StoredTask
    @State private var hasDeadline = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $task.title)
                    TextField("Notes", text: $task.notes, axis: .vertical).lineLimit(2...5)
                }
                Section("Effort") {
                    Stepper("Estimate: \(Fmt.duration(task.estimateMinutes))", value: $task.estimateMinutes, in: 5...3000, step: 15)
                    Stepper("Done so far: \(Fmt.duration(task.minutesDone))", value: $task.minutesDone, in: 0...3000, step: 15)
                    Picker("Priority", selection: Binding(get: { task.priority }, set: { task.priority = $0 })) {
                        Text("Low").tag(Priority.low)
                        Text("Normal").tag(Priority.normal)
                        Text("High").tag(Priority.high)
                        Text("Critical").tag(Priority.critical)
                    }
                    Picker("Energy", selection: Binding(get: { task.energy }, set: { task.energy = $0 })) {
                        Text("Light").tag(Energy.low)
                        Text("Medium").tag(Energy.medium)
                        Text("Deep work").tag(Energy.high)
                    }
                }
                Section("When") {
                    Toggle("Deadline", isOn: $hasDeadline)
                    if hasDeadline {
                        DatePicker("Due", selection: Binding(get: { task.deadline ?? Date().addingTimeInterval(86400) },
                                                             set: { task.deadline = $0 }))
                    }
                }
                Section("Module") {
                    Picker("Module", selection: $task.moduleCode) {
                        Text("None").tag(String?.none)
                        ForEach(modules) { m in Text("\(m.id) \(m.name)").tag(String?.some(m.id)) }
                        if let code = task.moduleCode, !modules.contains(where: { $0.id == code }) {
                            Text(code).tag(String?.some(code))
                        }
                    }
                }
                let planned = allBlocks.filter { $0.taskID == task.id && !$0.skipped }
                Section("Planned blocks") {
                    if planned.isEmpty {
                        Text(task.isDone ? "Done." : "Not scheduled yet. The Mac plans it on its next pass.")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(planned) { b in
                        HStack {
                            Image(systemName: b.completed ? "checkmark.circle.fill" : "calendar")
                                .foregroundStyle(b.completed ? Theme.success : Theme.moduleColor(b.moduleCode))
                            Text(Fmt.dayTime(b.start, app.calendar))
                            Spacer()
                            Text(Fmt.duration(b.minutes)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                Section {
                    Button(task.isDone ? "Mark not done" : "Mark done") { app.toggleComplete(task); dismiss() }
                    Button("Delete", role: .destructive) { app.delete(task); dismiss() }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("To-do")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if !hasDeadline { task.deadline = nil }
                        app.taskEdited(task)
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 560)
        .onAppear { hasDeadline = task.deadline != nil }
    }
}
