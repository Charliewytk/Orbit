import SwiftUI
import AppKit
import OrbitCore

/// Group projects: members, tasks, deadlines and my contributions log.
struct GroupsView: View {
    @State private var selection: String?
    @State private var newName = ""
    private var companion: CompanionHub { .shared }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(companion.state.groups.active) { p in
                        GroupListRow(project: p).tag(p.id)
                    }
                }
                .scrollContentBackground(.hidden)
                HStack {
                    TextField("New group project", text: $newName).textFieldStyle(.roundedBorder)
                    Button("Add") { add() }.disabled(newName.isEmpty)
                }
                .padding(Theme.Space.s)
            }
            .frame(width: 280)
            Divider()
            if let id = selection, let p = companion.state.groups.projects.first(where: { $0.id == id }) {
                GroupDetailView(project: p)
                    .id(p.id)
            } else {
                EmptyState(systemImage: "person.3", title: "Group work",
                           message: "Track members, who does what, deadlines, and a log of your own contributions for peer assessment.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .orbitBackground()
        .navigationTitle("Group work")
    }

    private func add() {
        let p = GroupProject(name: newName)
        companion.update(p)
        selection = p.id
        newName = ""
    }
}

struct GroupListRow: View {
    var project: GroupProject

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                ModuleDot(code: project.moduleCode, size: 8)
                Text(project.name).font(Theme.body).lineLimit(1)
            }
            ProgressView(value: project.progress).tint(Theme.accent)
            if let d = project.deadline {
                Text("Due \(d.formatted(date: .abbreviated, time: .omitted))").font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

struct GroupDetailView: View {
    @State var project: GroupProject
    @State private var newMember = ""
    @State private var newTask = ""
    @State private var newTaskDue = Date().addingTimeInterval(3 * 86400)
    @State private var contribution = ""
    @State private var contributionMinutes = 30
    private var companion: CompanionHub { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                overview
                members
                tasks
                contributions
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .onChange(of: project) { companion.update(project) }
    }

    private var overview: some View {
        DigestSection(title: "Project") {
            TextField("Name", text: $project.name).textFieldStyle(.roundedBorder)
            TextField("Module code", text: Binding(get: { project.moduleCode ?? "" },
                                                   set: { project.moduleCode = $0.isEmpty ? nil : $0.uppercased() }))
                .textFieldStyle(.roundedBorder)
            DatePicker("Deadline", selection: Binding(get: { project.deadline ?? Date() }, set: { project.deadline = $0 }),
                       displayedComponents: [.date, .hourAndMinute])
            TextField("Notes", text: $project.notes, axis: .vertical).lineLimit(2...6).textFieldStyle(.roundedBorder)
            HStack {
                Button("Archive") { project.archived = true }
                Button("Delete", role: .destructive) { companion.delete(project) }
            }
        }
    }

    private var members: some View {
        DigestSection(title: "Members") {
            ForEach(project.members) { m in
                HStack {
                    Text(m.name + (m.isMe ? " (me)" : "")).font(Theme.body)
                    Spacer()
                    Text("\(project.completedByMember[m.id] ?? 0) done").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            HStack {
                TextField("Add member", text: $newMember).textFieldStyle(.roundedBorder)
                Button("Add") {
                    project.members.append(.init(name: newMember))
                    newMember = ""
                }
                .disabled(newMember.isEmpty)
            }
        }
    }

    private var tasks: some View {
        DigestSection(title: "Tasks") {
            ForEach($project.tasks) { $task in
                GroupTaskRow(task: $task, members: project.members)
            }
            HStack {
                TextField("New task", text: $newTask).textFieldStyle(.roundedBorder)
                DatePicker("", selection: $newTaskDue, displayedComponents: .date).labelsHidden()
                Button("Add") {
                    project.tasks.append(.init(title: newTask, assigneeID: project.me?.id, due: newTaskDue))
                    newTask = ""
                }
                .disabled(newTask.isEmpty)
            }
        }
    }

    private var contributions: some View {
        DigestSection(title: "My contributions (\(project.myMinutes / 60)h \(project.myMinutes % 60)m)") {
            ForEach(project.contributions.sorted { $0.date > $1.date }) { c in
                HStack {
                    Text(c.date.formatted(date: .abbreviated, time: .omitted)).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    Text(c.summary).font(Theme.body)
                    Spacer()
                    if c.minutes > 0 { Text("\(c.minutes) min").font(Theme.caption) }
                }
            }
            HStack {
                TextField("What I did", text: $contribution).textFieldStyle(.roundedBorder)
                Stepper("\(contributionMinutes) min", value: $contributionMinutes, in: 0...600, step: 15)
                Button("Log") {
                    project.contributions.append(.init(date: Date(), summary: contribution, minutes: contributionMinutes))
                    contribution = ""
                }
                .disabled(contribution.isEmpty)
            }
            Button("Copy report for peer assessment") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(project.contributionReport(calendar: companion.cal), forType: .string)
            }
        }
    }
}

struct GroupTaskRow: View {
    @Binding var task: GroupProject.GroupTask
    var members: [GroupProject.Member]

    var body: some View {
        HStack {
            Toggle("", isOn: $task.done).labelsHidden()
            Text(task.title).font(Theme.body).strikethrough(task.done)
            Spacer()
            Picker("", selection: $task.assigneeID) {
                Text("Unassigned").tag(String?.none)
                ForEach(members) { m in Text(m.name).tag(String?.some(m.id)) }
            }
            .labelsHidden()
            .frame(width: 130)
            if let d = task.due {
                Text(d.formatted(date: .abbreviated, time: .omitted)).font(Theme.caption)
                    .foregroundStyle(!task.done && d < Date() ? Theme.danger : Theme.textTertiary)
            }
        }
    }
}
