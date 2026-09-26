import SwiftUI
import SwiftData
import OrbitCore

/// Things-style task list: quick add at the top, grouped Today / This week /
/// Later / Someday, inline metadata, and an inspector for the selected task.
struct TasksView: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \StoredTask.createdAt) private var tasks: [StoredTask]
    @Query(sort: \StoredBlock.start) private var blocks: [StoredBlock]
    @State private var showDone = false
    #if os(macOS)
    @State private var showInspector = true
    #endif
    @FocusState private var listFocused: Bool

    enum Bucket: String, CaseIterable, Identifiable {
        case today = "Today", week = "This week", later = "Later", someday = "Someday"
        var id: String { rawValue }
    }

    /// Everything the list shows, computed once per render.
    private struct Model {
        var groups: [(Bucket, [StoredTask])] = []
        var done: [StoredTask] = []
        var nextBlock: [String: StoredBlock] = [:]
        var openCount = 0
        var overdue = 0
        var ordered: [StoredTask] { groups.flatMap(\.1) }
    }

    private func makeModel(now: Date, cal: DayCalendar) -> Model {
        var m = Model()
        var todayBlock = Set<String>()
        for b in blocks where !b.skipped && !b.completed && b.end > now {
            if m.nextBlock[b.taskID] == nil { m.nextBlock[b.taskID] = b }
            if cal.isSameDay(b.start, now) { todayBlock.insert(b.taskID) }
        }
        let open = tasks.filter { !$0.isDone }
        let byID = Dictionary(open.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ranked = TaskScorer().rank(open.map(\.value), now: now).compactMap { byID[$0.id.uuidString] }
        // Anything the scorer didn't return (ids that aren't UUIDs) goes at the end.
        let rankedIDs = Set(ranked.map(\.id))
        let ordered = ranked + open.filter { !rankedIDs.contains($0.id) }

        var buckets: [Bucket: [StoredTask]] = [:]
        for t in ordered {
            let b: Bucket
            if let d = t.deadline {
                let days = cal.days(from: now, to: d)
                b = days <= 0 || todayBlock.contains(t.id) ? .today : (days <= 7 ? .week : .later)
            } else if todayBlock.contains(t.id) {
                b = .today
            } else if let next = m.nextBlock[t.id], cal.days(from: now, to: next.start) <= 7 {
                b = .week
            } else {
                b = .someday
            }
            buckets[b, default: []].append(t)
        }
        m.groups = Bucket.allCases.compactMap { b in buckets[b].map { (b, $0) } }
        m.done = tasks.filter(\.isDone).sorted { ($0.completedAt ?? now) > ($1.completedAt ?? now) }
        m.openCount = open.count
        m.overdue = open.filter { ($0.deadline ?? .distantFuture) < now }.count
        return m
    }

    var body: some View {
        let now = Date()
        let model = makeModel(now: now, cal: app.calendar)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    PageHeader(title: "Tasks", subtitle: subtitle(model))

                    QuickAddField(placeholder: "Add a task, e.g. “essay plan BEM2031 2h by Friday”") { task in
                        app.selectedTaskID = task.id
                    }
                    .padding(.bottom, Theme.Space.s)
                    Hairline()

                    if model.openCount == 0 {
                        EmptyState(title: "All clear.", message: "Type a task above and Orbit finds it a slot.")
                    }

                    ForEach(model.groups, id: \.0) { bucket, items in
                        groupHeader(bucket.rawValue, count: items.count)
                        ForEach(items) { task in
                            row(task, model: model, now: now)
                        }
                    }

                    if !model.done.isEmpty {
                        Button {
                            withAnimation(Motion.smooth) { showDone.toggle() }
                        } label: {
                            HStack(spacing: Theme.Space.xs) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .rotationEffect(.degrees(showDone ? 90 : 0))
                                Text("Completed")
                                Text("\(model.done.count)").monospacedDigit().foregroundStyle(Theme.textTertiary)
                            }
                            .font(Theme.headline)
                            .foregroundStyle(Theme.textSecondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, Theme.Space.xl)
                        .padding(.bottom, Theme.Space.xs)
                        .padding(.horizontal, Theme.Space.s)

                        if showDone {
                            ForEach(model.done.prefix(50)) { task in
                                row(task, model: model, now: now)
                            }
                        }
                    }
                }
                .padding(.horizontal, pagePadding)
                .padding(.bottom, Theme.Space.xxxl)
                .frame(maxWidth: Theme.readingWidth + pagePadding * 2)
                .frame(maxWidth: .infinity)
                .animation(Motion.smooth, value: model.ordered.map(\.id))
            }
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.downArrow) { move(1, model: model, proxy: proxy); return .handled }
            .onKeyPress(.upArrow) { move(-1, model: model, proxy: proxy); return .handled }
            .onKeyPress(.space) {
                guard let t = selectedTask else { return .ignored }
                withAnimation(Motion.smooth) { app.toggleComplete(t) }
                return .handled
            }
            .onKeyPress(.delete) {
                guard let t = selectedTask else { return .ignored }
                move(1, model: model, proxy: proxy)
                withAnimation(Motion.smooth) { app.deleteWithUndo(t) }
                return .handled
            }
        }
        .orbitBackground()
        .navigationTitle("Tasks")
        .inspector(isPresented: inspectorBinding) {
            TaskInspector(task: selectedTask)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(Motion.snappy) { showInspector.toggle() }
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Show or hide details (⌥⌘I)")
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        #endif
    }

    // MARK: Pieces

    private var pagePadding: CGFloat {
        #if os(macOS)
        return Theme.Space.xxxl
        #else
        return Theme.Space.l
        #endif
    }

    private var inspectorBinding: Binding<Bool> {
        #if os(macOS)
        return $showInspector
        #else
        return Binding(get: { app.selectedTaskID != nil }, set: { if !$0 { app.selectedTaskID = nil } })
        #endif
    }

    private var selectedTask: StoredTask? {
        app.selectedTaskID.flatMap { id in tasks.first { $0.id == id } }
    }

    private func subtitle(_ m: Model) -> String {
        var parts = ["\(m.openCount) open"]
        if m.overdue > 0 { parts.append("\(m.overdue) overdue") }
        return parts.joined(separator: " · ")
    }

    private func groupHeader(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(title).font(Theme.headline).foregroundStyle(Theme.textPrimary)
            Text("\(count)").font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.top, Theme.Space.xl)
        .padding(.bottom, Theme.Space.xs)
    }

    private func row(_ task: StoredTask, model: Model, now: Date) -> some View {
        TaskRow(task: task, nextBlock: model.nextBlock[task.id], isSelected: app.selectedTaskID == task.id, now: now)
            .id(task.id)
            .onTapGesture {
                app.selectedTaskID = task.id
                listFocused = true
            }
            .contextMenu {
                Button(task.isDone ? "Mark not done" : "Complete") {
                    withAnimation(Motion.smooth) { app.toggleComplete(task) }
                }
                Button("Delete", role: .destructive) {
                    withAnimation(Motion.smooth) { app.deleteWithUndo(task) }
                }
            }
            .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
    }

    private func move(_ delta: Int, model: Model, proxy: ScrollViewProxy) {
        let ordered = model.ordered + (showDone ? Array(model.done.prefix(50)) : [])
        guard !ordered.isEmpty else { return }
        let index = ordered.firstIndex { $0.id == app.selectedTaskID } ?? (delta > 0 ? -1 : ordered.count)
        let next = ordered[max(0, min(ordered.count - 1, index + delta))]
        app.selectedTaskID = next.id
        proxy.scrollTo(next.id)
    }
}

/// One task: checkbox, title, then quiet metadata on the right.
struct TaskRow: View {
    @Environment(AppModel.self) private var app
    var task: StoredTask
    var nextBlock: StoredBlock? = nil
    var isSelected: Bool = false
    var now: Date = Date()
    /// Optimistic checkbox state while the change settles.
    @State private var pending: Bool?
    @State private var tick = 0

    var body: some View {
        let cal = app.calendar
        let done = pending ?? task.isDone
        HStack(spacing: 10) {
            CircleCheckbox(isOn: done, action: toggle)
            Text(task.title.isEmpty ? "Untitled" : task.title)
                .font(Theme.body)
                .foregroundStyle(done ? Theme.textTertiary : Theme.textPrimary)
                .strikethrough(done, color: Theme.textTertiary)
                .lineLimit(1)
            if !task.notes.isEmpty {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: Theme.Space.s)
            if !done {
                if let b = nextBlock {
                    Text(cal.isSameDay(b.start, now) ? cal.time(b.start) : "\(Fmt.shortDue(b.start, cal, now: now)) \(cal.time(b.start))")
                        .font(Theme.caption.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .help("Scheduled")
                }
                ModuleTag(code: task.moduleCode)
                if let d = task.deadline {
                    DueText(date: d, calendar: cal, now: now, style: .short)
                }
            } else if let c = task.completedAt {
                Text(Fmt.shortDue(c, cal, now: now)).font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(minHeight: 32)
        .hoverRow(selected: isSelected)
        .successHaptic(tick)
    }

    private func toggle() {
        let target = !(pending ?? task.isDone)
        pending = target
        if target { tick += 1 }
        Task { @MainActor in
            // Let the tick land before the row moves.
            try? await Task.sleep(for: .milliseconds(350))
            if task.isDone != target {
                withAnimation(Motion.smooth) { app.toggleComplete(task) }
            }
            pending = nil
        }
    }
}

/// Details for the selected task, edited in place.
struct TaskInspector: View {
    var task: StoredTask?

    var body: some View {
        if let task {
            TaskEditor(task: task).id(task.id)
        } else {
            Text("No task selected")
                .font(Theme.body)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct TaskEditor: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \StoredBlock.start) private var allBlocks: [StoredBlock]
    @Query(sort: \StoredModule.id) private var modules: [StoredModule]
    @Bindable var task: StoredTask
    @State private var savedFingerprint: String?

    private var fingerprint: String {
        [task.title, task.notes, "\(task.estimateMinutes)", "\(task.minutesDone)", "\(task.priorityRaw)",
         "\(task.energyRaw)", task.deadline.map { "\($0.timeIntervalSince1970)" } ?? "-", task.moduleCode ?? "-"]
            .joined(separator: "|")
    }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $task.title, axis: .vertical)
                    .font(Theme.large.weight(.medium))
                TextField("Notes", text: $task.notes, axis: .vertical)
                    .lineLimit(3...8)
            }
            Section {
                Toggle("Deadline", isOn: Binding(
                    get: { task.deadline != nil },
                    set: { on in
                        task.deadline = on ? (task.deadline ?? app.calendar.date(minute: 17 * 60, of: app.calendar.addingDays(1, to: Date()))) : nil
                    }))
                if task.deadline != nil {
                    DatePicker("Due", selection: Binding(get: { task.deadline ?? Date() }, set: { task.deadline = $0 }))
                }
                Picker("Module", selection: $task.moduleCode) {
                    Text("None").tag(String?.none)
                    ForEach(modules) { m in Text(m.name.isEmpty ? m.id : "\(m.id) \(m.name)").tag(String?.some(m.id)) }
                    if let code = task.moduleCode, !modules.contains(where: { $0.id == code }) {
                        Text(code).tag(String?.some(code))
                    }
                }
            }
            Section {
                Stepper("Estimate \(Fmt.duration(task.estimateMinutes))", value: $task.estimateMinutes, in: 5...3000, step: 15)
                Stepper("Done \(Fmt.duration(task.minutesDone))", value: $task.minutesDone, in: 0...3000, step: 15)
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
            let planned = allBlocks.filter { $0.taskID == task.id && !$0.skipped }
            Section("Scheduled") {
                if planned.isEmpty {
                    Text(task.isDone ? "Done." : "Not scheduled yet. Orbit plans it on its next pass.")
                        .foregroundStyle(Theme.textSecondary)
                }
                ForEach(planned) { b in
                    HStack {
                        Text(Fmt.dayTime(b.start, app.calendar))
                            .strikethrough(b.completed)
                            .monospacedDigit()
                        Spacer()
                        Text(Fmt.duration(b.minutes)).foregroundStyle(Theme.textSecondary).monospacedDigit()
                    }
                }
            }
            Section {
                Button(task.isDone ? "Mark not done" : "Complete") {
                    withAnimation(Motion.smooth) { app.toggleComplete(task) }
                }
                Button("Delete", role: .destructive) {
                    let t = task
                    app.selectedTaskID = nil
                    withAnimation(Motion.smooth) { app.deleteWithUndo(t) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { savedFingerprint = fingerprint }
        .task(id: fingerprint) {
            // Save edits shortly after typing stops (replanning runs off this).
            guard let saved = savedFingerprint, saved != fingerprint else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            savedFingerprint = fingerprint
            app.taskEdited(task)
        }
        .onDisappear {
            if let saved = savedFingerprint, saved != fingerprint { app.taskEdited(task) }
        }
    }
}
