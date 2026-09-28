import SwiftUI
import OrbitCore

/// Study Lab: the concept web, practice sets, reading plan, teach-it-back and Explore.
struct StudyLabView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case web = "Web", practice = "Practice", reading = "Reading", teach = "Teach it back", explore = "Explore"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .web
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in Text(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Divider()
            content
        }
        .navigationTitle("Study Lab")
        .toolbar {
            ToolbarItem {
                Button { showSettings = true } label: { Label("Study settings", systemImage: "slider.horizontal.3") }
            }
        }
        .sheet(isPresented: $showSettings) { StudySettingsSheet() }
        .onAppear { StudyHub.shared.loadIfNeeded() }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .web: ConceptWebView()
        case .practice: PracticeView()
        case .reading: ReadingLibraryView()
        case .teach: TeachBackView()
        case .explore: ExploreView()
        }
    }
}

// MARK: - Web

struct ConceptWebView: View {
    private var hub: StudyHub { .shared }

    var body: some View {
        let topics = hub.currentTopics()
        let web = hub.web()
        List {
            Section("This week's topics") {
                if topics.isEmpty { Text("Sync ELE to see this week's topics.").foregroundStyle(.secondary) }
                ForEach(topics, id: \.self) { t in
                    TopicHintsRow(topic: t)
                }
            }
            Section("Cross-module connections") {
                if web.crossModule.isEmpty { Text("No connections found yet.").foregroundStyle(.secondary) }
                ForEach(web.crossModule, id: \.self) { e in
                    ConceptLinkRow(link: e)
                }
            }
            ForEach(EconStrand.allCases, id: \.self) { strand in
                let concepts = (web.focus + web.related).filter { $0.strand == strand }
                if !concepts.isEmpty {
                    Section(strand.label) {
                        Text(concepts.map(\.name).joined(separator: " · ")).font(.callout)
                    }
                }
            }
        }
    }
}

struct TopicHintsRow: View {
    let topic: StudyHub.WeekTopic

    var body: some View {
        let hints = StudyHub.shared.hints(for: topic)
        VStack(alignment: .leading, spacing: 3) {
            Text("\(ModuleLabel.title(topic.moduleCode)) · \(topic.topic)").font(.body.weight(.medium))
            ForEach(hints, id: \.self) { h in
                Text(h.line).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ConceptLinkRow: View {
    let link: ConceptLink

    var body: some View {
        let g = StudyHub.shared.graph
        let a = g.concepts[link.from], b = g.concepts[link.to]
        VStack(alignment: .leading, spacing: 2) {
            Text("\(a?.name ?? link.from)  ↔  \(b?.name ?? link.to)").font(.body.weight(.medium))
            Text("\(a?.strand.label ?? "") → \(b?.strand.label ?? "") · \(link.relation)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Practice

struct PracticeView: View {
    @State private var module = ""
    @State private var kind: PracticeSetKind = .homework
    @State private var difficulty = 0
    @State private var count = 6
    private var hub: StudyHub { .shared }

    var body: some View {
        List {
            Section("New set") {
                Picker("Module", selection: $module) {
                    ForEach(hub.moduleCodes, id: \.self) { c in Text("\(c) \(hub.moduleName(c))").tag(c) }
                }
                Picker("Type", selection: $kind) {
                    ForEach(PracticeSetKind.allCases, id: \.self) { k in Text(k.label).tag(k) }
                }
                Picker("Difficulty", selection: $difficulty) {
                    Text("Mixed").tag(0)
                    ForEach(PracticeDifficulty.allCases, id: \.self) { d in Text(d.label).tag(d.rawValue) }
                }
                Stepper("Questions: \(count)", value: $count, in: 3...12)
                HStack {
                    Button("Generate PDFs") {
                        let d = PracticeDifficulty(rawValue: difficulty)
                        Task { await hub.generatePractice(kind: kind, moduleCode: module, difficulty: d, count: count) }
                    }
                    .disabled(module.isEmpty || hub.working)
                    if hub.working { ProgressView().controlSize(.small); Text(hub.status).font(.caption) }
                }
                Text("\(hub.ledger.doneCount) questions marked done — never repeated.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Your sets") {
                ForEach(hub.practiceSets) { set in
                    PracticeSetRow(set: set)
                }
            }
        }
        .onAppear { if module.isEmpty { module = hub.moduleCodes.first ?? "" } }
    }
}

struct PracticeSetRow: View {
    let set: PracticeSet
    private var hub: StudyHub { .shared }

    var body: some View {
        let files = hub.files(for: set)
        VStack(alignment: .leading, spacing: 6) {
            Text(set.title).font(.body.weight(.medium))
            Text("\(set.questions.count) questions · \(set.kind.label)").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Open in Notability") { hub.openInNotability(files.questions) }
                Button("Solutions") { hub.openInNotability(files.solutions) }
                Button("AirDrop") { hub.airDrop([files.questions, files.solutions]) }
                ShareLink(item: files.questions) { Label("Share", systemImage: "square.and.arrow.up") }
                Menu("More") {
                    Button("Copy to Notability folder") { hub.exportForNotability([files.questions, files.solutions]) }
                    Button("Upload to Google Drive") { Task { await hub.uploadToDrive([files.questions, files.solutions], moduleCode: set.moduleCode) } }
                    Button("Rebuild PDFs") { Task { await hub.writeAndDeliver(set) } }
                    Divider()
                    Button("Mark done — felt confident") { hub.markDone(set, confident: true) }
                    Button("Mark done — found it hard") { hub.markDone(set, confident: false) }
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Reading

struct ReadingLibraryView: View {
    @State private var refresh = 0
    private var hub: StudyHub { .shared }

    var body: some View {
        let plan = hub.readingPlan()
        let around = hub.readingAround()
        List {
            Section("Evening reading (22:00–22:20)") {
                ForEach(plan.days, id: \.date) { day in
                    ReadingDayRow(day: day) { id, read in hub.setRead(id, read); refresh += 1 }
                }
            }
            Section("Reading around this week's topics") {
                ForEach(around) { item in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(item.title) — \(item.by)").font(.body.weight(.medium))
                            Text("\(item.kind.rawValue.capitalized) · \(item.why)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Add to plan") { hub.addAround(item); refresh += 1 }
                        Button("Read") { hub.setRead("around-\(item.id)", true); refresh += 1 }
                    }
                    .controlSize(.small)
                }
            }
            Section("All readings") {
                ForEach(hub.library.items(), id: \.id) { e in
                    Toggle(isOn: Binding(get: { e.read }, set: { hub.setRead(e.id, $0); refresh += 1 })) {
                        Text("\(ModuleLabel.title(e.moduleCode)) · \(e.title)\(e.week.map { " (wk \($0))" } ?? "") · \(e.importance.rawValue)")
                    }
                }
            }
        }
        .id(refresh)
    }
}

struct ReadingDayRow: View {
    let day: DailyReadingPlan.Day
    let setRead: (String, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(day.date.formatted(.dateTime.weekday(.wide).day().month())).font(.body.weight(.medium))
            if day.items.isEmpty { Text("Nothing planned — pick something from Reading around.").font(.caption).foregroundStyle(.secondary) }
            ForEach(day.items, id: \.self) { item in
                HStack {
                    Text("\(ModuleLabel.title(item.moduleCode)) · \(item.title)\(item.parts > 1 ? " (part \(item.part)/\(item.parts))" : "") · \(item.minutes) min")
                        .font(.callout)
                    Spacer()
                    Button("Done") { setRead(item.entryID, true) }.controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Teach it back

struct TeachBackView: View {
    @State private var topic: TeachBackTopic?
    @State private var explanation = ""
    @State private var result: TeachBackResult?
    private var hub: StudyHub { .shared }

    var body: some View {
        let topics = hub.teachBackTopics()
        HStack(spacing: 0) {
            List(selection: Binding(get: { topic?.id }, set: { id in topic = topics.first { $0.id == id }; result = nil })) {
                Section("This week") {
                    ForEach(topics) { t in
                        VStack(alignment: .leading) {
                            Text(t.topic)
                            Text("\(ModuleLabel.title(t.moduleCode)) · \(t.reason)").font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(t.id)
                    }
                }
                Section("Past") {
                    ForEach(hub.teachBack.results.prefix(10)) { r in
                        Text("\(r.topic) — \(r.score)/100").font(.callout)
                    }
                }
            }
            .frame(width: 260)
            Divider()
            TeachBackEditor(topic: topic, explanation: $explanation, result: $result)
        }
    }
}

struct TeachBackEditor: View {
    let topic: TeachBackTopic?
    @Binding var explanation: String
    @Binding var result: TeachBackResult?
    private var hub: StudyHub { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let topic {
                Text("Explain “\(topic.topic)” as if teaching a friend.").font(.headline)
                Text("Type, or dictate (press Fn twice). Orbit checks it against your course material and the other modules.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $explanation).font(.body).frame(minHeight: 160).border(Color.secondary.opacity(0.3))
                HStack {
                    Button("Grade my explanation") {
                        Task { result = await hub.grade(topic: topic, explanation: explanation) }
                    }
                    .disabled(explanation.count < 40 || hub.working)
                    if hub.working { ProgressView().controlSize(.small) }
                }
                if let result { TeachBackResultView(result: result) }
            } else {
                Text("Pick a topic on the left.").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }
}

struct TeachBackResultView: View {
    let result: TeachBackResult

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Score: \(result.score)/100").font(.title3.weight(.semibold))
                BulletGroup(title: "Gaps", items: result.gaps)
                BulletGroup(title: "Misconceptions", items: result.misconceptions)
                BulletGroup(title: "Links to your other modules", items: result.missingLinks)
                BulletGroup(title: "Next steps", items: result.nextSteps)
            }
        }
    }
}

struct BulletGroup: View {
    let title: String
    let items: [String]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                ForEach(items, id: \.self) { i in Text("• \(i)").font(.callout) }
            }
        }
    }
}

// MARK: - Explore

struct ExploreView: View {
    @State private var topic = ""
    @State private var module = ""
    @State private var mode: ExploreMode = .explore
    @State private var input = ""
    @State private var draft = ""
    @State private var turns: [StudyHub.ExploreTurn] = []
    @State private var thinking = false
    private var hub: StudyHub { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Topic or essay question", text: $topic).textFieldStyle(.roundedBorder)
                Picker("Module", selection: $module) {
                    Text("Any").tag("")
                    ForEach(hub.moduleCodes, id: \.self) { c in Text(c).tag(c) }
                }
                .frame(width: 160)
                Picker("", selection: $mode) {
                    ForEach(ExploreMode.allCases, id: \.self) { m in Text(m.label).tag(m) }
                }
                .pickerStyle(.segmented).frame(width: 220)
            }
            Text("A thinking partner: it asks questions, pushes back and finds links — it never writes your essay or plan.")
                .font(.caption).foregroundStyle(.secondary)
            if mode == .draftCheck {
                TextEditor(text: $draft).frame(height: 120).border(Color.secondary.opacity(0.3))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(turns) { t in
                        Text(t.text)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: t.fromStudent ? .trailing : .leading)
                            .background(t.fromStudent ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if thinking { ProgressView().controlSize(.small) }
                }
            }
            HStack {
                TextField(mode == .draftCheck ? "Ask about your draft…" : "Say what you think…", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Send", action: send).disabled(topic.isEmpty || thinking)
                Button("New") { turns = []; input = "" }
            }
        }
        .padding(16)
    }

    private func send() {
        guard !topic.isEmpty, !thinking else { return }
        let text = input.isEmpty ? "Let's start. Challenge my thinking on this." : input
        turns.append(.init(fromStudent: true, text: text))
        input = ""
        thinking = true
        let history = turns, t = topic, m = module.isEmpty ? nil : module, md = mode
        let d = mode == .draftCheck && turns.count <= 1 ? draft : nil
        Task {
            let reply = await hub.explore(topic: t, moduleCode: m, mode: md, history: history, draft: d)
            turns.append(.init(fromStudent: false, text: reply))
            thinking = false
        }
    }
}

// MARK: - Settings

struct StudySettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(MacPrefs.practiceDriveUpload) private var driveUpload = true
    @AppStorage(MacPrefs.notabilityAutoExport) private var autoExport = false
    @AppStorage(MacPrefs.notabilityFolder) private var folder = ""

    var body: some View {
        Form {
            Toggle("Upload PDFs to Google Drive (Orbit/Practice/<Module>)", isOn: $driveUpload)
            Toggle("Also copy every PDF to the Notability folder", isOn: $autoExport)
            TextField("Notability folder", text: $folder, prompt: Text(StudyHub.shared.notabilityFolder.path))
            Text("Point this at an iCloud Drive or Google Drive folder so Notability on the iPad can import the PDFs. Drive uploads need Google reconnected once (Settings → Accounts) to grant file access.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 520)
    }
}
