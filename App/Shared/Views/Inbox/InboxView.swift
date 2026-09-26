import SwiftUI
import SwiftData
import OrbitCore

/// Mail-client layout: the sorted list on the left, a reading pane on the right.
struct InboxView: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \StoredEmailDigest.date, order: .reverse) private var digests: [StoredEmailDigest]
    @State private var accountFilter: MailAccount?
    @State private var categoryFilter: EmailCategory?
    @State private var showHandled = false
    @State private var selectedID: String?
    @FocusState private var listFocused: Bool

    private var visible: [StoredEmailDigest] {
        let cutoff = Date().addingTimeInterval(-21 * 86400)
        return digests.filter { d in
            (showHandled || !d.handled) && (accountFilter == nil || d.account == accountFilter)
                && (categoryFilter == nil || d.category == categoryFilter)
                && d.date > cutoff
        }
    }

    var body: some View {
        let list = visible
        TwoPane(selection: $selectedID, listWidth: 340) {
            listPane(list)
        } detail: { id in
            if let id, let digest = digests.first(where: { $0.id == id }) {
                DigestReader(digest: digest)
            } else {
                Text(list.isEmpty ? "" : "No message selected")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Inbox")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Account", selection: $accountFilter) {
                        Text("All accounts").tag(MailAccount?.none)
                        Text("Gmail").tag(MailAccount?.some(.gmail))
                        Text("Exeter").tag(MailAccount?.some(.exeter))
                    }
                    Picker("Category", selection: $categoryFilter) {
                        Text("All categories").tag(EmailCategory?.none)
                        ForEach(EmailCategory.allCases, id: \.self) { c in
                            Text(c.title).tag(EmailCategory?.some(c))
                        }
                    }
                    Toggle("Show done", isOn: $showHandled)
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Filter the inbox")
            }
        }
    }

    // MARK: List

    private func listPane(_ list: [StoredEmailDigest]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    if list.isEmpty {
                        EmptyState(title: app.backend.isBrain ? "Inbox zero." : "Nothing here yet.",
                                   message: app.backend.isBrain
                                       ? "Connect Gmail or Exeter in Settings and sorted mail shows up here."
                                       : "Mail your Mac has sorted shows up here.")
                            .padding(.horizontal, Theme.Space.m)
                    }
                    ForEach(groups(list), id: \.title) { group in
                        Text(group.title)
                            .font(Theme.caption.weight(.medium))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, Theme.Space.m)
                            .padding(.top, Theme.Space.m)
                            .padding(.bottom, Theme.Space.xs)
                        ForEach(group.items) { digest in
                            DigestRow(digest: digest, isSelected: selectedID == digest.id)
                                .id(digest.id)
                                .onTapGesture { selectedID = digest.id; listFocused = true }
                                .contextMenu { contextMenu(digest) }
                                .transition(.opacity)
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.xs)
                .padding(.bottom, Theme.Space.l)
                .animation(Motion.smooth, value: list.map(\.id))
            }
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.downArrow) { move(1, in: list, proxy: proxy); return .handled }
            .onKeyPress(.upArrow) { move(-1, in: list, proxy: proxy); return .handled }
            .onKeyPress("j") { move(1, in: list, proxy: proxy); return .handled }
            .onKeyPress("k") { move(-1, in: list, proxy: proxy); return .handled }
            .onKeyPress("e") {
                guard let id = selectedID, let d = list.first(where: { $0.id == id }) else { return .ignored }
                done(d, in: list)
                return .handled
            }
        }
        .onAppear {
            #if os(macOS)
            if selectedID == nil { selectedID = list.first?.id }
            #endif
        }
    }

    @ViewBuilder
    private func contextMenu(_ digest: StoredEmailDigest) -> some View {
        Button(digest.handled ? "Move back to inbox" : "Mark as done") {
            if digest.handled { app.markHandled(digest, false) } else { done(digest, in: visible) }
        }
        if let url = digest.webURL { Button("Open in browser") { openExternal(url) } }
    }

    private struct MailGroup { var title: String; var items: [StoredEmailDigest] }

    private func groups(_ list: [StoredEmailDigest]) -> [MailGroup] {
        let cal = app.calendar
        let now = Date()
        var today: [StoredEmailDigest] = [], yesterday: [StoredEmailDigest] = [], earlier: [StoredEmailDigest] = []
        for d in list {
            switch cal.days(from: now, to: d.date) {
            case 0: today.append(d)
            case -1: yesterday.append(d)
            default: earlier.append(d)
            }
        }
        return [MailGroup(title: "Today", items: today), MailGroup(title: "Yesterday", items: yesterday),
                MailGroup(title: "Earlier", items: earlier)].filter { !$0.items.isEmpty }
    }

    private func move(_ delta: Int, in list: [StoredEmailDigest], proxy: ScrollViewProxy) {
        guard !list.isEmpty else { return }
        let ordered = groups(list).flatMap(\.items)
        let index = ordered.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : ordered.count)
        let next = max(0, min(ordered.count - 1, index + delta))
        selectedID = ordered[next].id
        proxy.scrollTo(ordered[next].id)
    }

    private func done(_ digest: StoredEmailDigest, in list: [StoredEmailDigest]) {
        let ordered = groups(list).flatMap(\.items)
        if selectedID == digest.id, let i = ordered.firstIndex(where: { $0.id == digest.id }) {
            let after = ordered.indices.contains(i + 1) ? ordered[i + 1].id : (i > 0 ? ordered[i - 1].id : nil)
            selectedID = after
        }
        withAnimation(Motion.smooth) { app.markHandledWithUndo(digest) }
    }
}

extension EmailCategory {
    var title: String {
        switch self {
        case .urgent: "Urgent"
        case .needsReply: "Needs reply"
        case .hasDate: "Date"
        case .uni: "Uni"
        case .other: "Other"
        case .ignore: "Low priority"
        }
    }

    /// Small monochrome symbol (never emoji).
    var symbol: String {
        switch self {
        case .urgent: "exclamationmark.circle"
        case .needsReply: "arrowshape.turn.up.left"
        case .hasDate: "calendar"
        case .uni: "graduationcap"
        case .other: "envelope"
        case .ignore: "arrow.down.circle"
        }
    }
}

/// Two-line message row: sender and time, subject, then category and account.
struct DigestRow: View {
    @Environment(AppModel.self) private var app
    var digest: StoredEmailDigest
    var isSelected: Bool = false

    var body: some View {
        let cal = app.calendar
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                if digest.category == .urgent || digest.category == .needsReply {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                        .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
                }
                Text(digest.from)
                    .font(Theme.body.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.s)
                Text(cal.isSameDay(digest.date, Date()) ? cal.time(digest.date) : Fmt.shortDue(digest.date, cal))
                    .font(Theme.caption.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            Text(digest.subject)
                .font(Theme.body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: digest.category.symbol).imageScale(.small)
                Text(digest.category.title)
                Text("·")
                Text(digest.account == .gmail ? "Gmail" : "Exeter")
                if !digest.suggestedTasks.isEmpty || !digest.suggestedEvents.isEmpty {
                    Text("·")
                    Text("Suggestions")
                }
            }
            .font(Theme.caption)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.s)
        .hoverRow(selected: isSelected)
        .opacity(digest.handled ? 0.5 : 1)
    }
}

/// The reading pane: summary, suggestions as plain buttons, and actions.
struct DigestReader: View {
    @Environment(AppModel.self) private var app
    var digest: StoredEmailDigest
    @State private var drafting = false
    @State private var added = 0

    var body: some View {
        let cal = app.calendar
        let tasks = digest.suggestedTasks
        let events = digest.suggestedEvents
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(digest.subject)
                    .font(.system(size: Theme.Size.title2, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: Theme.Space.xs) {
                    Text(digest.from).foregroundStyle(Theme.textPrimary)
                    Text("·")
                    Text(digest.account == .gmail ? "Gmail" : "Exeter")
                    Text("·")
                    Text("\(Fmt.day(digest.date, cal)) \(cal.time(digest.date))").monospacedDigit()
                    Text("·")
                    Label(digest.category.title, systemImage: digest.category.symbol)
                        .labelStyle(DetailLabelStyle())
                }
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, Theme.Space.s)

                HStack(spacing: Theme.Space.s) {
                    Button(digest.draftReply == nil ? "Draft reply" : "View draft") { drafting = true }
                        .buttonStyle(.bordered)
                    if let url = digest.webURL {
                        Button(digest.account == .gmail ? "Open in Gmail" : "Open in Outlook") { openExternal(url) }
                            .buttonStyle(.quiet)
                    }
                    Button(digest.handled ? "Move to inbox" : "Done") {
                        withAnimation(Motion.smooth) {
                            if digest.handled { app.markHandled(digest, false) } else { app.markHandledWithUndo(digest) }
                        }
                    }
                    .buttonStyle(.quiet)
                    .help("Mark done (E)")
                    Spacer()
                    if digest.draftSavedAt != nil {
                        Text("Draft saved").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
                .controlSize(.small)
                .padding(.top, Theme.Space.l)

                Hairline().padding(.vertical, Theme.Space.l)

                Text(digest.summary.isEmpty ? "No summary for this message." : digest.summary)
                    .font(Theme.large)
                    .foregroundStyle(digest.summary.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if !tasks.isEmpty || !events.isEmpty {
                    Text("Suggested")
                        .font(Theme.headline)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, Theme.Space.xl)
                        .padding(.bottom, Theme.Space.xs)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(tasks.enumerated()), id: \.offset) { i, t in
                            suggestion(title: "Add task: \(t.title)",
                                       detail: t.deadline.map { "due \(Fmt.dayTime($0, cal))" },
                                       symbol: "checklist", done: digest.addedSuggestions.contains("task:\(i)")) {
                                app.addSuggestedTask(digest, index: i)
                            }
                        }
                        ForEach(Array(events.enumerated()), id: \.offset) { i, e in
                            suggestion(title: "Add to calendar: \(e.title)", detail: Fmt.dayTime(e.start, cal),
                                       symbol: "calendar", done: digest.addedSuggestions.contains("event:\(i)")) {
                                Task { await app.addSuggestedEvent(digest, index: i) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .orbitBackground()
        .successHaptic(added)
        .sheet(isPresented: $drafting) { DraftReplySheet(digest: digest) }
        .id(digest.id)
    }

    private func suggestion(title: String, detail: String?, symbol: String, done: Bool,
                            action: @escaping () -> Void) -> some View {
        Button {
            added += 1
            withAnimation(Motion.snappy) { action() }
        } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: done ? "checkmark" : symbol)
                    .frame(width: 16)
                    .foregroundStyle(done ? Theme.success : Theme.textTertiary)
                Text(title)
                    .foregroundStyle(done ? Theme.textTertiary : Theme.accent)
                    .lineLimit(1)
                if let detail {
                    Text(detail).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if done { Text("Added").foregroundStyle(Theme.textTertiary) }
            }
            .font(Theme.body)
            .padding(.horizontal, Theme.Space.s)
            .frame(height: 30)
            .hoverRow()
        }
        .buttonStyle(.plain)
        .disabled(done)
    }
}

/// Shows (or asks the Mac for) a reply draft, lets you edit it, then saves it
/// as a draft in the right mailbox. Nothing is ever sent.
struct DraftReplySheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var digest: StoredEmailDigest
    @State private var text = ""
    @State private var loading = false
    @State private var queued = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Re: \(digest.subject)").font(Theme.headline).lineLimit(2)
                    Text("To \(digest.from)").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
                if loading {
                    HStack(spacing: Theme.Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Drafting in your tone…").foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else if queued && (digest.draftReply ?? "").isEmpty {
                    EmptyState(title: "Your Mac is drafting this.",
                               message: "It appears here when your Mac has written it (it needs to be awake).")
                } else {
                    TextEditor(text: $text)
                        .font(Theme.body)
                        .scrollContentBackground(.hidden)
                        .padding(Theme.Space.s)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                        .frame(minHeight: 240)
                }
                if let error { Text(error).font(Theme.caption).foregroundStyle(Theme.danger) }
                Text("Saved as a draft in \(digest.account == .gmail ? "Gmail" : "your Exeter mailbox"). Orbit never sends email.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
            .padding(Theme.Space.l)
            .navigationTitle("Draft reply")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save draft") { save() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 440)
        .task { await load() }
        .onChange(of: digest.draftReply) { _, new in
            if let new, text.isEmpty { text = new; queued = false }
        }
    }

    private func load() async {
        if let existing = digest.draftReply, !existing.isEmpty { text = existing; return }
        loading = true
        defer { loading = false }
        do {
            if let draft = try await app.backend.draftReply(digestID: digest.id) {
                text = draft
            } else {
                queued = true
            }
        } catch {
            self.error = "Couldn't draft a reply: \(error.localizedDescription)"
        }
    }

    private func save() {
        let body = text
        Task {
            do {
                try await app.backend.saveDraft(digestID: digest.id, body: body)
                app.show(app.backend.isBrain ? "Draft saved" : "Your Mac will save the draft")
                dismiss()
            } catch {
                self.error = "Couldn't save the draft: \(error.localizedDescription)"
            }
        }
    }
}
